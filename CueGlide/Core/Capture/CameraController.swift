// AVFoundation 的 Sendable 标注尚不完整，`AVCaptureDevice` 在串行队列里配置是安全的。
// 用 @preconcurrency 按旧规则处理该模块，避免每处闭包都加一层包装。
@preconcurrency import AVFoundation
import UIKit
import Speech
import os

/// 相机采集与录制。
///
/// 关键设计：音视频都走 DataOutput 手动写文件，不用 AVCaptureMovieFileOutput。
/// 这样音频采样只来自一条链路，不会因为多个音频会话互相抢占而录到静音。
///
/// 注意：原计划把同一份音频同时喂给写入器和语音识别，`onAudioSample` 为此预留了接口，
/// 但该接口目前没有接线。所以提词拍摄时禁止开启语音跟读，见 `CaptureViewModel`。
///
/// 关于 `@unchecked Sendable`：session、writer 与采样回调全部在 `captureQueue` 上串行执行，
/// 少量跨队列读写的标量由 `NSLock` 保护，编译器无法推断这层约定，故显式标注。
final class CameraController: NSObject, @unchecked Sendable {

    enum CaptureError: LocalizedError {
        case cameraUnavailable
        case microphoneDenied
        case cameraDenied
        case cannotConfigure
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .cameraUnavailable:
                "当前环境没有可用摄像头。模拟器不提供相机，请用真机测试拍摄功能。"
            case .microphoneDenied:
                "没有麦克风权限，录出来会没有声音。到系统设置里允许 CueGlide 使用麦克风。"
            case .cameraDenied:
                "没有相机权限。到系统设置里允许 CueGlide 使用相机。"
            case .cannotConfigure:
                "相机初始化失败，换个镜头或重启应用再试。"
            case .writerFailed(let message):
                "录制写入失败：\(message)"
            }
        }
    }

    let session = AVCaptureSession()

    /// 每帧音频回调，用于语音跟读。在采集队列上调用，回调方自行切线程。
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    /// 保持音频桥的强引用，弱引用会被立刻回收。
    private var speechBridge: CameraAudioBridge?

    private let captureQueue = DispatchQueue(label: "com.symi.cueglide.capture")
    private let log = Logger(subsystem: "com.symi.cueglide", category: "Camera")
    /// 录制交给官方的 MovieFileOutput：编码参数、方向、HDR 全由系统管线决定，
    /// 和系统相机是同一套。之前自己拼 VideoDataOutput + AssetWriter，等于把
    /// 系统已经做好的事重做一遍，还做不过它。
    private let movieOutput = AVCaptureMovieFileOutput()
    /// 仅用于把音频分流给语音跟读，不参与录制。
    private let audioOutput = AVCaptureAudioDataOutput()

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    /// 预览层由 UI 持有生命周期，这里只弱引用。
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// 必须强引用，重建时才拿得到角度。
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    /// 当前界面方向。重建 coordinator 后要按它把角度补回去。
    private var lastInterfaceOrientation: UIInterfaceOrientation = .portrait
    /// 是否跑在 HDR（10-bit HLG）上。只有在格式支持且色彩空间切换真的生效时才为 true。
    private var _isHDREnabled = false

    /// 用锁保护跨队列读写的少量标量，录制写入器本身只在 captureQueue 上被操作。
    private let stateLock = NSLock()
    private var _position: AVCaptureDevice.Position = .front
    private var _isConfigured = false
    /// 等待 MovieFileOutput 录音结束的信号。
    private var _recordingContinuation: CheckedContinuation<URL?, Never>?

    var position: AVCaptureDevice.Position {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _position
    }

    var isConfigured: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isConfigured
    }

    /// 成片是否走 HDR，用于日志与界面提示。
    var isHDREnabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isHDREnabled
    }

    var isRecording: Bool { movieOutput.isRecording }

    private var recordingContinuation: CheckedContinuation<URL?, Never>? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _recordingContinuation
        }
        set {
            stateLock.lock()
            _recordingContinuation = newValue
            stateLock.unlock()
        }
    }

    // MARK: - 权限

    func requestPermissions() async -> (camera: Bool, microphone: Bool) {
        async let camera = AVCaptureDevice.requestAccess(for: .video)
        async let mic = AVCaptureDevice.requestAccess(for: .audio)
        return await (camera, mic)
    }

    // MARK: - 配置

    func configure(position: AVCaptureDevice.Position) async throws {
        let permission = await requestPermissions()
        guard permission.camera else { throw CaptureError.cameraDenied }
        guard permission.microphone else { throw CaptureError.microphoneDenied }

        guard let device = Self.device(for: position) else {
            throw CaptureError.cameraUnavailable
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                do {
                    try self.configureSession(device: device)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configureSession(device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 要让设备跑在最高分辨率，必须用 inputPriority 把格式的控制权拿回来。
        // 用 .high 时系统会把 activeFormat 压到 1080p 一档，前置 4K 根本用不上。
        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }

        for input in session.inputs {
            session.removeInput(input)
        }

        // 先定格式再装 input，否则 input 会按设备默认格式接线
        try configureDevice(device)

        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(deviceInput) else { throw CaptureError.cannotConfigure }
        session.addInput(deviceInput)
        videoInput = deviceInput

        if let mic = AVCaptureDevice.default(for: .audio) {
            if let micInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(micInput) {
                session.addInput(micInput)
                audioInput = micInput
            }
        }

        // MovieFileOutput 不设 outputSettings，让系统按设备当前格式自己决定
        // 编码器、码率与色彩——这才是"用官方管线"的意思。
        // MovieFileOutput 与 AudioDataOutput 不能共用同一路音频，同时挂着会让录制
        // 静默失败（isRecording 一直是 false）。平时挂 AudioDataOutput 供跟读分流，
        // 录制时再整体切给 MovieFileOutput，录完换回来。
        if session.outputs.isEmpty {
            audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            }
        }

        // HDR 是否生效看设备的色彩空间实际值
        let actualHDR = device.activeColorSpace == .HLG_BT2020

        log.info(
            "输出状态：movie=\(self.session.outputs.contains(self.movieOutput), privacy: .public) audio=\(self.session.outputs.contains(self.audioOutput), privacy: .public) 音频输入=\(self.session.inputs.contains { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }, privacy: .public)"
        )

        // 录制取真实方向，不做镜像——系统相机的前置成片就是这样，
        // 镜像会让画面里的文字、手势全反。预览的镜像由预览层单独处理。
        if let connection = movieOutput.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }

        stateLock.lock()
        _position = device.position
        _isConfigured = true
        _isHDREnabled = actualHDR
        stateLock.unlock()

        // 旋转不再写死 90 度，交给系统按设备姿态算
        rebuildRotationCoordinator(for: device)

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-dumpCameraFormats") {
            Self.dumpFormats(of: device)
        }
        #endif

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fps = device.activeVideoMinFrameDuration.timescale > 0
            ? Int((Double(device.activeVideoMinFrameDuration.timescale) / Double(device.activeVideoMinFrameDuration.value)).rounded())
            : 0
        log.info(
            "相机就绪：\(device.localizedName, privacy: .public) \(dims.width, privacy: .public)×\(dims.height, privacy: .public) @\(fps, privacy: .public)fps，\(actualHDR ? "HDR(HLG)" : "SDR", privacy: .public)，格式数 \(device.formats.count, privacy: .public)"
        )
    }

    /// 把设备调到它能给出的最高视频格式。
    ///
    /// 前置相机在 iPhone 上是横向传感器，竖着拿靠旋转校正，所以这里只挑分辨率，
    /// 方向交给 `RotationCoordinator`。
    /// 配置设备格式，返回 HDR 是否真的生效。
    @discardableResult
    private func configureDevice(_ device: AVCaptureDevice) throws -> Bool {
        guard let format = Self.bestVideoFormat(for: device) else { return false }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.activeFormat = format

        // 目标 30fps：提词拍摄不需要高帧率，4K 下 60fps 反而容易掉帧。
        // 但必须夹在格式自己支持的区间里——有些高帧率格式最低就是 60，
        // 直接设 30 会设置失败。
        let range = format.videoSupportedFrameRateRanges.first { $0.maxFrameRate >= 30 }
        let target = min(max(30, range?.minFrameRate ?? 30), range?.maxFrameRate ?? 30)
        let duration = CMTime(value: 1, timescale: CMTimeScale(target.rounded()))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        // HDR 走 HLG / BT.2020。只有格式本身支持、且设置后读回来确认生效才认，
        // 任何一步不满足都退回 SDR——宁可没有 HDR，也不能出现偏色画面。
        if format.isVideoHDRSupported, format.supportedColorSpaces.contains(.HLG_BT2020) {
            device.activeColorSpace = .HLG_BT2020
            let applied = device.activeColorSpace == .HLG_BT2020
            if !applied {
                log.error("HLG 色彩空间设置未生效，退回 SDR")
            }
            return applied
        }
        return false
    }

    private static func bestVideoFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let options = device.formats.map { format -> VideoFormatOption in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return VideoFormatOption(
                width: dims.width,
                height: dims.height,
                maxFrameRate: maxRate,
                supportsHLG: format.isVideoHDRSupported
                    && format.supportedColorSpaces.contains(.HLG_BT2020)
            )
        }
        // 默认走 16:9：这是手机视频的标准比例，系统相机录的也是 16:9 / 9:16。
        // 满传感器 4:3 虽然像素更多，但出片比例不是用户预期。
        // 需要 4:3 满视野时用 `-useLargeSensor` 启动。
        let preferLargeSensor = ProcessInfo.processInfo.arguments.contains("-useLargeSensor")
        guard let index = preferredFormatIndex(in: options, preferLargeSensor: preferLargeSensor) else {
            return nil
        }
        return device.formats[index]
    }

    /// 相机格式的候选描述。抽成值类型，选择逻辑才能单独测。
    struct VideoFormatOption: Equatable {
        let width: Int32
        let height: Int32
        let maxFrameRate: Double
        /// 该格式是否支持 10-bit HLG（真正的 HDR 录像）。
        var supportsHLG: Bool = false

        var pixels: Int { Int(width) * Int(height) }

        /// 视频标准比例。前置偶尔会给出 4:3 的静止图像格式，
        /// 那种格式像素更多但录制会变形，优先 16:9。
        var isWidescreen: Bool {
            guard height > 0 else { return false }
            let ratio = Double(width) / Double(height)
            return abs(ratio - 16.0 / 9.0) < 0.06
        }

        var isUsable: Bool { width > 0 && height > 0 && maxFrameRate >= 30 }
    }

    /// 选格式的优先级：16:9 + HLG → 16:9 → 最高分辨率。
    ///
    /// 同一个分辨率会存在多个变体（不同像素格式/色彩空间），只按像素排序会随机
    /// 落到不支持 HLG 的那个上——实测 iPhone 18 Pro Max 前置的 3840×2160 就是
    /// 这样，像素数一样但只有部分变体支持 HLG，选错就退化成 SDR。
    static func preferredFormatIndex(
        in options: [VideoFormatOption],
        preferLargeSensor: Bool = false
    ) -> Int? {
        let usable = options.enumerated().filter { $0.element.isUsable }

        if preferLargeSensor {
            return usable.max { $0.element.pixels < $1.element.pixels }?.offset
        }

        let hlgWidescreen = usable.filter { $0.element.isWidescreen && $0.element.supportsHLG }
        if let best = hlgWidescreen.max(by: { $0.element.pixels < $1.element.pixels }) {
            return best.offset
        }

        let widescreen = usable.filter { $0.element.isWidescreen }
        if let best = widescreen.max(by: { $0.element.pixels < $1.element.pixels }) {
            return best.offset
        }

        return usable.max { $0.element.pixels < $1.element.pixels }?.offset
    }

    // MARK: - 旋转

    /// 把预览层交给控制器。`videoRotationAngleForHorizonLevelPreview`
    /// 在没有预览层时恒为 0，预览方向就对不上了。
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        rebuildRotationCoordinator(for: videoInput?.device)
    }

    private func rebuildRotationCoordinator(for device: AVCaptureDevice?) {
        rotationCoordinator = nil
        guard let device else { return }

        rotationCoordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: previewLayer
        )
        // coordinator 本身不主动送角度更新（不挂 KVO，见 updateRotation 的说明），
        // 重建后按上次的界面方向把角度补回去。
        applyRotationForCurrentInterface()
    }

    /// 按界面方向设定旋转角。
    ///
    /// 只跟重力（horizon-level）会有两个问题：设备平放或开了方向锁定时，重力角度
    /// 和界面方向对不上，表现就是「界面横了、录出来还是竖的」。iOS 27 的
    /// `videoRotationAngleRelativeToDeviceOrientation` 直接按给定界面方向返回角度，
    /// 不受重力影响；低于 27 退回重力角度。
    func updateRotation(interfaceOrientation: UIInterfaceOrientation) {
        lastInterfaceOrientation = interfaceOrientation
        applyRotationForCurrentInterface()
    }

    private func applyRotationForCurrentInterface() {
        guard !isRecording else {
            log.info("旋转跳过：正在录制")
            return
        }
        guard rotationCoordinator != nil else {
            log.info("旋转跳过：rotationCoordinator 为空")
            return
        }

        let angle = Self.captureAngle(for: lastInterfaceOrientation)
        let connection = movieOutput.connection(with: .video)
        log.info(
            "旋转应用：界面=\(self.lastInterfaceOrientation.rawValue, privacy: .public) 角度=\(angle, privacy: .public) 支持=\(connection?.isVideoRotationAngleSupported(angle) ?? false, privacy: .public)"
        )
        applyRotation(preview: angle, capture: angle)
    }

    /// 界面方向对应的画面旋转角。
    ///
    /// 不用 `videoRotationAngleRelative(toDeviceOrientation:)`：实测它对
    /// `landscapeRight` 返回 270，那是竖屏角度，设下去画面尺寸不变。
    /// 这里直接给角度：横屏 0 / 180 会让宽高互换，竖屏 90 / 270 保持竖构图。
    private static func captureAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .portrait:
            return 90
        case .portraitUpsideDown:
            return 270
        case .landscapeRight:
            return 0
        case .landscapeLeft:
            return 180
        default:
            return 90
        }
    }

    #if DEBUG
    /// 把设备支持的全部格式打到日志，用于核对原生能力。
    ///
    /// 前置相机的可用格式在不同机型上差别很大（4:3 / 16:9、8-bit / 10-bit HDR、
    /// 最高帧率都不同），靠猜会选错档，所以直接把真实列表打出来看。
    private static func dumpFormats(of device: AVCaptureDevice) {
        let probe = Logger(subsystem: "com.symi.cueglide", category: "CameraFormats")

        // syslog 会限流，一次性打几十行会被丢掉，所以按分辨率去重、只列关键结论。
        var seen = Set<String>()
        var resolutions: [String] = []
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let key = "\(dims.width)x\(dims.height)"
            guard seen.insert(key).inserted else { continue }
            let hdr = format.isVideoHDRSupported ? "HDR" : "-"
            let hlg = format.supportedColorSpaces.contains(.HLG_BT2020) ? "HLG" : "-"
            let p3 = format.supportedColorSpaces.contains(.P3_D65) ? "P3" : "-"
            resolutions.append("\(key)[\(hdr)/\(hlg)/\(p3)]")
        }
        probe.info("分辨率档位 \(resolutions.count, privacy: .public) 个：\(resolutions.joined(separator: " "), privacy: .public)")

        // 单独列出真正能用 HLG 的格式，这是 HDR 判定的硬条件。
        let hlgFormats = device.formats.filter {
            $0.isVideoHDRSupported && $0.supportedColorSpaces.contains(.HLG_BT2020)
        }
        var hlgResolutions = Set<String>()
        for format in hlgFormats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let rates = format.videoSupportedFrameRateRanges
                .map { String(format: "%.0f-%.0f", $0.minFrameRate, $0.maxFrameRate) }
                .joined(separator: "/")
            hlgResolutions.insert("\(dims.width)x\(dims.height)@\(rates)")
        }
        probe.info("可用 HLG 格式 \(hlgFormats.count, privacy: .public) 个：\(hlgResolutions.sorted().joined(separator: " "), privacy: .public)")

        let active = device.activeFormat
        let activeDims = CMVideoFormatDescriptionGetDimensions(active.formatDescription)
        probe.info(
            "当前 activeFormat \(activeDims.width, privacy: .public)x\(activeDims.height, privacy: .public) HDR=\(active.isVideoHDRSupported, privacy: .public) HLG=\(active.supportedColorSpaces.contains(.HLG_BT2020), privacy: .public) activeColorSpace=\(device.activeColorSpace.rawValue, privacy: .public)"
        )
    }
    #endif

    /// 界面方向 → 视频方向要**交叉**映射，不是同名。
    ///
    /// SDK 原文：`AVCaptureVideoOrientationLandscapeRight` 是 "port on the right"，
    /// 而 `UIInterfaceOrientationLandscapeLeft` 表示设备向右转（Home 在右）。
    /// UIKit 注释也写了 "rotating the device to the left requires rotating the
    /// content to the right"。同名映射会差 180 度，表现为横屏时画面整个倒过来。
    private static func videoOrientation(
        for orientation: UIInterfaceOrientation
    ) -> AVCaptureVideoOrientation {
        switch orientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            // UIInterfaceOrientation 是非冻结枚举，未知值按竖屏处理
            return .portrait
        }
    }

    /// 预览与采集各用各的角度：这两者在部分姿态下并不相等。
    /// 录制中不更新，否则像素尺寸会中途变化，写入器直接写坏。
    private func applyRotation(preview: CGFloat, capture: CGFloat) {
        guard !isRecording else { return }

        DispatchQueue.main.async { [weak self] in
            guard let connection = self?.previewLayer?.connection,
                  connection.isVideoRotationAngleSupported(preview) else { return }
            connection.videoRotationAngle = preview
        }

        captureQueue.async { [weak self] in
            guard let self,
                  let connection = self.movieOutput.connection(with: .video),
                  connection.isVideoRotationAngleSupported(capture) else { return }
            connection.videoRotationAngle = capture
        }
    }

    /// 明确要主摄（wide）。超广角画质更差、暗光噪点更多，
    /// 之前用 `devices.first` 拿到的顺序并不保证，可能落到超广角上。
    private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            return wide
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }

    /// 把相机音频分流一份给语音识别。
    ///
    /// 参数用采样率与声道数而不是 `AVAudioFormat` 本身：后者不是 Sendable，
    /// 从主线程传给这个非隔离方法会被 Swift 6 判为数据竞争。
    func attachSpeechAudio(
        formatSpec: AudioFormatSpec,
        continuation: AsyncStream<AudioChunk>.Continuation
    ) {
        guard let target = formatSpec.makeFormat() else {
            log.error("无法重建识别器要求的音频格式")
            return
        }
        log.info("识别器音频格式：\(formatSpec.summary, privacy: .public)")

        let bridge = CameraAudioBridge(targetFormat: target)
        speechBridge = bridge
        // 这个闭包在非隔离上下文里创建，不继承主执行器隔离，
        // 采集队列回调时不会触发隔离断言。
        onAudioSample = { sampleBuffer in
            bridge.handle(sampleBuffer, continuation: continuation)
        }
        log.info("相机音频已分流到语音识别")
    }

    func detachSpeechAudio() {
        onAudioSample = nil
        speechBridge = nil
    }

    // MARK: - 会话控制

    func start() {
        captureQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        captureQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// 切换前后摄。切换期间保持会话运行，避免画面黑一下。
    func switchCamera() async throws {
        let target: AVCaptureDevice.Position = position == .front ? .back : .front
        guard let device = Self.device(for: target) else {
            throw CaptureError.cameraUnavailable
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                do {
                    let newInput = try AVCaptureDeviceInput(device: device)
                    self.session.beginConfiguration()
                    if let old = self.videoInput {
                        self.session.removeInput(old)
                    }

                    // 换镜头后必须重新选格式：新设备的 activeFormat 是它自己的默认值，
                    // 不重选就会退回低分辨率（之前切到后摄画质掉一档就是这个原因）。
                    _ = try? self.configureDevice(device)

                    guard self.session.canAddInput(newInput) else {
                        if let old = self.videoInput, self.session.canAddInput(old) {
                            self.session.addInput(old)
                        }
                        self.session.commitConfiguration()
                        throw CaptureError.cannotConfigure
                    }
                    self.session.addInput(newInput)
                    self.videoInput = newInput

                    self.session.commitConfiguration()
                    let actualHDR = device.activeColorSpace == .HLG_BT2020

                    if let connection = self.movieOutput.connection(with: .video),
                       connection.isVideoMirroringSupported {
                        connection.isVideoMirrored = false
                    }

                    self.stateLock.lock()
                    self._position = device.position
                    self._isHDREnabled = actualHDR
                    self.stateLock.unlock()

                    // 换了镜头，原生方向可能不同，必须重建
                    self.rebuildRotationCoordinator(for: device)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 录制

    /// 交给 MovieFileOutput 直接录。
    ///
    /// 编码器、码率、HDR、像素格式、方向全由系统管线决定——不设 outputSettings，
    /// 就是让系统按设备当前格式用它的默认策略，和系统相机同一套。
    func startRecording() async throws {
        guard isConfigured else { throw CaptureError.cannotConfigure }

        // 把音频从分流用的 AudioDataOutput 交给录制管线
        session.beginConfiguration()
        if session.outputs.contains(audioOutput) {
            session.removeOutput(audioOutput)
        }
        if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        if let connection = movieOutput.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }
        session.commitConfiguration()

        guard let connection = movieOutput.connection(with: .video) else {
            restoreAudioOutput()
            throw CaptureError.cannotConfigure
        }

        // 刚加进 session 的连接角度是默认 0，必须立刻按当前方向写进去。
        // 这里不能用 applyRotationForCurrentInterface：它内部走 captureQueue.async，
        // 而下一行就 startRecording，角度还没落地就已经开录，横屏会失效。
        let angle = Self.captureAngle(for: lastInterfaceOrientation)
        let supported = [angle, (angle + 180).truncatingRemainder(dividingBy: 360)]
            .first { connection.isVideoRotationAngleSupported($0) }
        if let supported {
            connection.videoRotationAngle = supported
            log.info(
                "录制角度：写入 \(supported, privacy: .public)（目标 \(angle, privacy: .public)，界面 \(self.lastInterfaceOrientation.rawValue, privacy: .public)）"
            )
        } else {
            log.error(
                "录制角度：\(angle, privacy: .public) 与 180 度偏移都不被支持，保持连接默认值"
            )
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cueglide-\(Int(Date().timeIntervalSince1970)).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        log.info("开始录制")
    }

    /// 录完把音频输出换回分流模式，跟读才能继续用。
    private func restoreAudioOutput() {
        session.beginConfiguration()
        if session.outputs.contains(movieOutput) {
            session.removeOutput(movieOutput)
        }
        if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
            session.addOutput(audioOutput)
        }
        session.commitConfiguration()
        log.info("音频输出已交还给跟读分流")
    }

    func stopRecording() async -> URL? {
        log.info("停止录制请求，isRecording=\(self.movieOutput.isRecording, privacy: .public)")
        guard movieOutput.isRecording else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            recordingContinuation = continuation
            movieOutput.stopRecording()
        }
    }
}

// MARK: - 录制回调

extension CameraController: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let continuation = recordingContinuation
        recordingContinuation = nil

        if let error {
            log.error("录制失败：\(error.localizedDescription, privacy: .public)")
            continuation?.resume(returning: nil)
            return
        }

        log.info("录制完成：\(outputFileURL.lastPathComponent, privacy: .public)")
        continuation?.resume(returning: outputFileURL)

        // 录制结束把音频输出还给跟读分流
        let queue = captureQueue
        queue.async { [weak self] in
            self?.restoreAudioOutput()
        }

        // 录制期间角度被锁住，结束后补一次，否则设备在录制中转过之后预览会停在旧角度
        let position = position
        DispatchQueue.main.async { [weak self] in
            self?.rebuildRotationCoordinator(for: Self.device(for: position))
        }
    }
}

// MARK: - 音频分流

extension CameraController: AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // 视频由 MovieFileOutput 自己录，这里只处理音频（分流给语音跟读）
        guard output === audioOutput else { return }
        onAudioSample?(sampleBuffer)
    }
}
