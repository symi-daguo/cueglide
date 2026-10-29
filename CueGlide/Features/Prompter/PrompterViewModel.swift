import SwiftUI
import UIKit
import Observation

@MainActor
@Observable
final class PrompterViewModel {

    let script: Script
    private(set) var tokenized: TokenizedScript
    let renderer: PrompterRenderer
    let engine = ScrollEngine()
    let tracker = SpeechTracker()

    var display: DisplayConfig
    var scroll: ScrollConfig

    var controlsVisible = true
    var showsSettings = false
    var isIdleTimerDisabled = false
    /// 当前正在调节哪一项，控制条据此展开对应的滑块。
    var adjustTarget: AdjustTarget = .none
    /// 语音跟读失败时的提示，非 nil 时弹横幅。
    var voiceAlert: String?

    enum AdjustTarget: Equatable {
        case none
        case fontSize
        case speed
    }

    @ObservationIgnored private var viewportSize: CGSize = .zero
    @ObservationIgnored private var hideControlsTask: Task<Void, Never>?
    @ObservationIgnored private var lastKnownToken: Int = 0

    init(script: Script, display: DisplayConfig, scroll: ScrollConfig) {
        self.script = script
        let tokenized = ScriptTokenizer.tokenize(script.body)
        self.tokenized = tokenized
        self.display = display
        self.scroll = scroll
        self.renderer = PrompterRenderer(tokenized: tokenized, config: display)
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

    // MARK: - 语音跟读

    func configureVoice(localeIdentifier: String) {
        tracker.prepare(tokenized: tokenized, localeIdentifier: localeIdentifier)
        tracker.resync(to: lastKnownToken)
    }

    var isVoiceActive: Bool { tracker.state.isActive }

    func toggleVoice() {
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
            await tracker.start()
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
