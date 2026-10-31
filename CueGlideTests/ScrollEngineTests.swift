import XCTest
@testable import CueGlide

@MainActor
final class ScrollEngineTests: XCTestCase {

    private func makeEngine(totalTokens: Int = 100) -> ScrollEngine {
        let engine = ScrollEngine()
        engine.totalTokens = totalTokens
        engine.pointsPerToken = 20
        engine.unitsPerToken = 1.5
        return engine
    }

    /// 跳转不能越过稿件两端。
    func testSeekClampsToBounds() {
        let engine = makeEngine(totalTokens: 100)

        engine.seek(toTokenPosition: -50)
        XCTAssertEqual(engine.livePosition, 0, "负数应被夹到 0")

        engine.seek(toTokenPosition: 999)
        XCTAssertEqual(engine.livePosition, 99, "超出应被夹到最后一个词")
    }

    /// 进度按总词数归一，末尾必须是 1。
    func testProgressAtEdges() {
        let engine = makeEngine(totalTokens: 101)
        engine.seek(toTokenPosition: 0)
        XCTAssertEqual(engine.progress, 0, accuracy: 0.001)

        engine.seek(toTokenPosition: 100)
        XCTAssertEqual(engine.progress, 1, accuracy: 0.001)
    }

    /// 单篇只有一个词时不应除以零。
    func testSingleTokenDoesNotDivideByZero() {
        let engine = makeEngine(totalTokens: 1)
        engine.seek(toTokenPosition: 0)
        XCTAssertEqual(engine.progress, 0)
        XCTAssertEqual(engine.livePosition, 0)
    }

    /// 空稿件不应崩溃。
    func testEmptyScriptIsSafe() {
        let engine = makeEngine(totalTokens: 0)
        engine.seek(toTokenPosition: 10)
        XCTAssertEqual(engine.progress, 0)
        engine.start()
        XCTAssertFalse(engine.isRunning, "没有词的时候不该启动")
    }

    /// 复位要把位置、进度、结束标记一起清掉。
    func testResetClearsState() {
        let engine = makeEngine(totalTokens: 50)
        engine.seek(toTokenPosition: 30)
        engine.reset()

        XCTAssertEqual(engine.livePosition, 0)
        XCTAssertEqual(engine.progress, 0)
        XCTAssertFalse(engine.isFinished)
        XCTAssertFalse(engine.isRunning)
    }

    /// 恒速模式：每秒点数除以每词点数，得到每秒多少个词。
    func testConstantSpeedConversion() {
        let engine = makeEngine()
        var config = ScrollConfig()
        config.mode = .constant
        config.pointsPerSecond = 100
        engine.config = config
        engine.pointsPerToken = 20

        // 100 pt/s ÷ 20 pt/词 = 5 词/s；再乘 20 回到每秒点数
        XCTAssertEqual(engine.effectivePointsPerSecond, 100, accuracy: 0.1)
    }

    /// 语速模式：每分钟字数要按每词朗读单位换算。
    func testWPMSpeedConversion() {
        let engine = makeEngine()
        var config = ScrollConfig()
        config.mode = .wpm
        config.wordsPerMinute = 240
        engine.config = config
        engine.unitsPerToken = 2
        engine.pointsPerToken = 20

        // 每分钟 240 单位，每词 2 单位 → 120 词/分 → 2 词/s → 40 pt/s
        XCTAssertEqual(engine.effectivePointsPerSecond, 40, accuracy: 0.5)
    }

    /// 跟读模式引擎自身不推进，速度应报 0。
    func testVoiceModeReportsZeroSpeed() {
        let engine = makeEngine()
        var config = ScrollConfig()
        config.mode = .voice
        engine.config = config
        XCTAssertEqual(engine.effectivePointsPerSecond, 0)
    }

    /// 微调在边界处不能跑到负数。
    func testNudgeDoesNotGoNegative() {
        let engine = makeEngine(totalTokens: 20)
        engine.seek(toTokenPosition: 2)
        engine.nudge(byTokens: -10)
        XCTAssertEqual(engine.livePosition, 0)
    }

    /// 跟读必须跟得上正常语速。
    ///
    /// 这条锁的是一个真实事故：早期把上限写成 `1.2 * delta`（每秒 1.2 词），
    /// 而中文语速有 4–6 字/秒，导致画面恒定落后、越拉越远。
    func testVoiceStepKeepsUpWithNormalSpeech() {
        let dt = 1.0 / 60.0
        var position = 0.0
        var velocity = 0.0
        var target = 0.0

        // 目标以 5 词/秒前移，模拟正常朗读，跑 5 秒
        for _ in 0..<300 {
            target += 5.0 * dt
            let result = ScrollEngine.voiceStep(
                position: position, velocity: velocity, target: target, delta: dt
            )
            position = result.position
            velocity = result.velocity
        }

        XCTAssertLessThan(
            abs(target - position), 2.5,
            "落后不应超过 2.5 个词，超出就是速度参数算错了"
        )
    }

    /// 目标停止前移后要平滑收敛，不能超调（超调就是「滚过头再弹回来」）。
    func testVoiceStepConvergesWithoutOvershoot() {
        let dt = 1.0 / 60.0
        var position = 0.0
        var velocity = 0.0
        let target = 10.0
        var maxPosition = 0.0

        for _ in 0..<300 {
            let result = ScrollEngine.voiceStep(
                position: position, velocity: velocity, target: target, delta: dt
            )
            position = result.position
            velocity = result.velocity
            maxPosition = max(maxPosition, position)
        }

        XCTAssertEqual(position, target, accuracy: 0.3, "5 秒内应收敛到目标")
        XCTAssertLessThanOrEqual(maxPosition, target + 0.1, "临界阻尼不应超调")
    }

    /// 大跨度跳段：速度受上限约束，不会一帧飞过去，但要能在合理时间追上。
    func testVoiceStepHandlesLargeJump() {
        let dt = 1.0 / 60.0
        var position = 0.0
        var velocity = 0.0
        let target = 100.0

        let first = ScrollEngine.voiceStep(
            position: position, velocity: velocity, target: target, delta: dt
        )
        XCTAssertLessThan(first.position, 1.0, "单帧位移要受速度上限约束")

        for _ in 0..<600 where position < target - 0.5 {
            let result = ScrollEngine.voiceStep(
                position: position, velocity: velocity, target: target, delta: dt
            )
            position = result.position
            velocity = result.velocity
        }
        XCTAssertEqual(position, target, accuracy: 1.0, "10 秒内应追上 100 词的跳转")
    }

    /// 掉帧时（一次 dt 很大）不能把速度算爆，否则画面会猛跳。
    func testVoiceStepStableUnderFrameDrop() {
        let result = ScrollEngine.voiceStep(
            position: 0, velocity: 0, target: 50, delta: 0.125
        )
        XCTAssertLessThan(abs(result.velocity), 20.1, "速度不得超过上限")
        XCTAssertLessThan(result.position, 3.0, "单次大步长也不应飞出去")
    }
}
