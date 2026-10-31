import XCTest
@testable import CueGlide

final class TemplatePromptKitTests: XCTestCase {

    /// 标准格式应当逐字段解析出来。
    func testParsesStandardFormat() {
        let text = """
        标题：三句讲清一个概念
        场景：知识科普
        摘要：适合把一个复杂名词拆成三句话说清楚
        正文：
        [先说结论] 这个词其实就是 [一句话解释]。
        [为什么重要] 因为它决定了 [具体影响]。
        [怎么用] 下次遇到 [场景] 时，先问自己 [问题]。
        """

        let parsed = TemplatePromptKit.parse(text)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.title, "三句讲清一个概念")
        XCTAssertEqual(parsed?.scene, "知识科普")
        XCTAssertEqual(parsed?.summary, "适合把一个复杂名词拆成三句话说清楚")
        XCTAssertTrue(parsed?.body.contains("[一句话解释]") ?? false)
        XCTAssertTrue(parsed?.body.contains("[具体影响]") ?? false)
    }

    /// AI 常带代码块围栏和加粗，必须能剥掉。
    func testToleratesCodeFenceAndBold() {
        let text = """
        ```markdown
        **标题**：探店三分钟
        **场景**：探店实录
        **摘要**：一顿饭的功夫讲完一家店
        **正文**：
        先说环境，[描述氛围]。
        再说招牌，[菜名] 必点。
        ```
        """

        let parsed = TemplatePromptKit.parse(text)
        XCTAssertEqual(parsed?.title, "探店三分钟")
        XCTAssertEqual(parsed?.scene, "探店实录")
        XCTAssertTrue(parsed?.body.contains("[菜名]") ?? false)
    }

    /// 全角与半角冒号都要认。
    func testToleratesHalfWidthColon() {
        let text = "标题:直播开场\n场景:直播话术\n摘要:留人四步\n正文:\n先打招呼。"
        let parsed = TemplatePromptKit.parse(text)
        XCTAssertEqual(parsed?.title, "直播开场")
        XCTAssertEqual(parsed?.scene, "直播话术")
    }

    /// 场景写成没听过的词时归到「自定义」，不能整条丢弃。
    func testUnknownSceneFallsBackToCustom() {
        let text = "标题：随便写写\n场景：脱口秀\n正文：\n随便一段。"
        let parsed = TemplatePromptKit.parse(text)
        XCTAssertEqual(parsed?.scene, "自定义")
        XCTAssertEqual(parsed?.title, "随便写写")
    }

    /// 完全没有字段名时，把第一行当标题、其余当正文，好过直接失败。
    func testFallsBackToFirstLineAsTitle() {
        let text = """
        我的开场白
        大家好，今天讲三件事。
        第一件是[事项一]。
        """
        let parsed = TemplatePromptKit.parse(text)
        XCTAssertEqual(parsed?.title, "我的开场白")
        XCTAssertTrue(parsed?.body.contains("[事项一]") ?? false)
    }

    /// 空输入不应该产出模板。
    func testEmptyInputReturnsNil() {
        XCTAssertNil(TemplatePromptKit.parse(""))
        XCTAssertNil(TemplatePromptKit.parse("   \n  \n"))
    }
}
