import XCTest
import AVFoundation
@testable import CueGlide

/// 相机格式选择与录制码率的回归保护。
///
/// 这两段直接决定成片清晰度，改错了在模拟器上看不出来（没有相机），
/// 只能靠真机肉眼看，所以用纯逻辑用例钉住。
final class CameraFormatTests: XCTestCase {

    private typealias Option = CameraController.VideoFormatOption

    // MARK: - 格式选择

    /// 前置相机常同时给出 4:3 的高像素静止格式和 16:9 的 4K 视频格式。
    /// 4:3 像素更多但录制会变形，必须优先 16:9。
    func testPrefersWidescreenOverHigherPixelCount() {
        let options = [
            Option(width: 4032, height: 3024, maxFrameRate: 30),  // 4:3，像素更多
            Option(width: 3840, height: 2160, maxFrameRate: 30),  // 16:9，4K
            Option(width: 1920, height: 1080, maxFrameRate: 60)
        ]
        XCTAssertEqual(CameraController.preferredFormatIndex(in: options), 1)
    }

    /// 只有 4:3 时不能直接放弃，退回最高分辨率。
    func testFallsBackToHighestResolutionWhenNoWidescreen() {
        let options = [
            Option(width: 1280, height: 960, maxFrameRate: 30),
            Option(width: 4032, height: 3024, maxFrameRate: 30)
        ]
        XCTAssertEqual(CameraController.preferredFormatIndex(in: options), 1)
    }

    /// 只支持 24fps 的高像素格式不能用：设 30fps 会失败，画面反而不动。
    func testSkipsFormatsBelow30FPS() {
        let options = [
            Option(width: 4032, height: 3024, maxFrameRate: 24),
            Option(width: 1920, height: 1080, maxFrameRate: 30)
        ]
        XCTAssertEqual(CameraController.preferredFormatIndex(in: options), 1)
    }

    /// 全是低帧率格式时返回 nil，让调用方保留设备默认格式。
    func testReturnsNilWhenNothingUsable() {
        let options = [
            Option(width: 1280, height: 720, maxFrameRate: 24),
            Option(width: 0, height: 0, maxFrameRate: 60)
        ]
        XCTAssertNil(CameraController.preferredFormatIndex(in: options))
    }

    func testEmptyOptionsReturnNil() {
        XCTAssertNil(CameraController.preferredFormatIndex(in: []))
    }

    // MARK: - 码率

    /// 4K30 HEVC 应在 44Mbps 上下，接近系统相机的 40–50Mbps 档。
    func test4KHEVCBitRateMatchesSystemCamera() {
        let rate = RecordingWriter.averageBitRate(
            for: CGSize(width: 3840, height: 2160),
            codec: .hevc
        )
        XCTAssertGreaterThan(rate, 43_000_000, "4K HEVC 码率偏低会发糊")
        XCTAssertLessThan(rate, 47_000_000)
    }

    /// 同尺寸下 HEVC 必须比 H.264 省，否则选 HEVC 没有意义。
    func testHEVCCostsLessThanH264() {
        let size = CGSize(width: 3840, height: 2160)
        let hevc = RecordingWriter.averageBitRate(for: size, codec: .hevc)
        let h264 = RecordingWriter.averageBitRate(for: size, codec: .h264)
        XCTAssertLessThan(hevc, h264)
    }

    /// 1080p H.264 要落在 15Mbps 以上，这是同档清晰度的下限。
    func test1080pH264BitRateIsSufficient() {
        let rate = RecordingWriter.averageBitRate(
            for: CGSize(width: 1920, height: 1080),
            codec: .h264
        )
        XCTAssertGreaterThan(rate, 15_000_000)
    }

    /// 小尺寸也要有 8Mbps 下限，否则压缩块会非常明显。
    func testSmallSizeKeepsMinimumBitRate() {
        let rate = RecordingWriter.averageBitRate(
            for: CGSize(width: 640, height: 480),
            codec: .h264
        )
        XCTAssertEqual(rate, 8_000_000)
    }

    /// 输出设置必须带上压缩属性，否则系统会用默认码率（也就是之前糊的原因）。
    func testVideoSettingsCarryCompressionProperties() {
        let size = CGSize(width: 1920, height: 1080)
        let settings = RecordingWriter.videoSettings(size: size, codec: .hevc)

        XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 1920)
        XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 1080)
        XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .hevc)

        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertNotNil(compression, "缺少压缩属性就回到默认码率")
        XCTAssertEqual(
            compression?[AVVideoAverageBitRateKey] as? Int,
            RecordingWriter.averageBitRate(for: size, codec: .hevc)
        )
        XCTAssertEqual(compression?[AVVideoExpectedSourceFrameRateKey] as? Int, 30)
    }
}
