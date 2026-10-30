import SwiftUI
import SwiftData

enum ScriptSort: String, CaseIterable, Identifiable {
    case updated, created, title, length

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .updated: "修改时间"
        case .created: "创建时间"
        case .title: "标题"
        case .length: "字数"
        }
    }
}

struct ScriptListView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Query private var scripts: [Script]

    @State private var query = ""
    @State private var sort: ScriptSort = .updated
    @State private var editingScript: Script?
    @State private var activeScript: Script?
    @State private var pendingDelete: Script?
    @State private var showingImporter = false
    @State private var importError: String?

    private var filtered: [Script] {
        var list = scripts
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            list = list.filter {
                $0.title.localizedStandardContains(trimmed)
                    || $0.body.localizedStandardContains(trimmed)
            }
        }
        switch sort {
        case .updated:
            return list.sorted { $0.updatedAt > $1.updatedAt }
        case .created:
            return list.sorted { $0.createdAt > $1.createdAt }
        case .title:
            return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .length:
            return list.sorted { $0.characterCount > $1.characterCount }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    header
                    searchField
                    newScriptCard

                    ForEach(filtered) { script in
                        scriptCard(script)
                    }

                    if filtered.isEmpty && !query.isEmpty {
                        Text("没有匹配的台本")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.canvas)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $editingScript) { script in
                ScriptEditorView(script: script)
            }
            .fullScreenCover(item: $activeScript) { script in
                PrompterView(
                    script: script,
                    display: settings.display,
                    scroll: settings.scroll
                )
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: ScriptImporter.readableTypes,
                allowsMultipleSelection: false
            ) { result in
                importFromFile(result)
            }
            .alert(
                "导入失败",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )
            ) {
                Button("知道了") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .confirmationDialog(
                "删除这篇台本？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let target = pendingDelete {
                        context.delete(target)
                        try? context.save()
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("删除后无法恢复，录像文件不受影响。")
            }
        }
    }

    // MARK: - 页头

    private var header: some View {
        PageHeader(
            title: "台本",
            subtitle: "共 \(scripts.count) 篇 · 按\(sort.displayName)排序"
        ) {
            Menu {
                Picker("排序", selection: $sort) {
                    ForEach(ScriptSort.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                Divider()
                Button("新建台本", systemImage: "plus") {
                    createScript()
                }
                Button("从粘贴板导入", systemImage: "doc.on.clipboard") {
                    importFromClipboard()
                }
                Button("从文件导入", systemImage: "folder") {
                    showingImporter = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多操作")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            TextField("搜索标题或正文", text: $query)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 0.5)
        }
    }

    // MARK: - 新建

    private var newScriptCard: some View {
        Button {
            createScript()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                Text("新建台本")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(Theme.brand)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Theme.brandSoft.opacity(0.55), in: .rect(cornerRadius: 14))
            .accessibilityLabel("新建台本")
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.brand.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
        .buttonStyle(.plain)
    }

    private func importFromClipboard() {
        guard let imported = ScriptImporter.fromClipboard() else {
            importError = "粘贴板里没有可用的文字。先复制一段稿子再试。"
            return
        }
        let script = Script(title: imported.title, body: imported.body)
        context.insert(script)
        try? context.save()
        editingScript = script
    }

    private func importFromFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let imported = try ScriptImporter.read(from: url)
                let script = Script(title: imported.title, body: imported.body)
                context.insert(script)
                try? context.save()
                editingScript = script
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func createScript() {
        // 标题留空，用户点进来直接写就行，不用先删掉占位标题。
        // 列表卡片对空标题有「未命名台本」回退显示。
        let script = Script(title: "", body: "")
        context.insert(script)
        try? context.save()
        editingScript = script
    }

    // MARK: - 卡片

    private func scriptCard(_ script: Script) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.brand)
                    .padding(8)
                    .background(Theme.brandSoft, in: .rect(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 6) {
                    Text(script.title.isEmpty ? "未命名台本" : script.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    Text(script.body.isEmpty ? "空台本，点开开始写" : script.preview)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Menu {
                    Button("编辑", systemImage: "square.and.pencil") { editingScript = script }
                    Button("从头提词", systemImage: "play.circle") {
                        script.lastReadTokenIndex = 0
                        activeScript = script
                    }
                    ShareLink(item: script.body) {
                        Label("分享台本", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button("删除", systemImage: "trash", role: .destructive) {
                        pendingDelete = script
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多操作")
            }

            HStack(spacing: 10) {
                Text("\(Format.count(script.characterCount)) 字")
                Text("建议 \(Format.duration(script.estimatedSeconds(wordsPerMinute: settings.wordsPerMinuteBaseline)))")
                Spacer()

                Button {
                    activeScript = script
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("开始提词")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.brand)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Theme.brandSoft, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("开始提词：\(script.title.isEmpty ? "未命名台本" : script.title)")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.hairline, lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { editingScript = script }
    }
}

#Preview {
    ScriptListView()
        .environment(AppSettings())
        .modelContainer(for: Script.self, inMemory: true)
}
