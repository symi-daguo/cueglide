import SwiftUI
import AVFoundation
import Photos
import os

@MainActor
@Observable
final class CaptureViewModel {

    enum Phase: Equatable {
        case preparing
        case ready
        case recording
        case saving
        case failed(String)
    }

    let script: Script
    let camera = CameraController()
    let prompter: PrompterViewModel

    private(set) var phase: Phase = .preparing
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastSavedMessage: String?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startedAt: Date?

    init(script: Script, display: DisplayConfig, scroll: ScrollConfig) {
        self.script = script
        self.prompter = PrompterViewModel(
            script: script,
            display: display,
            scroll: scroll,
            captureMode: true
        )
        // 音频走相机的分流通道，录制和跟读可以同时用
        let camera = self.camera
        self.prompter.externalAudioSource = { sampleRate, channels, continuation in
            camera.attachSpeechAudio(
                sampleRate: sampleRate,
                channels: channels,
                continuation: continuation
            )
        }
    }

    var isRecording: Bool { phase == .recording }
    var isAvailable: Bool {
        if case .failed = phase { return false }
        return true
    }

    // MARK: - 生命周期

    func prepare() async {
        phase = .preparing
        do {
            try await camera.configure(position: .front)
            camera.start()
            phase = .ready
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-autoVoice") {
                try? await Task.sleep(for: .seconds(2))
                toggleVoice()
                try? await Task.sleep(for: .seconds(4))
            }
            await runAutoRecordIfRequested()
            #endif
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    var isVoiceActive: Bool { prompter.isVoiceActive }

    func toggleVoice() {
        prompter.toggleVoice()
    }

    func teardown() {
        stopTimer()
        camera.detachSpeechAudio()
        camera.stop()
        if camera.isRecording {
            let camera = self.camera
            Task { _ = await camera.stopRecording() }
        }
    }

    // MARK: - 录制

    func toggleRecording() {
        switch phase {
        case .ready:
            Task { await startRecording() }
        case .recording:
            Task { await stopRecording() }
        default:
            break
        }
    }

    private func startRecording() async {
        do {
            try await camera.startRecording()
            startedAt = Date()
            elapsed = 0
            phase = .recording
            startTimer()

            // 录制时提词自动开始滚动，用户不需要再点一次播放
            if !prompter.engine.isRunning {
                prompter.togglePlayback()
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func stopRecording() async {
        stopTimer()
        if prompter.engine.isRunning {
            prompter.togglePlayback()
        }

        phase = .saving
        guard let url = await camera.stopRecording() else {
            phase = .ready
            return
        }

        do {
            try await saveToPhotoLibrary(url: url)
            let info = await Self.recordingInfo(for: url)
            lastSavedMessage = info.map { "已保存到相册 · \($0)" } ?? "已保存到相册"
        } catch {
            lastSavedMessage = "保存失败：\(error.localizedDescription)"
        }

        // 取证用：把成片复制到 Documents，可以用 devicectl 拷出来做逐项对比。
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-keepRecording") {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let isLarge = !ProcessInfo.processInfo.arguments.contains("-use4KHDR")
            let name = isLarge ? "capture-large.mov" : "capture-4k.mov"
            let dest = docs.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        #endif

        try? FileManager.default.removeItem(at: url)
        phase = .ready
    }

    #if DEBUG
    /// 自动录一段，用于抓取画质取证样本，不需要人工点按。
    func runAutoRecordIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-autoRecord") else { return }
        guard phase == .ready else { return }

        await startRecording()
        try? await Task.sleep(for: .seconds(5))
        guard phase == .recording else { return }
        await stopRecording()
    }
    #endif

    /// 读成片实际写入的分辨率与编码器。拍摄参数是否真的生效，
    /// 看这一行就够了，不用去相册翻详情。
    private static func recordingInfo(for url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let formats = try? await track.load(.formatDescriptions),
              let format = formats.first else { return nil }

        let codecName: String
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMVideoCodecType_HEVC: codecName = "HEVC"
        case kCMVideoCodecType_H264: codecName = "H.264"
        default: codecName = "未知编码"
        }

        // 从轨道元数据里读真实码率与传递函数，确认 HDR 确实写进了文件，
        // 而不是只在采集端开了、写的时候又退回 SDR。
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any]
        let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let isHDR = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        let bitrate = (try? await track.load(.estimatedDataRate)).map { $0 / 1_000_000 }

        var parts = ["\(Int(size.width))×\(Int(size.height))", codecName]
        if isHDR { parts.append("HDR") }
        if let bitrate { parts.append(String(format: "%.0fMbps", bitrate)) }

        let summary = parts.joined(separator: " ")
        Logger(subsystem: "com.symi.cueglide", category: "Capture")
            .info("成片参数：\(summary, privacy: .public)")
        return summary
    }

    private func saveToPhotoLibrary(url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(
                domain: "CueGlide",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "没有相册写入权限"]
            )
        }
        try await Self.addVideoAsset(at: url)
    }

    /// 必须放在 `nonisolated` 里。
    ///
    /// `performChanges` 的闭包由 Photos 在后台事务队列
    /// （com.apple.PHPhotoLibrary.transaction）执行，而它是在 `@MainActor` 类里
    /// 定义的：非 Sendable 闭包会继承主执行器隔离，一进闭包就断言失败、SIGTRAP。
    /// 表现就是录制完点停止，保存时闪退。
    private nonisolated static func addVideoAsset(at url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    // MARK: - 其他

    func switchCamera() async {
        guard !isRecording else { return }
        try? await camera.switchCamera()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
    }

    var elapsedLabel: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
