import Foundation
import NaturalLanguage

/// 稿件中的一个可高亮单元。中文按词（NLTokenizer 会切成词），西文按单词。
struct ScriptToken: Sendable, Equatable, Identifiable {
    let index: Int
    let text: String
    let normalized: String
    let nsRange: NSRange
    let containsCJK: Bool

    var id: Int { index }
}

/// 分词结果。滚动定位、逐词高亮、语音对齐都以它为唯一坐标系统。
struct TokenizedScript: Sendable {
    let source: String
    let tokens: [ScriptToken]
    let characterCount: Int
    let speechUnitCount: Int

    static let empty = TokenizedScript(source: "", tokens: [], characterCount: 0, speechUnitCount: 0)

    var isEmpty: Bool { tokens.isEmpty }
    var totalTokens: Int { tokens.count }

    /// 用 UTF-16 偏移二分定位所属词序号。
    func tokenIndex(forUTF16Offset offset: Int) -> Int {
        guard !tokens.isEmpty else { return 0 }
        var low = 0
        var high = tokens.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = tokens[mid].nsRange
            if offset < range.location {
                high = mid - 1
            } else if offset >= range.location + range.length {
                low = mid + 1
            } else {
                return mid
            }
        }
        return min(max(low, 0), tokens.count - 1)
    }

    /// 取某段词区间的字符范围，用于加高亮属性。
    func nsRange(forTokenRange range: ClosedRange<Int>) -> NSRange? {
        guard !tokens.isEmpty else { return nil }
        let lower = min(max(range.lowerBound, 0), tokens.count - 1)
        let upper = min(max(range.upperBound, 0), tokens.count - 1)
        guard lower <= upper else { return nil }
        let start = tokens[lower].nsRange.location
        let end = tokens[upper].nsRange.location + tokens[upper].nsRange.length
        return NSRange(location: start, length: end - start)
    }
}

enum ScriptTokenizer {

    struct Statistics: Sendable {
        let characters: Int
        let speechUnits: Int
    }

    // MARK: - 统计

    static func statistics(of text: String) -> Statistics {
        var characters = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            characters += 1
        }
        let tokenized = tokenize(text)
        return Statistics(characters: characters, speechUnits: tokenized.speechUnitCount)
    }

    // MARK: - 分词

    static func tokenize(_ text: String) -> TokenizedScript {
        guard !text.isEmpty else { return .empty }

        var tokens: [ScriptToken] = []
        tokens.reserveCapacity(max(text.count / 2, 16))

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text

        var speechUnits = 0
        var index = 0

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let raw = String(text[range])
            let normalized = normalize(raw)
            guard !normalized.isEmpty else { return true }

            let hasCJK = raw.unicodeScalars.contains(where: isCJK)
            let units = hasCJK
                ? raw.unicodeScalars.filter(isCJK).count
                : 1
            speechUnits += max(units, 1)

            tokens.append(
                ScriptToken(
                    index: index,
                    text: raw,
                    normalized: normalized,
                    nsRange: NSRange(range, in: text),
                    containsCJK: hasCJK
                )
            )
            index += 1
            return true
        }

        var characters = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            characters += 1
        }

        return TokenizedScript(
            source: text,
            tokens: tokens,
            characterCount: characters,
            speechUnitCount: speechUnits
        )
    }

    // MARK: - 归一化

    /// 归一化用于语音对齐：全角转半角、小写、剔除标点与空白，只保留字母、数字与 CJK。
    static func normalize(_ text: String) -> String {
        let halfwidth = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        var result = String.UnicodeScalarView()
        for scalar in halfwidth.lowercased().unicodeScalars {
            if isCJK(scalar) || CharacterSet.alphanumerics.contains(scalar) {
                result.append(scalar)
            }
        }
        return String(result)
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // 平假名 / 片假名
             0x3400...0x4DBF,   // CJK 扩展 A
             0x4E00...0x9FFF,   // CJK 基本区
             0xAC00...0xD7AF,   // 谚文
             0xF900...0xFAFF,   // CJK 兼容表意
             0x20000...0x2FA1F: // CJK 扩展 B 及以后
            return true
        default:
            return false
        }
    }
}
