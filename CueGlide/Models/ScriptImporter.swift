import Foundation
import UIKit
import UniformTypeIdentifiers

/// 台本导入。只处理纯文本类格式，不做富文本解析与 PDF 提取。
enum ScriptImporter {

    /// 可导入的类型。PDF 与 Word 需要额外解析，暂不放开。
    static var readableTypes: [UTType] {
        [.plainText, .text, .utf8PlainText, UTType(filenameExtension: "md") ?? .plainText]
    }

    enum ImportError: LocalizedError {
        case unreadable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                "读不了「\(name)」，请确认是纯文本文件。"
            case .empty:
                "这个文件里没有文字内容。"
            }
        }
    }

    /// 读取用户选中的文件。需要处理安全作用域，否则沙盒外文件读不到。
    static func read(from url: URL) throws -> (title: String, body: String) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer {
            if needsScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.unreadable(url.lastPathComponent)
        }

        guard let text = decode(data), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.empty
        }

        return (deriveTitle(from: text, fallback: url.deletingPathExtension().lastPathComponent), text)
    }

    /// 从粘贴板导入。
    static func fromClipboard() -> (title: String, body: String)? {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (deriveTitle(from: text, fallback: "粘贴的台本"), text)
    }

    /// 编码兜底：先按 UTF-8，失败再试 GB18030，避免老文件变成乱码或直接失败。
    private static func decode(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        return String(data: data, encoding: gb18030)
    }

    /// 标题优先取第一行有内容的文字，过长则截断。
    private static func deriveTitle(from text: String, fallback: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""

        guard !firstLine.isEmpty else { return fallback }
        let cleaned = firstLine.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return fallback }
        return String(cleaned.prefix(24))
    }
}
