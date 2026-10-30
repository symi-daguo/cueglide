import XCTest
import AVFoundation
import Speech
@testable import CueGlide

final class SpeechAudioCaptureTests: XCTestCase {

    /// 没装过 tap 就调 `removeTap` 时，AVAudioNode 抛的是 ObjC 异常，
    /// Swift 的 `do/catch` 拦不住，进程直接崩。这条用例锁住防护逻辑：
    /// 未启动直接停止必须安静返回。
    @MainActor
    func testStopWithoutStartIsSafe() async {
        let capture = SpeechAudioCapture()
        await capture.stop()
        await capture.stop()
    }

    /// 每次开关跟读都会新建一个采集实例，停止路径必须可重复执行。
    @MainActor
    func testRepeatedStopStaysSafe() async {
        let capture = SpeechAudioCapture()
        for _ in 0..<5 {
            await capture.stop()
        }
    }
}
