import Foundation

/// 模板助手的提示词与解析。
///
/// 不集成任何大模型：给用户一段可直接复制的提示词，让他去常用的 AI 里生成，
/// 再把结果粘回来解析。这样既能借到各家模型的能力，又不必引入网络请求和密钥。
enum TemplatePromptKit {

    /// 可直接复制到任意 AI 对话框的提示词。
    static let prompt = """
    你是短视频脚本教练。请帮我设计一个提词器模板，严格按下面的格式输出，不要加代码块标记、不要额外解释：

    标题：（不超过 8 个字）
    场景：（从「开场钩子 / 产品讲解 / 知识科普 / 探店实录 / 直播话术 / 情感共鸣」里选一个）
    摘要：（一句话说明这个模板适合什么内容，不超过 20 字）
    正文：
    （3 到 5 段骨架，每段一行，用方括号标出需要替换的占位符，例如 [你的产品]、[具体痛点]）

    我这次要做的内容方向是：
    """

    struct Parsed {
        var title: String
        var scene: String
        var summary: String
        var body: String
    }

    /// 允许的场景，与内置模板保持一致；解析到未知场景时归到「自定义」。
    private static let knownScenes = [
        "开场钩子", "产品讲解", "知识科普", "探店实录", "直播话术", "情感共鸣"
    ]

    /// 从粘贴文本里解析字段。
    ///
    /// 容错考虑：AI 常带 markdown 代码块、全角冒号、`**加粗**` 包裹的字段名，
    /// 也可能把「正文」写成「内容」。这些都做兼容，实在解析不到标题就返回 nil。
    static func parse(_ raw: String) -> Parsed? {
        var text = raw
        // 去掉 ``` 代码块围栏
        text = text.replacingOccurrences(of: "```", with: "")
        // 去掉 markdown 加粗
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")

        let lines = text.components(separatedBy: .newlines)
        var title = ""
        var scene = ""
        var summary = ""
        var bodyLines: [String] = []
        var inBody = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let value = fieldValue(in: line, keys: ["标题", "名称", "模板名称"]) {
                title = value
                continue
            }
            if let value = fieldValue(in: line, keys: ["场景", "分类"]) {
                scene = value
                continue
            }
            if let value = fieldValue(in: line, keys: ["摘要", "说明", "简介"]) {
                summary = value
                continue
            }
            // 「正文」「内容」后面可能直接换行，也可能同一行接着写
            if let value = fieldValue(in: line, keys: ["正文", "内容", "骨架"]) {
                inBody = true
                if !value.isEmpty { bodyLines.append(value) }
                continue
            }
            if inBody {
                bodyLines.append(line)
            }
        }

        // 没识别到字段名时，退化成「第一行当标题、其余当正文」
        if title.isEmpty, bodyLines.isEmpty {
            let meaningful = lines.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let first = meaningful.first else { return nil }
            title = String(first.prefix(20))
            bodyLines = Array(meaningful.dropFirst())
        }

        guard !title.isEmpty else { return nil }
        let normalizedScene = knownScenes.first { scene.contains($0) } ?? "自定义"

        return Parsed(
            title: String(title.prefix(24)),
            scene: normalizedScene,
            summary: String(summary.prefix(40)),
            body: bodyLines.joined(separator: "\n\n")
        )
    }

    /// 匹配「键：值」形式的行，冒号兼容全角半角。
    private static func fieldValue(in line: String, keys: [String]) -> String? {
        for key in keys {
            for separator in ["：", ":"] {
                let prefix = key + separator
                if line.hasPrefix(prefix) {
                    return line.dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespaces)
                }
                // 有些模型会写成「1. 标题：xxx」
                if line.contains(prefix) {
                    if let range = line.range(of: prefix) {
                        return line[range.upperBound...]
                            .trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        return nil
    }
}
