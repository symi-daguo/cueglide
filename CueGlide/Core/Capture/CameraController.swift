import AVFoundation
import UIKit

/// 相机采集与录制。
///
/// 关键设计：音视频都走 DataOutput 手动写文件，不用 AVCaptureMovieFileOutput。
/// 原因是语音跟读也要麦克风，两条链路若各自开 session 会互相抢占；
/// 这里一次采集，音频只读一份，同时喂给录制写入器和语音识别。
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
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    /// 用锁保护跨队列读写的少量标量，录制写入器本身只在 captureQueue 上被操作。
    private let stateLock = NSLock()
    private var _writer: RecordingWriter?
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
        return _writer != nil
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

        session.sessionPreset = .high

        for input in session.inputs {
            session.removeInput(input)
        }

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
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
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
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = device.position == .front
            }
        }

        stateLock.lock()
        _position = device.position
        _isConfigured = true
        stateLock.unlock()
    }

    private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
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
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 录制

    func startRecording() async throws {
        guard isConfigured else { throw CaptureError.cannotConfigure }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                do {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("cueglide-\(Int(Date().timeIntervalSince1970)).mov")
                    let newWriter = try RecordingWriter(
                        outputURL: url,
                        videoSize: CGSize(width: 1080, height: 1920)
                    )
                    self.writer = newWriter
                    newWriter.start()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
            writer?.appendVideo(sampleBuffer)
        } else if output === audioOutput {
            writer?.appendAudio(sampleBuffer)
            onAudioSample?(sampleBuffer)
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
    private var started = false
    private var sessionStarted = false

    init(outputURL: URL, videoSize: CGSize) throws {
        self.outputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height)
        ]
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
