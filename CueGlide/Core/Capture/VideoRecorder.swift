import AVFoundation

/// 视频录制器：VideoDataOutput 采样 + AssetWriter 落盘。
///
/// 为什么不用 `AVCaptureMovieFileOutput`：它的录制方向只跟设备物理方向，
/// 往 connection 写 `videoRotationAngle` 对成片无效（实测写入 0 度仍是竖的），
/// 做不到「竖着拿也能拍横片」。走 DataOutput 才能让方向真正可控。
///
/// 编码参数刻意只声明编码器与尺寸，不设码率、不设压缩属性——那部分交给系统
/// 默认策略，避免像早先那样手调码率反而把画质带偏。
final class VideoRecorder {

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let outputURL: URL
    private var started = false
    private var sessionStarted = false

    init(url: URL, size: CGSize) throws {
        outputURL = url
        try? FileManager.default.removeItem(at: url)

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let hevcSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let h264Settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let videoSettings = writer.canApply(outputSettings: hevcSettings, forMediaType: .video)
            ? hevcSettings
            : h264Settings

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100
            ]
        )
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw NSError(
                domain: "CueGlide",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法为录制添加轨道"]
            )
        }
        writer.add(videoInput)
        writer.add(audioInput)
    }

    func start() {
        guard writer.startWriting() else { return }
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

    /// AVAssetWriter 没有可读的会话开始时间，首帧到达时手动开 session。
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
