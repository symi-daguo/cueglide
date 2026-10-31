import SwiftUI
import SwiftData
import PhotosUI

/// 新建或编辑自定义模板。
///
/// 内置的六个模板是只读静态数据，用户想改就「复制为我的模板」再编辑，
/// 这样内置内容不会被误删，也省去维护两套编辑权限。
struct TemplateEditorView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    private let existing: CustomTemplate?

    @State private var title: String
    @State private var scene: String
    @State private var summary: String
    @State private var scriptBody: String
    @State private var artwork: String
    @State private var photoItem: PhotosPickerItem?
    @State private var errorMessage: String?

    /// 可选场景，去掉「全部」这个筛选项。
    private var sceneOptions: [String] {
        TemplateCatalog.scenes.filter { $0 != "全部" } + ["自定义"]
    }

    /// - Parameters:
    ///   - template: 传值表示编辑已有模板，传 nil 表示新建。
    ///   - draft: 从「用 AI 生成」解析出来的字段，用于新建时预填。
    init(template: CustomTemplate? = nil, draft: TemplatePromptKit.Parsed? = nil) {
        existing = template
        _title = State(initialValue: template?.title ?? draft?.title ?? "")
        _scene = State(initialValue: template?.scene ?? draft?.scene ?? "自定义")
        _summary = State(initialValue: template?.summary ?? draft?.summary ?? "")
        _scriptBody = State(initialValue: template?.body ?? draft?.body ?? "")
        _artwork = State(initialValue: template?.artwork ?? "asset:TemplateHook")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("模板名称", text: $title)
                    Picker("场景", selection: $scene) {
                        ForEach(sceneOptions, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("一句话摘要", text: $summary, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section("正文骨架") {
                    TextEditor(text: $scriptBody)
                        .frame(minHeight: 220)
                        .font(.system(size: 14))
                }

                Section("配图") {
                    artworkPicker
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("从相册选一张", systemImage: "photo.on.rectangle")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "新建模板" : "编辑模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: photoItem) { _, item in
                loadPhoto(item)
            }
        }
    }

    // MARK: - 配图

    private var artworkPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(TemplateArtwork.builtIn, id: \.self) { name in
                        let identifier = "asset:" + name
                        Button {
                            artwork = identifier
                        } label: {
                            TemplateArtwork.image(for: identifier)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 104, height: 68)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(
                                            artwork == identifier ? Color.accentColor : Color.clear,
                                            lineWidth: 2.5
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            if artwork.hasPrefix("file:") {
                HStack(spacing: 8) {
                    TemplateArtwork.image(for: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 104, height: 68)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        }
                    Text("正在使用你上传的图片")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    errorMessage = "这张图片读不出来，换一张试试。"
                    return
                }
                if let identifier = TemplateArtwork.save(image) {
                    artwork = identifier
                    errorMessage = nil
                } else {
                    errorMessage = "图片保存失败，可能是存储空间不足。"
                }
            } catch {
                errorMessage = "读取相册失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 保存

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        if let existing {
            existing.title = trimmedTitle
            existing.scene = scene
            existing.summary = summary
            existing.body = scriptBody
            existing.artwork = artwork
        } else {
            let template = CustomTemplate(
                title: trimmedTitle,
                scene: scene,
                summary: summary,
                body: scriptBody,
                artwork: artwork
            )
            context.insert(template)
        }

        try? context.save()
        dismiss()
    }
}
