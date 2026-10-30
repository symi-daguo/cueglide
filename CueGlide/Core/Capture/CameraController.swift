// AVFoundation 的 Sendable 标注尚不完整，`AVCaptureDevice` 在串行队列里配置是安全的。
// 用 @preconcurrency 按旧规则处理该模块，避免每处闭包都加一层包装。
@preconcurrency import AVFoundation
import UIKit
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

    private let captureQueue = DispatchQueue(label: "com.symi.cueglide.capture")
    private let log = Logger(subsystem: "com.symi.cueglide", category: "Camera")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    /// 预览层由 UI 持有生命周期，这里只弱引用。
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// 必须强引用：coordinator 释放后 KVO 就不再送角度了。
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    /// 用锁保护跨队列读写的少量标量，录制写入器本身只在 captureQueue 上被操作。
    private let stateLock = NSLock()
    private var _writer: RecordingWriter?
    /// 已按下录制但还没收到第一帧，等拿到真实画面尺寸再建写入器。
    private var _pendingRecordingURL: URL?
    private var _position: AVCaptureDevice.Position = .front
    private var _isConfigured = false

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

    var isRecording: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _writer != nil || _pendingRecordingURL != nil
    }

    private var pendingRecordingURL: URL? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _pendingRecordingURL
        }
        set {
            stateLock.lock()
            _pendingRecordingURL = newValue
            stateLock.unlock()
        }
    }

    private var writer: RecordingWriter? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _writer
        }
        set {
            stateLock.lock()
            _writer = newValue
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

        if session.outputs.isEmpty {
            // 录制走硬件编码器，420v 是采集管线和编码器都原生支持的格式。
            // 用 32BGRA 每帧要多做一次色彩转换，4K 下直接吃掉帧率。
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }

            audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            }
        }

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = device.position == .front
            }
        }

        stateLock.lock()
        _position = device.position
        _isConfigured = true
        stateLock.unlock()

        // 旋转不再写死 90 度，交给系统按设备姿态算
        rebuildRotationCoordinator(for: device)

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fps = device.activeVideoMinFrameDuration.timescale > 0
            ? Int((Double(device.activeVideoMinFrameDuration.timescale) / Double(device.activeVideoMinFrameDuration.value)).rounded())
            : 0
        log.info(
            "相机就绪：\(device.localizedName, privacy: .public) \(dims.width, privacy: .public)×\(dims.height, privacy: .public) @\(fps, privacy: .public)fps，格式数 \(device.formats.count, privacy: .public)"
        )
    }

    /// 把设备调到它能给出的最高视频格式。
    ///
    /// 前置相机在 iPhone 上是横向传感器，竖着拿靠旋转校正，所以这里只挑分辨率，
    /// 方向交给 `RotationCoordinator`。
    private func configureDevice(_ device: AVCaptureDevice) throws {
        guard let format = Self.bestVideoFormat(for: device) else { return }

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
    }

    private static func bestVideoFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let options = device.formats.map { format -> VideoFormatOption in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return VideoFormatOption(
                width: dims.width,
                height: dims.height,
                maxFrameRate: maxRate
            )
        }
        guard let index = preferredFormatIndex(in: options) else { return nil }
        return device.formats[index]
    }

    /// 相机格式的候选描述。抽成值类型，选择逻辑才能单独测。
    struct VideoFormatOption: Equatable {
        let width: Int32
        let height: Int32
        let maxFrameRate: Double

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

    /// 挑分辨率最高的 16:9 格式，且必须支持 30fps。
    /// 没有 16:9 就退回最高分辨率，避免个别机型只有 4:3 时反而降档。
    static func preferredFormatIndex(in options: [VideoFormatOption]) -> Int? {
        let usable = options.enumerated().filter { $0.element.isUsable }
        let widescreen = usable.filter { $0.element.isWidescreen }
        let pool = widescreen.isEmpty ? usable : widescreen
        return pool.max { $0.element.pixels < $1.element.pixels }?.offset
    }

    // MARK: - 旋转

    /// 把预览层交给控制器。`videoRotationAngleForHorizonLevelPreview`
    /// 在没有预览层时恒为 0，预览方向就对不上了。
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        rebuildRotationCoordinator(for: videoInput?.device)
    }

    private func rebuildRotationCoordinator(for device: AVCaptureDevice?) {
        rotationObservation = nil
        rotationCoordinator = nil
        guard let device else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            self?.applyRotation(
                preview: coordinator.videoRotationAngleForHorizonLevelPreview,
                capture: coordinator.videoRotationAngleForHorizonLevelCapture
            )
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
                  let connection = self.videoOutput.connection(with: .video),
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

                    if let connection = self.videoOutput.connection(with: .video) {
                        if connection.isVideoMirroringSupported {
                            connection.isVideoMirrored = device.position == .front
                        }
                    }

                    self.stateLock.lock()
                    self._position = device.position
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

    /// 只登记待录制的目标文件。真正的写入器要等第一帧到达，用画面的真实像素尺寸来建，
    /// 否则写死分辨率会让成片被拉伸。
    func startRecording() async throws {
        guard isConfigured else { throw CaptureError.cannotConfigure }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cueglide-\(Int(Date().timeIntervalSince1970)).mov")
        pendingRecordingURL = url
    }

    func stopRecording() async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            captureQueue.async { [weak self] in
                guard let self, let current = self.writer else {
                    continuation.resume(returning: nil)
                    return
                }
                self.writer = nil
                Task {
                    let url = await current.finish()
                    // 录制期间角度被锁住，设备如果在录制中转过，结束后不会再收到
                    // KVO 更新，必须主动重建一次，否则预览与采集都停在旧角度。
                    // AVCaptureDevice 不是 Sendable，这里按 position 重新取，
                    // 不跨队列传设备对象。
                    let position = self.position
                    DispatchQueue.main.async {
                        self.rebuildRotationCoordinator(for: Self.device(for: position))
                    }
                    continuation.resume(returning: url)
                }
            }
        }
    }
}

// MARK: - 采样回调

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            beginWriterIfNeeded(with: sampleBuffer)
            writer?.appendVideo(sampleBuffer)
        } else if output === audioOutput {
            writer?.appendAudio(sampleBuffer)
            onAudioSample?(sampleBuffer)
        }
    }
}

// MARK: - 首帧建写入器

extension CameraController {

    /// 用第一帧视频的真实宽高创建写入器。相机按设备方向旋转后输出的像素尺寸
    /// 由 connection 决定，不能假设固定比例。
    fileprivate func beginWriterIfNeeded(with sampleBuffer: CMSampleBuffer) {
        guard writer == nil,
              let url = pendingRecordingURL,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.height > 0 else { return }

        pendingRecordingURL = nil
        let size = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
        do {
            let newWriter = try RecordingWriter(outputURL: url, videoSize: size)
            writer = newWriter
            newWriter.start()
            log.info("录制开始：\(newWriter.summary, privacy: .public)")
        } catch {
            // 建不起来就把临时文件清掉，界面会因为没有写入器而回到未录制状态
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - 写入器

/// 把音视频采样写成 mov。运行在采集队列上，内部不再加锁。
final class RecordingWriter {

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let outputURL: URL
    private let videoSize: CGSize
    private let codec: AVVideoCodecType
    private var started = false
    private var sessionStarted = false

    init(outputURL: URL, videoSize: CGSize) throws {
        self.outputURL = outputURL
        self.videoSize = videoSize
        try? FileManager.default.removeItem(at: outputURL)

        let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer = assetWriter

        // HEVC 同画质码率约为 H.264 的一半，iPhone 全系有硬件编码；
        // 万一当前尺寸不支持再退回 H.264。
        let hevcSettings = Self.videoSettings(size: videoSize, codec: .hevc)
        let chosen: AVVideoCodecType =
            assetWriter.canApply(outputSettings: hevcSettings, forMediaType: .video) ? .hevc : .h264
        self.codec = chosen
        let videoSettings = Self.videoSettings(size: videoSize, codec: chosen)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100
        ]
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw CameraController.CaptureError.writerFailed("无法添加轨道")
        }
        writer.add(videoInput)
        writer.add(audioInput)
    }

    /// 按像素折算码率。之前不设码率，系统给的默认值在 1080p 以上明显偏紧，
    /// 4K 会糊成一片。系数按系统相机的实测水平取：HEVC 0.18 bit/像素/帧
    /// 对应 4K30 约 45Mbps，H.264 需要 0.26 才追得平。
    static func videoSettings(size: CGSize, codec: AVVideoCodecType) -> [String: Any] {
        let bitRate = Self.averageBitRate(for: size, codec: codec)

        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]
    }

    /// 码率按像素折算：0.18 bit/像素/帧对应 4K30 约 45Mbps，接近系统相机水平。
    /// 低于 8Mbps 时画面会明显发糊，设个下限兜住小尺寸。
    static func averageBitRate(for size: CGSize, codec: AVVideoCodecType) -> Int {
        let pixels = Double(size.width) * Double(size.height)
        let bitsPerPixel = codec == .hevc ? 0.18 : 0.26
        return max(8_000_000, Int(pixels * 30 * bitsPerPixel))
    }

    /// 成片里记录的编码器与分辨率，用于界面提示与排查。
    var summary: String {
        let dims = "\(Int(videoSize.width))×\(Int(videoSize.height))"
        return "\(dims) \(codec == .hevc ? "HEVC" : "H.264")"
    }

    func start() {
        guard writer.startWriting() else {
            return
        }
        started = true
    }

    func appendVideo(_ buffer: CMSampleBuffer) {
        guard started, writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        beginSessionIfNeeded(at: buffer)
        videoInput.append(buffer)
    }

    func appendAudio(_ buffer: CMSampleBuffer) {
        guard started, writer.status == .writing, audioInput.isReadyForMoreMediaData else { return }
        beginSessionIfNeeded(at: buffer)
        audioInput.append(buffer)
    }

    /// AVAssetWriter 没有可读的会话开始时间，只能自己记一个标志，首帧到达时开session。
    private func beginSessionIfNeeded(at buffer: CMSampleBuffer) {
        guard !sessionStarted else { return }
        sessionStarted = true
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
    }

    func finish() async -> URL? {
        guard started, writer.status == .writing else {
            writer.cancelWriting()
            return nil
        }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? outputURL : nil
    }
}
