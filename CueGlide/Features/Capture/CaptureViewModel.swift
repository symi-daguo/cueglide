import SwiftUI
import AVFoundation
import Photos

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
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func teardown() {
        stopTimer()
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
            lastSavedMessage = "已保存到相册"
        } catch {
            lastSavedMessage = "保存失败：\(error.localizedDescription)"
        }

        try? FileManager.default.removeItem(at: url)
        phase = .ready
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
