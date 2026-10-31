import AVFoundation
import os

/// 跨隔离传递的音频帧。
///
/// `AVAudioPCMBuffer` 本身不是 Sendable，但这里的缓冲是刚由转换器新建、
/// 投递后不再被采集队列改写，独占所有权，所以可以安全跨队列。
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// buffer 在整条流里的起始时间。必须是严格单调递增的精确值，
    /// 用「总帧数 / 采样率」算秒再转 CMTime 会因浮点漂移产生重复时间戳，
    /// 引擎会以 `Audio input timestamp overlaps or precedes prior audio input` 中止。
    let startTime: CMTime
}

/// 识别器要求的音频格式描述。
///
/// 必须原样传递 `AVAudioFormat` 的 ASBD，不能自己用
/// `standardFormatWithSampleRate` 重拼：识别器可能要求 Int16 或交错排列，
/// 格式对不上时 `AnalyzerInput.init(buffer:)` 会直接断言失败。
struct AudioFormatSpec: @unchecked Sendable {
    let streamDescription: AudioStreamBasicDescription

    init(_ format: AVAudioFormat) {
        streamDescription = format.streamDescription.pointee
    }

    func makeFormat() -> AVAudioFormat? {
        var description = streamDescription
        return AVAudioFormat(streamDescription: &description)
    }

    var summary: String {
        "\(streamDescription.mSampleRate)Hz \(streamDescription.mChannelsPerFrame)ch \(streamDescription.mBitsPerChannel)bit flags=\(streamDescription.mFormatFlags)"
    }
}

/// 把相机采集的音频转成 `AnalyzerInput`，供 `SpeechAnalyzer` 实时识别。
///
/// 存在的理由：录制和语音跟读都要麦克风，各自开一套 `AVAudioEngine` 会互相抢占，
/// 录制出来就是静音。这里复用相机那一路音频，分流一份给识别器，两个功能才能同时用。
///
/// 线程模型：`handle` 在 `AVCaptureAudioDataOutput` 的采集队列上被调用，
/// 所以这个类型不是 `@MainActor`，内部状态只在该队列上访问。标注
/// `@unchecked Sendable` 就是在声明这个约定。
final class CameraAudioBridge: @unchecked Sendable {

    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var chunkCount = 0
    private var reportedFormat = false
    /// 已投递的输出帧总数，用来生成精确时间戳。
    private var accumulatedFrames: AVAudioFramePosition = 0
    private let log = Logger(subsystem: "com.symi.cueglide", category: "CameraAudioBridge")

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    /// 采集队列上只做格式转换。
    ///
    /// `AnalyzerInput.init(buffer:)` 内部有执行器要求，在这里构造会直接
    /// `_dispatch_assert_queue_fail` / SIGTRAP，所以只投递裸缓冲，
    /// 由消费方在主线程包装。
    func handle(
        _ sampleBuffer: CMSampleBuffer,
        continuation: AsyncStream<AudioChunk>.Continuation
    ) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else {
            if chunkCount == 0 { log.error("相机音频无法转成 PCM") }
            return
        }

        if !reportedFormat {
            reportedFormat = true
            let targetRate = targetFormat.sampleRate
            log.info(
                "相机音频首帧：\(pcm.format.sampleRate, privacy: .public)Hz \(pcm.format.channelCount, privacy: .public)ch \(pcm.frameLength, privacy: .public) 帧 → 目标 \(targetRate, privacy: .public)Hz"
            )
        }

        guard let output = converted(pcm) ?? Optional(pcm), output.frameLength > 0 else {
            // 0 帧 buffer 会制造重复时间戳，必须丢弃
            return
        }

        let startTime = CMTime(
            value: accumulatedFrames,
            timescale: CMTimeScale(targetFormat.sampleRate)
        )
        accumulatedFrames += AVAudioFramePosition(output.frameLength)

        chunkCount += 1
        if chunkCount == 50 {
            log.info(
                "相机音频已投递 50 帧，累计 \(self.accumulatedFrames, privacy: .public) 帧"
            )
        }
        #if DEBUG
        if chunkCount % 30 == 1 {
            // 顺带算一下响度，用来区分「麦克风没收到声音」和「识别器不出结果」
            var level: Int64 = 0
            if let samples = output.int16ChannelData?[0] {
                var sum: Int64 = 0
                for index in 0..<Int(output.frameLength) {
                    sum += Int64(abs(Int(samples[index])))
                }
                level = sum / Int64(max(1, output.frameLength))
            }
            print("[Audio] 第 \(chunkCount) 包 \(output.frameLength) 帧 响度 \(level)")
        }
        #endif
        continuation.yield(AudioChunk(buffer: output, startTime: startTime))
    }

    /// 相机给的是 44.1/48kHz，识别器通常要 16kHz，必须重采样。
    private func converted(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Logger 的字符串插值是 autoclosure，里面引用属性必须显式 self，
        // 否则编译器要求写出捕获语义；这里先取成局部常量更干净。
        let targetRate = targetFormat.sampleRate
        let target = targetFormat

        if sourceFormat != buffer.format {
            sourceFormat = buffer.format
            let newConverter = AVAudioConverter(from: buffer.format, to: target)
            // 默认的 priming 会为了音质补偿首帧，代价是时间戳漂移；转写不需要这个
            newConverter?.primeMethod = .none
            converter = newConverter
            if converter == nil {
                log.error(
                    "相机音频 \(buffer.format.sampleRate, privacy: .public)Hz 无法转到 \(targetRate, privacy: .public)Hz"
                )
            }
        }
        guard let converter else { return nil }

        let ratio = targetRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
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

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
              ) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
