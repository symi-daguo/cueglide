import SwiftUI
import UIKit
import AVFoundation
import Speech
import Observation

@MainActor
@Observable
final class PrompterViewModel {

    let script: Script
    private(set) var tokenized: TokenizedScript
    let renderer: PrompterRenderer
    let engine = ScrollEngine()
    let tracker = SpeechTracker()
    let remote = RemoteController()

    var display: DisplayConfig
    var scroll: ScrollConfig

    var controlsVisible = true
    var showsSettings = false
    /// 当前正在调节哪一项，控制条据此展开对应的滑块。
    var adjustTarget: AdjustTarget = .none
    /// 语音跟读失败时的提示，非 nil 时弹横幅。
    var voiceAlert: String?
    /// 遥控按 Esc 时要求退出，由界面层关闭页面。
    @ObservationIgnored var onRequestExit: (() -> Void)?
    /// 是否允许开启语音跟读。录制页要关掉：录制本身占着麦克风，
    /// 跟读再开一个音频会话会把录音掐断，两条链路只能留一条。
    @ObservationIgnored var allowsVoiceTracking = true
    /// 拍摄时由相机提供音频：设置后跟读不再自己开音频引擎，
    /// 避免和录像抢麦克风把声音录成静音。
    @ObservationIgnored var externalAudioSource:
        ((Double, AVAudioChannelCount, AsyncStream<AudioChunk>.Continuation) -> Void)?

    enum AdjustTarget: Equatable {
        case none
        case fontSize
        case speed
    }

    @ObservationIgnored private var viewportSize: CGSize = .zero
    @ObservationIgnored private var hideControlsTask: Task<Void, Never>?
    @ObservationIgnored private var lastKnownToken: Int = 0

    init(script: Script, display: DisplayConfig, scroll: ScrollConfig, captureMode: Bool = false) {
        self.script = script
        let tokenized = ScriptTokenizer.tokenize(script.body)
        self.tokenized = tokenized
        self.display = display
        self.scroll = scroll
        self.renderer = PrompterRenderer(tokenized: tokenized, config: display, captureMode: captureMode)
        self.lastKnownToken = min(max(script.lastReadTokenIndex, 0), max(tokenized.totalTokens - 1, 0))

        engine.config = scroll
        engine.totalTokens = tokenized.totalTokens
        engine.onFrame = { [weak self] position in
            self?.handleFrame(position)
        }
        tracker.prepare(tokenized: tokenized, localeIdentifier: "")
        tracker.onAdvance = { [weak self] token in
            MainActor.assumeIsolated {
                self?.handleVoiceAdvance(token)
            }
        }

        remote.onCommand = { [weak self] command in
            MainActor.assumeIsolated {
                self?.handleRemote(command)
            }
        }

        renderer.hostView.onLayout = { [weak self] size in
            MainActor.assumeIsolated {
                self?.updateViewport(size)
            }
        }
    }

    // MARK: - 布局

    func updateViewport(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let widthChanged = abs(size.width - viewportSize.width) > 1
        viewportSize = size

        if widthChanged {
            renderer.apply(tokenized: tokenized, config: display, width: size.width)
            renderer.updateWidth(size.width)
        } else if !renderer.isMeasured {
            renderer.apply(tokenized: tokenized, config: display, width: size.width)
        }
        renderer.setViewportHeight(size.height)
        syncMetrics()
        renderer.scroll(toTokenPosition: Double(lastKnownToken), viewportHeight: size.height)
        renderer.highlight(currentToken: lastKnownToken)
    }

    /// 尺寸类变化时同步给渲染层。
    ///
    /// 布局判断只认尺寸类：Duo 内屏横放时宽高比像「横屏手机」，但尺寸类仍是
    /// regular × regular，应该继续用宽屏列宽，而不是压到 420。
    func updateTraits(isCompactHeight: Bool) {
        renderer.updateTraits(isCompactHeight: isCompactHeight)
        guard renderer.isMeasured else { return }
        syncMetrics()
        renderer.scroll(toTokenPosition: Double(lastKnownToken), viewportHeight: viewportSize.height)
    }

    private func syncMetrics() {
        engine.pointsPerToken = max(renderer.metrics.pointsPerToken, 1)
        engine.unitsPerToken = max(renderer.metrics.unitsPerToken, 0.1)
    }

    // MARK: - 播放控制

    func togglePlayback() {
        if engine.isRunning || engine.countdownRemaining > 0 {
            engine.pause()
            showControls()
        } else {
            engine.start()
            scheduleHideControls()
        }
    }

    func restart() {
        engine.reset()
        renderer.resetHighlight()
        renderer.scroll(toTokenPosition: 0, viewportHeight: viewportSize.height)
        lastKnownToken = 0
        showControls()
    }

    func seekToStartOfScreen(atViewportY y: CGFloat) {
        let index = renderer.tokenIndex(atViewportY: y)
        lastKnownToken = index
        engine.seek(toTokenPosition: Double(index))
        tracker.resync(to: index)
        showControls()
    }

    func nudge(tokens: Double) {
        let target = Double(lastKnownToken) + tokens
        lastKnownToken = Int(target.rounded())
        engine.seek(toTokenPosition: target)
        tracker.resync(to: lastKnownToken)
    }

    // MARK: - 进度跳转

    @ObservationIgnored private var wasRunningBeforeScrub = false

    /// 拖动进度条时先暂停，松手再恢复，避免自动滚动和手动定位互相打架。
    func handleScrub(_ isEditing: Bool) {
        if isEditing {
            wasRunningBeforeScrub = engine.isRunning
            if engine.isRunning {
                engine.pause()
            }
        } else if wasRunningBeforeScrub {
            wasRunningBeforeScrub = false
            engine.start()
        }
    }

    func seek(toProgress value: Double) {
        let total = max(tokenized.totalTokens - 1, 0)
        let target = min(max(value, 0), 1) * Double(total)
        lastKnownToken = Int(target.rounded())
        engine.seek(toTokenPosition: target)
        tracker.resync(to: lastKnownToken)
    }

    // MARK: - 遥控

    private func handleRemote(_ command: RemoteController.Command) {
        switch command {
        case .togglePlayback:
            togglePlayback()
        case .speedUp:
            adjustSpeed(factor: 1.15)
        case .speedDown:
            adjustSpeed(factor: 0.87)
        case .jumpForward:
            nudge(tokens: 12)
            showControls()
        case .jumpBackward:
            nudge(tokens: -12)
            showControls()
        case .restart:
            restart()
        case .exit:
            onRequestExit?()
        }
    }

    /// 界面上的速度加减。上一步 / 下一步都按 10% 走，四种模式下体感一致。
    func stepSpeed(_ direction: Int) {
        guard direction != 0 else { return }
        adjustSpeed(factor: direction > 0 ? 1.1 : 1 / 1.1)
    }

    /// 遥控调速按比例走，避免不同模式下步长不一致。
    private func adjustSpeed(factor: Double) {
        var next = scroll
        switch next.mode {
        case .constant:
            next.pointsPerSecond *= factor
        case .wpm:
            next.wordsPerMinute *= factor
        case .timed:
            next.targetDuration /= factor
        case .voice:
            return
        }
        applyScroll(next)
        showControls()
    }

    /// 由界面在出现时调用。放在这里而不是 init，是因为 @State 的初始化值
    /// 可能被 SwiftUI 多次求值，每求值一次就会多注册一组通知监听。
    func startRemote() {
        remote.start()
    }

    func stopRemote() {
        remote.stop()
    }

    /// 退出提词页时释放麦克风与识别器。
    ///
    /// 不停的话，音频会话会一直保持 active、AVAudioEngine 继续跑，麦克风被占着，
    /// 直到下次进页面手动关掉或系统把 App 挂起。跟读的启停是异步的，这里丢给
    /// 全局并发执行，不阻塞页面退出。
    func teardownVoice() {
        guard tracker.state.isActive else { return }
        Task { await tracker.stop() }
    }

    // MARK: - 语音跟读

    func configureVoice(localeIdentifier: String) {
        tracker.prepare(tokenized: tokenized, localeIdentifier: localeIdentifier)
        tracker.resync(to: lastKnownToken)
    }

    var isVoiceActive: Bool { tracker.state.isActive }

    func toggleVoice() {
        guard allowsVoiceTracking else {
            voiceAlert = "录制中无法使用语音跟读。录制和跟读都要占用麦克风，只能二选一。"
            return
        }
        if tracker.state.isActive {
            Task {
                await tracker.stop()
                if scroll.mode == .voice {
                    var next = scroll
                    next.mode = .constant
                    applyScroll(next)
                }
                showControls()
            }
            return
        }

        Task {
            await tracker.start(externalAudio: externalAudioSource)
            guard tracker.state == .listening else {
                if case .unavailable(let message) = tracker.state {
                    voiceAlert = message
                }
                return
            }
            tracker.resync(to: lastKnownToken)
            var next = scroll
            next.mode = .voice
            applyScroll(next)
            engine.seek(toTokenPosition: Double(lastKnownToken))
            showControls()
        }
    }

    var voiceHint: String {
        switch tracker.state {
        case .idle:
            ""
        case .preparing:
            "正在准备语音模型，首次使用需要下载"
        case .listening:
            tracker.latestTranscript.isEmpty
                ? "在听，直接开始读稿即可"
                : "听到：" + String(tracker.latestTranscript.suffix(16))
        case .unavailable(let message):
            message
        }
    }

    private func handleVoiceAdvance(_ token: Int) {
        lastKnownToken = token
        engine.seek(toTokenPosition: Double(token))
    }

    // MARK: - 参数

    func adjustFontSize(_ delta: Double) {
        var next = display
        next.fontSize += delta
        next.clamp()
        applyDisplay(next)
    }

    func applyDisplay(_ next: DisplayConfig) {
        var clamped = next
        clamped.clamp()
        display = clamped
        guard viewportSize.width > 1 else { return }
        renderer.apply(tokenized: tokenized, config: display, width: viewportSize.width)
        syncMetrics()
        renderer.scroll(toTokenPosition: Double(lastKnownToken), viewportHeight: viewportSize.height)
        renderer.highlight(currentToken: lastKnownToken)
    }

    func applyScroll(_ next: ScrollConfig) {
        var clamped = next
        clamped.clamp()
        scroll = clamped
        engine.config = clamped
    }

    // MARK: - 状态

    private func handleFrame(_ position: Double) {
        let index = Int(position.rounded())
        renderer.scroll(toTokenPosition: position, viewportHeight: viewportSize.height)
        renderer.highlight(currentToken: index)
        if index != lastKnownToken {
            lastKnownToken = index
        }
    }

    func showControls() {
        withAnimation(.smooth(duration: 0.22)) {
            controlsVisible = true
        }
        scheduleHideControls()
    }

    func scheduleHideControls() {
        hideControlsTask?.cancel()
        guard engine.isRunning, adjustTarget == .none else { return }
        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.engine.isRunning else { return }
                withAnimation(.smooth(duration: 0.28)) {
                    self.controlsVisible = false
                }
            }
        }
    }

    func saveProgress() {
        script.lastReadTokenIndex = lastKnownToken
    }

    var progressLabel: String {
        "\(lastKnownToken + 1) / \(max(tokenized.totalTokens, 1))"
    }

    var remainingSeconds: Int {
        guard tokenized.speechUnitCount > 0 else { return 0 }
        let remainingUnits = Double(tokenized.speechUnitCount)
            * (1 - Double(lastKnownToken) / Double(max(tokenized.totalTokens, 1)))
        let wpm = scroll.mode == .wpm ? scroll.wordsPerMinute : 240
        return Int((remainingUnits / wpm * 60).rounded())
    }
}
