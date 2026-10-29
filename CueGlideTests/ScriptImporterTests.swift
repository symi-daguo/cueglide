import XCTest
@testable import CueGlide

final class ScriptImporterTests: XCTestCase {

    private func temporaryFile(name: String, content: String, encoding: String.Encoding = .utf8) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    /// 正常 UTF-8 文件：正文完整，标题取第一行。
    func testReadUTF8() throws {
        let url = try temporaryFile(
            name: "demo.txt",
            content: "今天聊聊提词器\n\n第一段内容。\n第二段内容。"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try ScriptImporter.read(from: url)
        XCTAssertEqual(result.title, "今天聊聊提词器")
        XCTAssertTrue(result.body.contains("第二段内容"))
    }

    /// 第一行是 Markdown 标题时，井号要被去掉。
    func testTitleStripsMarkdownHeading() throws {
        let url = try temporaryFile(name: "md.md", content: "# 三秒钩子开场\n正文")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try ScriptImporter.read(from: url)
        XCTAssertEqual(result.title, "三秒钩子开场")
    }

    /// 文件开始几行是空行时，标题要取第一行有内容的。
    func testTitleSkipsLeadingBlankLines() throws {
        let url = try temporaryFile(name: "blank.txt", content: "\n\n  \n真正的标题\n正文")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try ScriptImporter.read(from: url)
        XCTAssertEqual(result.title, "真正的标题")
    }

    /// 空文件应当明确报错，而不是建一篇空白台本。
    func testEmptyFileThrows() throws {
        let url = try temporaryFile(name: "empty.txt", content: "   \n\n  ")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ScriptImporter.read(from: url))
    }

    /// 极长首行要截断，避免标题撑爆卡片。
    func testTitleTruncated() throws {
        let long = String(repeating: "长", count: 80)
        let url = try temporaryFile(name: "long.txt", content: long)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try ScriptImporter.read(from: url)
        XCTAssertEqual(result.title.count, 24)
    }

    /// 文件不存在时不应崩溃。
    func testMissingFileThrows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-exist-\(UUID()).txt")
        XCTAssertThrowsError(try ScriptImporter.read(from: url))
    }
}
