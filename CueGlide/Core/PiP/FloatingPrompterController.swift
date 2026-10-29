import AVKit
import AVFoundation
import UIKit
import Observation

/// 悬浮提词：把提词画面渲染成视频帧，通过画中画浮窗显示在其他应用之上。
///
/// 限制说明：
/// 画中画只接受视频帧，所以每帧都要离屏渲染一次。用 15fps 足够，文字滚动不需要更高帧率。
/// 浮窗里的滚动独立于主界面，不跟随语音跟读。
@MainActor
@Observable
final class FloatingPrompterController: NSObject {

    enum State: Equatable {
        case idle
        case running
        case stopped
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    private(set) var state: State = .idle
    private(set) var isPlaying: Bool = true
    private(set) var progress: Double = 0

    let displayLayer = AVSampleBufferDisplayLayer()

    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private var renderer: FloatingFrameRenderer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var position: Double = 0
    @ObservationIgnored private var tokensPerSecond: Double = 3
    @ObservationIgnored private var lastTick = Date()
    /// 画布按浮窗的实际显示尺寸来定，这样字号 1:1 呈现，不会在浮窗里缩得看不清。
    @ObservationIgnored private let canvasSize = CGSize(width: 360, height: 640)
    @ObservationIgnored private let pixelSize = CGSize(width: 720, height: 1280)

    var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = CGRect(origin: .zero, size: pixelSize)
    }

    // MARK: - 准备

    func prepare(script: Script, display: DisplayConfig, scroll: ScrollConfig) {
        let tokenized = ScriptTokenizer.tokenize(script.body)
        guard tokenized.totalTokens > 0 else {
            state = .failed("这篇台本是空的，先写点内容再悬浮提词。")
            return
        }

        let frameRenderer = FloatingFrameRenderer(
            tokenized: tokenized,
            config: display,
            canvasSize: canvasSize
        )
        renderer = frameRenderer

        // 浮窗里的滚动速度沿用提词页的恒速设置
        let pointsPerToken = max(Double(canvasSize.height) / Double(tokenized.totalTokens), 4)
        let pps = scroll.mode == .constant ? scroll.pointsPerSecond : 56
        tokensPerSecond = max(pps / pointsPerToken, 0.6)

        position = Double(min(script.lastReadTokenIndex, tokenized.totalTokens - 1))
        progress = position / Double(max(tokenized.totalTokens - 1, 1))

        enqueueFrame(atToken: Int(position))
        state = .idle
    }

    // MARK: - 启停

    func start() {
        guard renderer != nil else { return }
        guard isSupported else {
            state = .failed("这台设备不支持画中画浮窗。")
            return
        }

        if pip == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            pip = controller
        }

        guard let pip else { return }
        guard pip.isPictureInPicturePossible else {
            state = .failed("画中画暂时不可用，稍后再试，或先播放任意视频让系统就绪。")
            return
        }

        isPlaying = true
        lastTick = Date()
        startTimer()
        pip.startPictureInPicture()
        state = .running
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pip?.stopPictureInPicture()
        pip = nil
        state = .stopped
    }

    func togglePlay() {
        isPlaying.toggle()
        lastTick = Date()
        if isPlaying {
            startTimer()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - 渲染循环

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard isPlaying, let renderer else { return }

        let now = Date()
        let delta = min(now.timeIntervalSince(lastTick), 0.5)
        lastTick = now

        position += tokensPerSecond * delta
        let upperBound = Double(max(renderer.totalTokens - 1, 0))
        if position >= upperBound {
            position = upperBound
            isPlaying = false
            timer?.invalidate()
            timer = nil
        }

        progress = upperBound > 0 ? position / upperBound : 0
        enqueueFrame(atToken: Int(position))
    }

    private func enqueueFrame(atToken token: Int) {
        guard let renderer else { return }
        let image = renderer.image(atToken: token)
        guard let buffer = image.toPixelBuffer(
            width: Int(pixelSize.width),
            height: Int(pixelSize.height)
        ) else { return }

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &format
        )
        guard let format else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 15),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }
}

// MARK: - 画中画生命周期

extension FloatingPrompterController: @preconcurrency AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        state = .running
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        timer?.invalidate()
        timer = nil
        state = .stopped
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        state = .failed("浮窗启动失败：\(error.localizedDescription)")
    }
}

// MARK: - 浮窗内播放控制

extension FloatingPrompterController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        isPlaying = playing
        lastTick = Date()
        if playing {
            startTimer()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        guard let renderer else {
            completionHandler()
            return
        }
        let delta = skipInterval.seconds * tokensPerSecond
        let upperBound = Double(max(renderer.totalTokens - 1, 0))
        position = min(max(position + delta, 0), upperBound)
        progress = upperBound > 0 ? position / upperBound : 0
        enqueueFrame(atToken: Int(position))
        completionHandler()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        // 提词是持续内容，对系统声明为直播式无终点
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        !isPlaying
    }
}

// MARK: - 位图转视频帧

extension UIImage {

    /// 用 Core Image 渲染到 CVPixelBuffer。CGContext 是左下原点、CVPixelBuffer 是左上原点，
    /// 手动做翻转容易搞反，交给 CIContext 处理方向更稳。
    @MainActor
    func toPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard let cgImage else { return nil }

        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        PixelBufferRenderer.shared.render(CIImage(cgImage: cgImage), into: buffer)
        return buffer
    }
}

/// CIContext 创建开销大，全局复用一个。
@MainActor
private final class PixelBufferRenderer {
    static let shared = PixelBufferRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false])

    func render(_ image: CIImage, into buffer: CVPixelBuffer) {
        let target = CIImage(cvPixelBuffer: buffer)
        let scaled = image.transformed(by: .init(
            scaleX: target.extent.width / image.extent.width,
            y: target.extent.height / image.extent.height
        ))
        context.render(
            scaled,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: target.extent.width, height: target.extent.height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }
}
