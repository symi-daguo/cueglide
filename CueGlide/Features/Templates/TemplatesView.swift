import SwiftUI
import SwiftData

struct TemplatesView: View {

    @Environment(\.modelContext) private var context
    @State private var scene: String = "全部"
    @State private var createdScript: Script?

    private var templates: [ScriptTemplate] {
        TemplateCatalog.templates(in: scene)
    }

    /// 自适应列数：iPhone 竖屏 2 列，Duo 展开约 3 列，iPad 横屏 4–5 列。
    private let columns = [
        GridItem(.adaptive(minimum: 158, maximum: 260), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scenePicker

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(templates) { template in
                            templateCard(template)
                        }
                    }

                    note
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.canvas)
            .navigationTitle("模板")
            .sheet(item: $createdScript) { script in
                ScriptEditorView(script: script)
            }
        }
    }

    private var scenePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TemplateCatalog.scenes, id: \.self) { item in
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { scene = item }
                    } label: {
                        Text(item)
                            .font(.system(size: 13, weight: scene == item ? .semibold : .regular))
                            .foregroundStyle(scene == item ? .white : Theme.textSecondary)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(
                                scene == item ? Theme.brand : Theme.surface,
                                in: .capsule
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func templateCard(_ template: ScriptTemplate) -> some View {
        Button {
            create(from: template)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: UIColor(rgb: template.accentHex)).opacity(0.14))
                        .frame(height: 96)

                    Text(template.scene)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(uiColor: UIColor(rgb: template.accentHex)))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Color(uiColor: UIColor(rgb: template.accentHex)).opacity(0.16),
                            in: .capsule
                        )
                        .padding(10)
                }

                Text(template.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 10)

                Text(template.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 3)
                    .padding(.bottom, 2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var note: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
            Text("模板是写在本地的手写骨架，不含 AI 生成。点一下就直接创建成台本，可以随意改。")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.top, 4)
    }

    private func create(from template: ScriptTemplate) {
        let script = Script(title: template.title, body: template.body, groupName: template.scene)
        context.insert(script)
        try? context.save()
        createdScript = script
    }
}

#Preview {
    TemplatesView()
        .environment(AppSettings())
        .modelContainer(for: Script.self, inMemory: true)
}
