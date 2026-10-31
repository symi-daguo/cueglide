import Foundation
import UIKit
import Observation

/// 提词滚动引擎。位置坐标统一用「浮点词索引」，不用像素，
/// 这样换字号、换行距之后阅读进度不会丢。
@MainActor
@Observable
final class ScrollEngine {

    // MARK: - 对 UI 暴露的状态（低频更新，供 SwiftUI 读取）

    private(set) var displayPosition: Double = 0
    private(set) var isRunning: Bool = false
    private(set) var isFinished: Bool = false
    private(set) var countdownRemaining: Int = 0
    private(set) var elapsed: TimeInterval = 0

    // MARK: - 高频实时状态（不参与 SwiftUI 观察）

    @ObservationIgnored private(set) var livePosition: Double = 0
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval = 0
    @ObservationIgnored private var startPosition: Double = 0
    @ObservationIgnored private var frameCounter = 0
    @ObservationIgnored private var countdownDeadline: CFTimeInterval?

    // 帧率采样，仅当启动参数带 -fpsProbe 时激活，用于性能验证
    @ObservationIgnored private let fpsProbeEnabled = ProcessInfo.processInfo.arguments.contains("-fpsProbe")
    @ObservationIgnored private var probeFrames = 0
    @ObservationIgnored private var probeDropped = 0
    @ObservationIgnored private var probeLastReport = CFAbsoluteTimeGetCurrent()
    @ObservationIgnored private var probeMaxGap: Double = 0

    /// 每帧回调，参数是当前浮点词索引。渲染层在这里直接改 contentOffset，不经过 SwiftUI。
    @ObservationIgnored var onFrame: ((Double) -> Void)?

    // MARK: - 输入参数

    var config: ScrollConfig = .default {
        didSet {
            if isRunning, config.mode == .timed { restartTimedBaseline() }
        }
    }

    var totalTokens: Int = 0
    /// 平均每个词占多少点高度，由排版层测量后回填。
    var pointsPerToken: Double = 40
    /// 平均每个词包含多少朗读单位，由分词层回填。
    var unitsPerToken: Double = 1.4

    // MARK: - 生命周期

    func start() {
        guard totalTokens > 0 else { return }
        if isFinished { reset() }

        if countdownRemaining == 0, config.countdown > 0, livePosition == startPosition {
            beginCountdown()
            return
        }
        resume()
    }

    func pause() {
        stopDisplayLink()
        isRunning = false
        countdownDeadline = nil
        countdownRemaining = 0
        syncDisplayPosition()
    }

    func toggle() {
        if isRunning || countdownRemaining > 0 {
            pause()
        } else {
            start()
        }
    }

    func reset() {
        stopDisplayLink()
        voiceTarget = nil
        isRunning = false
        isFinished = false
        countdownRemaining = 0
        countdownDeadline = nil
        elapsed = 0
        livePosition = 0
        startPosition = 0
        displayPosition = 0
        onFrame?(0)
    }

    /// 跟读模式的目标位置。引擎每帧按固定比例逼近它，形成平滑滚动，
    /// 而不是每次命中就瞬间跳过去（那会让画面「卡住再一闪到位置」）。
    private var voiceTarget: Double?

    /// 跟读命中时调用：设定目标位置并保证引擎在跑。
    func followVoice(toTokenPosition position: Double) {
        let clamped = min(max(position, 0), Double(max(totalTokens - 1, 0)))
        voiceTarget = clamped
        if !isRunning {
            resume()
        }
    }

    func seek(toTokenPosition position: Double) {
        let clamped = min(max(position, 0), Double(max(totalTokens - 1, 0)))
        livePosition = clamped
        isFinished = false
        if config.mode == .timed {
            restartTimedBaseline()
        }
        onFrame?(clamped)
        syncDisplayPosition()
    }

    func nudge(byTokens delta: Double) {
        seek(toTokenPosition: livePosition + delta)
    }

    // MARK: - 内部推进

    private func beginCountdown() {
        countdownRemaining = config.countdown
        let deadline = CACurrentMediaTime() + Double(config.countdown)
        countdownDeadline = deadline
        isRunning = true
        startDisplayLink()
    }

    private func resume() {
        isRunning = true
        isFinished = false
        startPosition = livePosition
        elapsed = 0
        restartTimedBaseline()
        startDisplayLink()
    }

    private func restartTimedBaseline() {
        startPosition = livePosition
        elapsed = 0
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = 0
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = 0
    }

    @objc private func handleTick(_ link: CADisplayLink) {
        let now = link.timestamp

        // 倒计时阶段
        if let deadline = countdownDeadline {
            let remaining = Int(ceil(deadline - now))
            countdownRemaining = max(remaining, 0)
            if now >= deadline {
                countdownDeadline = nil
                countdownRemaining = 0
                lastTimestamp = now
                startPosition = livePosition
                elapsed = 0
            }
            return
        }

        guard isRunning else { return }
        if lastTimestamp == 0 {
            lastTimestamp = now
            return
        }

        let rawDelta = now - lastTimestamp
        let delta = min(rawDelta, 0.125)
        lastTimestamp = now
        elapsed += delta

        if fpsProbeEnabled {
            probeFrames += 1
            probeMaxGap = max(probeMaxGap, rawDelta)
            // 120Hz 下正常帧间隔 8.3ms，超过 26ms 记一次掉帧
            if rawDelta > 0.026 {
                probeDropped += 1
            }
            let clock = CFAbsoluteTimeGetCurrent()
            if clock - probeLastReport >= 2 {
                let ratio = Double(probeDropped) / Double(max(probeFrames, 1)) * 100
                NSLog("[FPS] 帧数=%d 掉帧=%d 掉帧率=%.1f%% 最大间隔=%.0fms",
                      probeFrames, probeDropped, ratio, probeMaxGap * 1000)
                probeFrames = 0
                probeDropped = 0
                probeMaxGap = 0
                probeLastReport = clock
            }
        }

        var next = livePosition

        switch config.mode {
        case .constant:
            let tokensPerSecond = config.pointsPerSecond / max(pointsPerToken, 1)
            next += tokensPerSecond * delta

        case .wpm:
            let tokensPerSecond = (config.wordsPerMinute / 60) / max(unitsPerToken, 0.1)
            next += tokensPerSecond * delta

        case .timed:
            let duration = max(config.targetDuration, 1)
            let progress = min(elapsed / duration, 1)
            next = startPosition + (Double(totalTokens) - startPosition) * progress

        case .voice:
            // 跟读模式由 SpeechTracker 通过 followVoice 设定目标，这里每帧平滑逼近。
            // 直接 seek 会让画面「卡住 → 瞬间跳到位置」，观感不像提词器。
            if let target = voiceTarget {
                let gap = target - livePosition
                if abs(gap) <= 0.35 {
                    next = target
                    voiceTarget = nil
                } else {
                    // 每秒约 2 词左右的上限，避免跳段时画面飞过去
                    let maxStep = 1.2 * delta
                    let step = min(abs(gap) * 6.0 * delta + 0.02, maxStep)
                    next = livePosition + (gap > 0 ? step : -step)
                    if abs(target - next) <= 0.35 {
                        next = target
                        voiceTarget = nil
                    }
                }
            } else {
                next = livePosition
            }
        }

        let upperBound = Double(max(totalTokens - 1, 0))
        if next >= upperBound {
            next = upperBound
            livePosition = next
            onFrame?(next)
            finish()
            return
        }

        livePosition = next
        onFrame?(next)

        // 每 6 帧同步一次低频状态给 SwiftUI，约 20Hz，足够进度条使用。
        frameCounter += 1
        if frameCounter >= 6 {
            frameCounter = 0
            displayPosition = next
        }
    }

    private func finish() {
        stopDisplayLink()
        isRunning = false
        isFinished = true
        countdownRemaining = 0
        syncDisplayPosition()
    }

    private func syncDisplayPosition() {
        displayPosition = livePosition
    }

    // MARK: - 派生量

    /// 当前进度 0...1
    var progress: Double {
        guard totalTokens > 1 else { return 0 }
        return min(max(displayPosition / Double(totalTokens - 1), 0), 1)
    }

    /// 恒速模式下当前每秒滚动的点数，用于 UI 显示。
    var effectivePointsPerSecond: Double {
        switch config.mode {
        case .constant:
            config.pointsPerSecond
        case .wpm:
            (config.wordsPerMinute / 60) / max(unitsPerToken, 0.1) * pointsPerToken
        case .timed:
            totalTokens > 0 ? Double(totalTokens) / max(config.targetDuration, 1) * pointsPerToken : 0
        case .voice:
            0
        }
    }
}
