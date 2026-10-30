import AVFoundation
import Speech
import os

/// 麦克风采集与格式转换，产出 `AnalyzerInput` 交给 `SpeechAnalyzer`。
///
/// 类本身是 `@MainActor`：引擎、转换器、tap 状态都只在主线程读写，不用额外加锁。
///
/// 但**安装 tap 这一步必须放在 `nonisolated static` 里**，原因在 SDK 的类型标注：
///
/// ```objc
/// typedef void (^ NS_SWIFT_NONSENDABLE AVAudioNodeTapBlock)(AVAudioPCMBuffer *, AVAudioTime *);
/// ```
///
/// `NS_SWIFT_NONSENDABLE` 表示它不被当作 `@Sendable`。Swift 6 的规则是：在
/// `@MainActor` 上下文里定义的非 Sendable 闭包会**继承该隔离**，编译器在闭包入口
/// 插入 `_checkExpectedExecutor` 断言。而 AVAudioEngine 的 tap 回调跑在实时线程
/// （RealtimeMessenger 队列），一进闭包就断言失败、SIGTRAP —— 表现就是真机上点
/// 「跟读」立刻闪退。
///
/// 这类崩溃模拟器上看不到：模拟器音频栈走主线程，断言恰好成立。
///
/// 放进 `nonisolated static` 后，闭包不继承任何执行器；闭包只捕获局部常量与
/// Sendable 的 continuation，不引用 `self`，实时线程上没有任何跨隔离访问。
@MainActor
final class SpeechAudioCapture {

    enum CaptureError: LocalizedError {
        case micUnavailable

        var errorDescription: String? {
            "当前没有可用的麦克风输入。"
        }
    }

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private let log = Logger(subsystem: "com.symi.cueglide", category: "SpeechAudioCapture")

    /// 开始采集。音频经转换后直接投递到 `continuation`，由 `SpeechAnalyzer` 消费。
    func start(
        targetFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) async throws {
        // `.record` 类别只能配 `.measurement` / `.default` 这类模式。
        // SDK 对 `.duckOthers` 的说明是「only valid with Ambient / PlayAndRecord /
        // Playback / MultiRoute」，配 `.record` 会抛 IncompatibleCategory，
        // 结果是跟读永远起不来。
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])

        // 同步版 setActive 在主线程会让 UI 卡顿（AVAudioSession 自己会打警告），
        // iOS 27 起提供了异步的 activate/deactivate，优先用新的。
        if #available(iOS 27, *) {
            try await session.activate(options: [])
        } else {
            try session.setActive(true, options: [])
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.micUnavailable
        }

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        if converter == nil {
            log.error("无法建立格式转换器，按原始格式透传")
        }

        Self.installTap(
            on: input,
            format: inputFormat,
            converter: converter,
            targetFormat: targetFormat,
            continuation: continuation
        )
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            await stop()
            throw error
        }

        log.info(
            "音频采集已启动：输入 \(inputFormat.sampleRate, privacy: .public)Hz \(inputFormat.channelCount, privacy: .public)ch → 目标 \(targetFormat.sampleRate, privacy: .public)Hz"
        )
    }

    func stop() async {
        // 没装过 tap 就调 removeTap，AVAudioNode 会抛 ObjC 异常（不是 Swift error，
        // catch 不住）直接崩溃，所以必须先判断。
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }

        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27, *) {
            _ = try? await session.deactivate(options: [.notifyOthersOnDeactivation])
        } else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
        log.info("音频采集已停止")
    }

    // MARK: - 实时线程路径

    /// 在非隔离上下文安装 tap。
    ///
    /// 这个函数和它里面的闭包都不带 `@MainActor`，所以闭包不会继承主执行器隔离，
    /// 编译器也不会往闭包入口插隔离断言。这是「点跟读就闪退」的根因所在，
    /// 改动前请先读类型注释里的 SDK 证据。
    private nonisolated static func installTap(
        on input: AVAudioNode,
        format: AVAudioFormat,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let output = convert(buffer, using: converter, to: targetFormat) ?? buffer
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }

    /// 实时线程上的格式转换。不触碰任何实例状态。
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
}
