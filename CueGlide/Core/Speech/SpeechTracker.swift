import Foundation
import Speech
import AVFoundation
import Observation
import os

/// 端侧语音跟读。用 iOS 26 的 SpeechAnalyzer 做流式转写，把识别结果交给 ScriptAligner
/// 推算出当前读到的位置，再驱动提词滚动。
///
/// 全程在设备上完成，音频不出本机。
@MainActor
@Observable
final class SpeechTracker {

    enum TrackingState: Equatable {
        case idle
        case preparing
        case listening
        case unavailable(String)

        var isActive: Bool {
            self == .listening || self == .preparing
        }
    }

    private(set) var state: TrackingState = .idle
    /// 最近一次识别出的文本，用于在界面上给用户确认「确实在听」。
    private(set) var latestTranscript: String = ""
    /// 最近命中的词索引。
    private(set) var matchedToken: Int = 0

    /// 命中新位置时回调。
    @ObservationIgnored var onAdvance: ((Int) -> Void)?

    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var transcriber: SpeechTranscriber?
    @ObservationIgnored private var capture: SpeechAudioCapture?
    @ObservationIgnored private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private let log = Logger(subsystem: "com.symi.cueglide", category: "SpeechTracker")
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var aligner: ScriptAligner?
    @ObservationIgnored private var accumulated = ""
    @ObservationIgnored private var anchorToken = 0
    @ObservationIgnored private var pendingJumpToken: Int?
    @ObservationIgnored private var localeIdentifier = ""

    // MARK: - 准备

    func prepare(tokenized: TokenizedScript, localeIdentifier: String) {
        aligner = ScriptAligner(tokenized: tokenized)
        self.localeIdentifier = localeIdentifier
    }

    /// 用户手动滚动或跳转后，重置对齐锚点，避免旧累积文本把位置拉回去。
    func resync(to token: Int) {
        anchorToken = token
        matchedToken = token
        accumulated = ""
        pendingJumpToken = nil
    }

    // MARK: - 启停

    /// 启动跟读。
    ///
    /// `externalAudio` 不为空时表示音频由外部提供（拍摄时来自相机），此时不自己
    /// 开音频引擎——录制和跟读抢麦克风会录成静音。参数是采样率、声道数和投递流，
    /// 全是 Sendable，可以安全跨到采集队列。
    func start(
        externalAudio: ((Double, AVAudioChannelCount, AsyncStream<AnalyzerInput>.Continuation) -> Void)? = nil
    ) async {
        guard state != .listening, state != .preparing else { return }
        guard let aligner, !aligner.isEmpty else {
            state = .unavailable("台本内容为空，无法跟读")
            return
        }

        state = .preparing
        accumulated = ""
        pendingJumpToken = nil
        latestTranscript = ""

        log.info("开始准备语音跟读")
        do {
            try await requestPermissions()
            log.info("麦克风与语音识别权限已获取")
            let locale = resolveLocale()
            let format = try await prepareAnalyzer(locale: locale)
            if let externalAudio, let continuation {
                externalAudio(format.sampleRate, format.channelCount, continuation)
                log.info("语音跟读已接管相机音频")
            } else {
                try await startCapture(format: format)
            }
            state = .listening
            log.info("语音跟读已进入监听状态")
        } catch {
            log.error("语音跟读启动失败：\(error.localizedDescription, privacy: .public)")
            await teardown()
            state = .unavailable(error.localizedDescription)
        }
    }

    func stop() async {
        await teardown()
        state = .idle
    }

    // MARK: - 权限

    private func requestPermissions() async throws {
        let micGranted = await Self.requestRecordPermission()
        guard micGranted else {
            throw TrackerError.microphoneDenied
        }

        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            throw TrackerError.speechDenied
        }
    }

    /// 这两个请求必须放在 `nonisolated` 里。
    ///
    /// 系统的权限回调（TCC）跑在后台队列。如果直接在 `@MainActor` 方法里用
    /// `withCheckedContinuation`，continuation 会绑定到主执行器，后台 `resume` 时
    /// Swift 6 的隔离断言会直接触发 SIGTRAP——真机上点「跟读」就闪退，模拟器因
    /// 权限已缓存、不走回调，所以一直没暴露。
    private nonisolated static func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - 识别器

    private func resolveLocale() -> Locale {
        let trimmed = localeIdentifier.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Locale.current : Locale(identifier: trimmed)
    }

    /// 准备识别器，返回它期望的音频格式。
    private func prepareAnalyzer(locale: Locale) async throws -> AVAudioFormat {
        let supported = await SpeechTranscriber.supportedLocales
        let target = locale.identifier(.bcp47)
        guard supported.contains(where: { $0.identifier(.bcp47) == target }) else {
            throw TrackerError.unsupportedLocale(locale.localizedString(forIdentifier: target) ?? target)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        // 首次使用某个语言时需要下载端侧模型
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw TrackerError.audioFormatUnavailable
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.continuation = continuation

        try await analyzer.start(inputSequence: stream)
        startConsumingResults(transcriber: transcriber)
        log.info("识别器已启动，目标格式 \(analyzerFormat.sampleRate, privacy: .public)Hz")
        return analyzerFormat
    }

    private func startConsumingResults(transcriber: SpeechTranscriber) {
        resultsTask?.cancel()
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    let text = String(result.text.characters)
                    self?.handle(transcript: text)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .unavailable(error.localizedDescription)
            }
        }
    }

    // MARK: - 音频采集

    /// 采集放在 `SpeechAudioCapture` 里——那个类不带 `@MainActor`，
    /// 音频 tap 闭包才不会继承主执行器隔离，否则实时线程一回调就 SIGTRAP。
    private func startCapture(format: AVAudioFormat) async throws {
        guard let continuation else {
            throw TrackerError.audioFormatUnavailable
        }
        let capture = SpeechAudioCapture()
        try await capture.start(targetFormat: format, continuation: continuation)
        self.capture = capture
    }

    // MARK: - 对齐

    private func handle(transcript: String) {
        guard let aligner else { return }
        latestTranscript = transcript

        let normalized = ScriptTokenizer.normalize(transcript)
        guard !normalized.isEmpty else { return }

        accumulated.append(normalized)
        if accumulated.count > 80 {
            accumulated = String(accumulated.suffix(60))
        }

        guard let match = aligner.align(spoken: accumulated, currentToken: anchorToken) else {
            return
        }

        // 大跨度跳转要连续两次指向同一片区域才认，避免某个词碰巧匹配导致画面乱跳
        let needsConfirmation = abs(match.distance) > 24
        if needsConfirmation {
            if let pending = pendingJumpToken, abs(pending - match.tokenIndex) <= 8 {
                pendingJumpToken = nil
                commit(token: match.tokenIndex)
            } else {
                pendingJumpToken = match.tokenIndex
            }
            return
        }

        pendingJumpToken = nil
        commit(token: match.tokenIndex)
    }

    private func commit(token: Int) {
        guard token != matchedToken else { return }
        matchedToken = token
        anchorToken = token
        // 位置稳定后清空累积文本，避免旧内容持续把位置压在原地
        if accumulated.count > 24 {
            accumulated = String(accumulated.suffix(12))
        }
        onAdvance?(token)
    }

    // MARK: - 清理

    private func teardown() async {
        resultsTask?.cancel()
        resultsTask = nil

        await capture?.stop()
        capture = nil

        continuation?.finish()
        continuation = nil

        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil
        transcriber = nil
    }

    // MARK: - 错误

    enum TrackerError: LocalizedError {
        case microphoneDenied
        case speechDenied
        case audioFormatUnavailable
        case unsupportedLocale(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "没有麦克风权限。到系统设置里允许 CueGlide 使用麦克风再试。"
            case .speechDenied:
                "没有语音识别权限。到系统设置里允许 CueGlide 使用语音识别再试。"
            case .audioFormatUnavailable:
                "无法准备语音识别的音频格式。"
            case .unsupportedLocale(let name):
                "当前系统语言（\(name)）暂不支持端侧跟读，可以在设置里手动指定识别语言。"
            }
        }
    }
}
