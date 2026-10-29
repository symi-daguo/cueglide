import Foundation

/// 把端侧识别出的文本流与稿件做字符级对齐，推算当前读到的词索引。
///
/// 设计取舍：
/// 1. 不用词级编辑距离。语音识别会给同音字、漏字、多字，词级比对一个字错就整词不匹配，
///    字符级匹配更抗噪，且中文一个字就是一个音节，天然对齐。
/// 2. 局部窗口优先。绝大多数时间用户都在当前位置附近，只看 ±90 个词，命中率足够且开销极低。
/// 3. 局部失配再全稿搜索，用来实现「跳段后还能找回」。
struct ScriptAligner {

    struct Match {
        let tokenIndex: Int
        /// 命中位置距当前位置的词数，正数表示往前跳。
        let distance: Int
        /// 是否走的是全稿搜索。
        let isGlobal: Bool
    }

    /// 归一化后的全稿，只含字母数字与 CJK，每个 UTF-16 单元对应一个字。
    private let normalizedScript: NSString
    /// 归一化文本每个字符对应的词索引。
    private let characterToToken: [Int]
    /// 每个词在归一化文本中的起始字符位置。
    private let tokenStartCharacter: [Int]
    private let tokenCount: Int

    /// 参与比对的尾部字符数。太短容易误命中，太长则对漏字更敏感。
    private let queryLength = 12
    /// 局部窗口向前看的词数。
    private let forwardWindow = 90
    /// 局部窗口向后看的词数。
    private let backwardWindow = 10

    init(tokenized: TokenizedScript) {
        var chars: [Character] = []
        var mapping: [Int] = []
        var starts: [Int] = []
        chars.reserveCapacity(tokenized.source.count)
        mapping.reserveCapacity(tokenized.source.count)
        starts.reserveCapacity(tokenized.totalTokens)

        for token in tokenized.tokens {
            starts.append(chars.count)
            for ch in token.normalized {
                chars.append(ch)
                mapping.append(token.index)
            }
        }

        self.normalizedScript = String(chars) as NSString
        self.characterToToken = mapping
        self.tokenStartCharacter = starts
        self.tokenCount = tokenized.totalTokens
    }

    var isEmpty: Bool { tokenCount == 0 || characterToToken.isEmpty }

    /// 用识别文本的尾部去稿件里找位置。
    /// - Parameters:
    ///   - spoken: 归一化后的识别文本，可以持续累加，内部只取尾部。
    ///   - currentToken: 当前所在词索引，作为局部搜索的锚点。
    func align(spoken: String, currentToken: Int) -> Match? {
        guard !isEmpty else { return nil }

        let trimmed = String(spoken.suffix(queryLength * 2))
        guard trimmed.count >= 3 else { return nil }
        let query = String(trimmed.suffix(queryLength))
        let nsQuery = query as NSString
        guard nsQuery.length >= 3 else { return nil }

        // 一、局部窗口：绝大多数命中的都走这条，开销极低
        let lowerToken = max(currentToken - backwardWindow, 0)
        let upperToken = min(currentToken + forwardWindow, tokenCount - 1)
        let lowerChar = characterOffset(forToken: lowerToken)
        let upperChar = min(
            characterOffset(forToken: upperToken) + (tokenLength(at: upperToken) ?? 1) + 1,
            normalizedScript.length
        )

        if upperChar > lowerChar {
            let window = NSRange(location: lowerChar, length: upperChar - lowerChar)
            let hit = normalizedScript.range(of: query, options: [], range: window)
            if hit.location != NSNotFound, hit.length > 0 {
                let token = tokenIndex(atCharacter: hit.location + hit.length - 1)
                return Match(
                    tokenIndex: token,
                    distance: token - currentToken,
                    isGlobal: false
                )
            }
        }

        // 二、全稿搜索：用来支持跳段、回头重读
        if let hit = normalizedScript.range(of: query, options: []) as NSRange?,
           hit.location != NSNotFound, hit.length > 0 {
            let token = tokenIndex(atCharacter: hit.location + hit.length - 1)
            return Match(
                tokenIndex: token,
                distance: token - currentToken,
                isGlobal: true
            )
        }

        // 三、短查询兜底：识别结果前面几个字可能听错，只拿最后 5 个字再试一次
        let shortQuery = String(query.suffix(5))
        if shortQuery.count >= 4 {
            let nsShort = shortQuery as NSString
            if upperChar > lowerChar {
                let window = NSRange(location: lowerChar, length: upperChar - lowerChar)
                let local = normalizedScript.range(of: shortQuery, options: [], range: window)
                if local.location != NSNotFound, local.length > 0 {
                    let token = tokenIndex(atCharacter: local.location + local.length - 1)
                    return Match(
                        tokenIndex: token,
                        distance: token - currentToken,
                        isGlobal: false
                    )
                }
            }
            let global = normalizedScript.range(of: shortQuery, options: [])
            if global.location != NSNotFound, global.length > 0 {
                let token = tokenIndex(atCharacter: global.location + global.length - 1)
                return Match(
                    tokenIndex: token,
                    distance: token - currentToken,
                    isGlobal: true
                )
            }
            _ = nsShort
        }

        return nil
    }

    // MARK: - 索引换算

    private func characterOffset(forToken token: Int) -> Int {
        guard !tokenStartCharacter.isEmpty else { return 0 }
        let clamped = min(max(token, 0), tokenStartCharacter.count - 1)
        return tokenStartCharacter[clamped]
    }

    private func tokenLength(at token: Int) -> Int? {
        guard !tokenStartCharacter.isEmpty else { return nil }
        let clamped = min(max(token, 0), tokenStartCharacter.count - 1)
        if clamped + 1 < tokenStartCharacter.count {
            return tokenStartCharacter[clamped + 1] - tokenStartCharacter[clamped]
        }
        return characterToToken.count - tokenStartCharacter[clamped]
    }

    private func tokenIndex(atCharacter character: Int) -> Int {
        guard !characterToToken.isEmpty else { return 0 }
        let clamped = min(max(character, 0), characterToToken.count - 1)
        return characterToToken[clamped]
    }
}
