import SwiftUI
import SwiftData

struct TemplatesView: View {

    @Environment(\.modelContext) private var context
    @State private var scene: String = "全部"
    @State private var createdScript: Script?
    @State private var editorItem: EditorItem?

    /// 用户自建模板，新的排前面。
    @Query(sort: \CustomTemplate.createdAt, order: .reverse)
    private var customTemplates: [CustomTemplate]

    /// 新建与编辑共用一个 sheet，避免两个 sheet 抢同一个呈现时机。
    private struct EditorItem: Identifiable {
        let id = UUID()
        let template: CustomTemplate?
    }

    private var builtInTemplates: [ScriptTemplate] {
        TemplateCatalog.templates(in: scene)
    }

    private var visibleCustomTemplates: [CustomTemplate] {
        guard scene != "全部" else { return customTemplates }
        return customTemplates.filter { $0.scene == scene }
    }

    /// 自适应列数：iPhone 竖屏 2 列，Duo 展开约 3 列，iPad 横屏 4–5 列。
    private let columns = [
        GridItem(.adaptive(minimum: 158, maximum: 260), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "模板", subtitle: "选一个骨架开始，也可以做自己的")
                    scenePicker

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(visibleCustomTemplates) { template in
                            customCard(template)
                        }
                        ForEach(builtInTemplates) { template in
                            builtInCard(template)
                        }
                        addCard
                    }

                    note
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.canvas)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $createdScript) { script in
                ScriptEditorView(script: script)
            }
            .sheet(item: $editorItem) { item in
                TemplateEditorView(template: item.template)
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

    // MARK: - 卡片

    private func builtInCard(_ template: ScriptTemplate) -> some View {
        Button {
            createScript(title: template.title, body: template.body, scene: template.scene)
        } label: {
            cardFace(
                title: template.title,
                scene: template.scene,
                summary: template.summary,
                artwork: "asset:" + template.imageName,
                tint: Color(uiColor: UIColor(rgb: template.accentHex))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                createScript(title: template.title, body: template.body, scene: template.scene)
            } label: {
                Label("创建台本", systemImage: "doc.badge.plus")
            }
            Button {
                duplicate(template)
            } label: {
                Label("复制为我的模板", systemImage: "square.on.square")
            }
        }
    }

    private func customCard(_ template: CustomTemplate) -> some View {
        Button {
            createScript(title: template.title, body: template.body, scene: template.scene)
        } label: {
            cardFace(
                title: template.title,
                scene: template.scene,
                summary: template.summary.isEmpty ? "自己写的模板" : template.summary,
                artwork: template.artwork,
                tint: Theme.brand
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                createScript(title: template.title, body: template.body, scene: template.scene)
            } label: {
                Label("创建台本", systemImage: "doc.badge.plus")
            }
            Button {
                editorItem = EditorItem(template: template)
            } label: {
                Label("编辑模板", systemImage: "pencil")
            }
            Button(role: .destructive) {
                delete(template)
            } label: {
                Label("删除模板", systemImage: "trash")
            }
        }
    }

    private var addCard: some View {
        Button {
            editorItem = EditorItem(template: nil)
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                Text("新建模板")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 196)
            .background(Theme.surface, in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(
                        Theme.hairline,
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private func cardFace(
        title: String,
        scene: String,
        summary: String,
        artwork: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                TemplateArtwork.image(for: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 108)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        // 底部压暗，保证场景胶囊在任何图上都读得清
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.5)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text(scene)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.16), in: .capsule)
                    .padding(10)
            }

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.top, 10)

            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                // reservesSpace 让只有一行的摘要也占两行高度，
                // 否则同一行网格里的卡片高度会参差不齐。
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .padding(.top, 3)
                .padding(.bottom, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Theme.hairline, lineWidth: 0.5)
        }
    }

    private var note: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
            Text("内置模板是本地手写骨架，可一键复制成自己的模板再改；自定义模板能改标题、正文和配图，配图支持内置图库或从相册选。")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.top, 4)
    }

    // MARK: - 动作

    private func createScript(title: String, body: String, scene: String) {
        let script = Script(title: title, body: body, groupName: scene)
        context.insert(script)
        try? context.save()
        createdScript = script
    }

    private func duplicate(_ template: ScriptTemplate) {
        let copy = CustomTemplate(
            title: template.title + "（我的）",
            scene: template.scene,
            summary: template.summary,
            body: template.body,
            artwork: "asset:" + template.imageName
        )
        context.insert(copy)
        try? context.save()
    }

    private func delete(_ template: CustomTemplate) {
        TemplateArtwork.delete(template.artwork)
        context.delete(template)
        try? context.save()
    }
}

#Preview {
    TemplatesView()
        .environment(AppSettings())
        .modelContainer(for: [Script.self, CustomTemplate.self], inMemory: true)
}
