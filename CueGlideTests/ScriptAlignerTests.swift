import XCTest
@testable import CueGlide

final class ScriptAlignerTests: XCTestCase {

    /// 五段共两百余字，超过局部窗口 90 词，用来验证全稿搜索。
    private let longBody = """
    第一段讲开场，先把结论提前说出来，别让观众等太久，直接告诉大家今天能拿走什么。
    第二段讲背景，说清楚这个问题为什么会出现，常见的三种错误做法分别是什么样子。
    第三段讲方法，一步一步拆开讲，每一步只讲一个动作，讲完一个再讲下一个不要跳。
    第四段讲案例，用一个真实场景串起来，让观众能对上自己的情况，产生代入的感觉。
    第五段讲收尾，重复一次核心结论，给出下一步动作，提醒观众收藏并关注后续更新。
    """

    private func make(_ text: String) -> (ScriptAligner, TokenizedScript) {
        let tokenized = ScriptTokenizer.tokenize(text)
        return (ScriptAligner(tokenized: tokenized), tokenized)
    }

    /// 正常前进：说的内容就在当前位置，应走局部窗口命中。
    func testLocalMatch() {
        let (aligner, tokenized) = make("今天我们来聊一聊提词器的设计。它的核心是把文字匀速推上去，让视线停在同一个位置。")
        let match = aligner.align(spoken: "今天我们来聊一聊", currentToken: 0)
        XCTAssertNotNil(match, "同段内容应当命中")
        let match2 = match!
        XCTAssertFalse(match2.isGlobal, "应在局部窗口内命中")
        XCTAssertLessThanOrEqual(match2.tokenIndex, 10, "位置应落在前十个词内")
        XCTAssertTrue(match2.tokenIndex < tokenized.totalTokens)
    }

    /// 跳段找回：稿子长度超过局部窗口，从开头跳到最后一段，必须走全稿搜索。
    func testJumpForwardFound() {
        let body = longBody
        let (aligner, tokenized) = make(body)
        XCTAssertGreaterThan(tokenized.totalTokens, 110, "稿件需长于局部窗口，测试才有意义")

        let match = aligner.align(
            spoken: "第五段讲收尾重复一次核心结论给出下一步动作",
            currentToken: 0
        )
        XCTAssertNotNil(match, "跳到结尾应当能找到")
        XCTAssertTrue(match!.isGlobal, "超出局部窗口时应走全稿搜索")
        XCTAssertGreaterThan(match!.tokenIndex, 100, "位置应落在最后一段")
    }

    /// 回头重读：当前位置在后段，说前面的话，应能找回去。
    func testJumpBackwardFound() {
        let body = """
        开场先说清楚今天讲什么。第一段讲基础概念，第二段讲具体做法，第三段讲常见问题。
        现在进入第二部分，我们讨论节奏控制。做法是一句话一停顿，逗号处稍作停留。
        最后是收尾，重复一次核心结论，提醒观众收藏。
        """
        let (aligner, _) = make(body)
        let tail = aligner.align(spoken: "最后是收尾重复一次核心结论", currentToken: 0)
        XCTAssertNotNil(tail)
        let back = aligner.align(spoken: "第一段讲基础概念", currentToken: tail!.tokenIndex)
        XCTAssertNotNil(back, "回头重读应当能找到")
        XCTAssertLessThan(back!.tokenIndex, 30, "应回到前段")
    }

    /// 开头几个字识别错，靠尾字兜底仍能跟上。
    func testToleratesLeadingRecognitionError() {
        let body = "提词器最重要的不是字号多大，而是阅读线的位置是否贴着镜头。"
        let (aligner, _) = make(body)
        let match = aligner.align(spoken: "题词其阅读线的位置是否贴着镜头", currentToken: 0)
        XCTAssertNotNil(match, "尾字匹配应当命中")
        XCTAssertGreaterThan(match!.tokenIndex, 5)
    }

    /// 完全无关的内容不应乱跳。
    func testUnrelatedReturnsNil() {
        let (aligner, _) = make("提词器最重要的不是字号多大，而是阅读线的位置是否贴着镜头。")
        let match = aligner.align(spoken: "完全无关的另一段内容比如天气不错", currentToken: 0)
        XCTAssertNil(match, "无关内容不该产生位置跳变")
    }

    /// 太短的输入不参与对齐，避免单字误命中。
    func testTooShortReturnsNil() {
        let (aligner, _) = make("提词器最重要的不是字号多大，而是阅读线的位置是否贴着镜头。")
        XCTAssertNil(aligner.align(spoken: "的", currentToken: 0))
        XCTAssertNil(aligner.align(spoken: "阅读", currentToken: 0))
    }

    /// 空稿不应崩溃。
    func testEmptyScript() {
        let (aligner, _) = make("")
        XCTAssertNil(aligner.align(spoken: "随便说点什么内容", currentToken: 0))
    }
}
