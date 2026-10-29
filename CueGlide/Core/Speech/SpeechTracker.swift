import Foundation
import Speech
import AVFoundation
import Observation

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
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var continuation: AsyncStream<AnalyzerInput>.Continuation?
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

    func start() async {
        guard state != .listening, state != .preparing else { return }
        guard let aligner, !aligner.isEmpty else {
            state = .unavailable("台本内容为空，无法跟读")
            return
        }

        state = .preparing
        accumulated = ""
        pendingJumpToken = nil
        latestTranscript = ""

        do {
            try await requestPermissions()
            let locale = resolveLocale()
            try await prepareAnalyzer(locale: locale)
            try startAudioEngine()
            state = .listening
        } catch {
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
        let micGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard micGranted else {
            throw TrackerError.microphoneDenied
        }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw TrackerError.speechDenied
        }
    }

    // MARK: - 识别器

    private func resolveLocale() -> Locale {
        let trimmed = localeIdentifier.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Locale.current : Locale(identifier: trimmed)
    }

    private func prepareAnalyzer(locale: Locale) async throws {
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
        configureCapture(format: analyzerFormat)
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

    @ObservationIgnored private var converter: AVAudioConverter?
    @ObservationIgnored private var captureFormat: AVAudioFormat?

    private func configureCapture(format: AVAudioFormat) {
        captureFormat = format
    }

    private func startAudioEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: [])

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw TrackerError.micUnavailable
        }

        let targetFormat = captureFormat ?? inputFormat
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // 音频线程：只做格式转换与投递，不碰主线程状态
            let outBuffer = Self.convert(buffer, using: converter, to: targetFormat) ?? buffer
            self.continuation?.yield(AnalyzerInput(buffer: outBuffer))
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
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

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        continuation?.finish()
        continuation = nil

        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil
        transcriber = nil
        converter = nil
        captureFormat = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - 错误

    enum TrackerError: LocalizedError {
        case microphoneDenied
        case speechDenied
        case micUnavailable
        case audioFormatUnavailable
        case unsupportedLocale(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "没有麦克风权限。到系统设置里允许 CueGlide 使用麦克风再试。"
            case .speechDenied:
                "没有语音识别权限。到系统设置里允许 CueGlide 使用语音识别再试。"
            case .micUnavailable:
                "当前没有可用的麦克风输入。"
            case .audioFormatUnavailable:
                "无法准备语音识别的音频格式。"
            case .unsupportedLocale(let name):
                "当前系统语言（\(name)）暂不支持端侧跟读，可以在设置里手动指定识别语言。"
            }
        }
    }
}
