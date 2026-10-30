import SwiftUI
import SwiftData
import UIKit

struct ScriptEditorView: View {

    @Bindable var script: Script
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context

    @State private var activeScript: Script?
    @State private var liveCharacters: Int = 0
    @State private var statsTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("台本标题", text: $script.title, axis: .vertical)
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                Divider().opacity(0.4)

                TextEditor(text: $script.body)
                    .font(.system(size: 16))
                    .lineSpacing(6)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .overlay(alignment: .topLeading) {
                        if script.body.isEmpty {
                            Text("在这里粘贴或输入你的口播稿……")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 21)
                                .padding(.top, 16)
                                .allowsHitTesting(false)
                        }
                    }

                statusBar
            }
            .background(Theme.canvas)
            .navigationTitle("编辑台本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { close() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        script.refreshDerivedFields()
                        try? context.save()
                        activeScript = script
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("提词")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .disabled(script.body.isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { dismissKeyboard() }
                }
            }
            .fullScreenCover(item: $activeScript) { target in
                PrompterView(
                    script: target,
                    display: settings.display,
                    scroll: settings.scroll
                )
            }
            .onAppear {
                liveCharacters = script.characterCount
            }
            .onChange(of: script.body) { _, newValue in
                liveCharacters = newValue.unicodeScalars.reduce(into: 0) { partial, scalar in
                    if !CharacterSet.whitespacesAndNewlines.contains(scalar) { partial += 1 }
                }
                scheduleStatsRefresh()
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Label("\(Format.count(liveCharacters)) 字", systemImage: "textformat.size")
            Label(
                Format.duration(estimatedSeconds),
                systemImage: "clock"
            )
            Spacer()
            Text("按语速 \(Int(settings.wordsPerMinuteBaseline)) 字/分 估算")
                .foregroundStyle(Theme.textTertiary)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private var estimatedSeconds: Int {
        guard settings.wordsPerMinuteBaseline > 0 else { return 0 }
        return Int((Double(liveCharacters) / settings.wordsPerMinuteBaseline * 60).rounded())
    }

    /// 输入时只数非空白字符，完整分词延迟 0.4 秒再做，避免长稿输入卡顿。
    private func scheduleStatsRefresh() {
        statsTask?.cancel()
        statsTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            script.refreshDerivedFields()
        }
    }

    /// 收起键盘。编辑长稿时键盘会挡住正文，需要一个明确的收起点。
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func close() {
        script.refreshDerivedFields()
        if script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.delete(script)
        }
        try? context.save()
        dismiss()
    }
}
