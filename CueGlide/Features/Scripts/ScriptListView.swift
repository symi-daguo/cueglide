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
            .navigationTitle("台本")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索标题或正文")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
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

    private func createScript() {
        let script = Script(title: "未命名台本", body: "")
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
