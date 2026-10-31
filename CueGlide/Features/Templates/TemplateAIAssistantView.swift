import SwiftUI

/// 「用 AI 帮我写模板」。
///
/// 不联网、不存密钥：给一段可复制的提示词，用户拿去常用 AI 生成后把结果粘回来，
/// 这里解析成模板字段再交给编辑器预填。
struct TemplateAIAssistantView: View {

    @Environment(\.dismiss) private var dismiss

    /// 解析成功后回传，由调用方打开编辑器预填。
    let onParsed: (TemplatePromptKit.Parsed) -> Void

    @State private var pasted = ""
    @State private var copied = false
    @State private var parseError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    steps
                    promptCard
                    pasteArea

                    if let parseError {
                        Label(parseError, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.canvas)
            .navigationTitle("用 AI 生成模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("解析并填入") { parse() }
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - 步骤

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(stepTexts.enumerated()), id: \.offset) { index, text in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Theme.brand, in: .circle)
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var stepTexts: [String] {
        [
            "复制下面的提示词，贴到任意 AI 对话框里，末尾补上你想讲的方向",
            "把它给你的结果整段复制回来，粘在下面",
            "点「解析并填入」，标题、场景、摘要、正文会自动带进编辑器"
        ]
    }

    // MARK: - 提示词

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("提示词")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = TemplatePromptKit.prompt
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.brand)
            }

            Text(TemplatePromptKit.prompt)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 0.5)
        }
    }

    // MARK: - 粘贴

    private var pasteArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI 的输出")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if !pasted.isEmpty {
                    Button("清空") { pasted = "" }
                        .font(.system(size: 12))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            TextEditor(text: $pasted)
                .font(.system(size: 13))
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Theme.surface, in: .rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 0.5)
                }
                .overlay(alignment: .topLeading) {
                    if pasted.isEmpty {
                        Text("把 AI 回复的整段文字粘在这里")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - 解析

    private func parse() {
        guard let parsed = TemplatePromptKit.parse(pasted) else {
            parseError = "没认出格式，确认里面包含「标题：」和「正文：」两行再试。"
            return
        }
        parseError = nil
        onParsed(parsed)
        dismiss()
    }
}
