import SwiftUI
import SwiftData

struct RootView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Query private var scripts: [Script]

    @State private var tab: AppTab = RootView.launchTab()
    @State private var deepLinkScript: Script?

    var body: some View {
        TabView(selection: $tab) {
            Tab("开拍", systemImage: "record.circle", value: AppTab.home) {
                HomeView()
            }
            Tab("台本", systemImage: "doc.text", value: AppTab.scripts) {
                ScriptListView()
            }
            Tab("模板", systemImage: "square.grid.2x2", value: AppTab.templates) {
                TemplatesView()
            }
            Tab("设置", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .task {
            seedSampleIfNeeded()
            handleLaunchArguments()
        }
        .fullScreenCover(item: $deepLinkScript) { script in
            PrompterView(
                script: script,
                display: settings.display,
                scroll: settings.scroll
            )
        }
    }

    /// 支持 `-tabScripts` / `-tabTemplates` / `-tabSettings` 指定首屏，方便自动化验证。
    static func launchTab() -> AppTab {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-tabScripts") { return .scripts }
        if args.contains("-tabTemplates") { return .templates }
        if args.contains("-tabSettings") { return .settings }
        return .home
    }

    /// 支持 `-openPrompter` 启动参数直接进提词页，方便自动化验证与后续快捷指令复用。
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-openPrompter") else { return }
        let target = scripts.first ?? {
            let fallback = Script(title: "验证稿", body: SampleText.long)
            context.insert(fallback)
            try? context.save()
            return fallback
        }()
        deepLinkScript = target
    }

    /// 首次启动塞一篇示例稿，让用户点开就能看到真实滚动效果。
    private func seedSampleIfNeeded() {
        guard !settings.hasInsertedSampleScript, scripts.isEmpty else { return }
        let sample = Script(
            title: "用这篇体验提词",
            body: """
            欢迎使用 CueGlide，这是一款免费开源的提词器。

            现在你看到的就是提词页。文字会按照你设定的速度向上滚动，正在读的那一句会被高亮，读过的部分会自动变淡，这样视线不会往回跑。

            默认的阅读线贴在屏幕上方，靠近前置摄像头的位置。这么设计是为了让你的视线尽量接近镜头，观众看起来才像在看你，而不是在看稿子。

            手指在屏幕上向下滑，可以手动往回翻；向上滑，可以往前赶。双击屏幕暂停，再双击继续。底部控制条会在三秒后自动淡出，点一下屏幕就能叫回来。

            右下角的滑块里可以改配色、改镜像、改阅读线位置。如果你用的是分光镜提词器，把镜像打开成水平翻转就好。

            整篇稿子读完之后，进度会记在台本里，下次打开从上次停下的地方继续。

            这里没有任何账号，没有会员，没有云端。你的稿子只存在这台设备上。
            """,
            groupName: "示例"
        )
        context.insert(sample)
        try? context.save()
        settings.hasInsertedSampleScript = true
    }
}

enum AppTab: Hashable {
    case home
    case scripts
    case templates
    case settings
}

#Preview {
    RootView()
        .environment(AppSettings())
        .modelContainer(for: Script.self, inMemory: true)
}
