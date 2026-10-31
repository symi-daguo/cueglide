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
}
