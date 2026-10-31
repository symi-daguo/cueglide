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
                HomeView(onOpenTemplates: { tab = .templates })
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
            cleanStoreIfRequested()
            seedSampleIfNeeded()
            handleLaunchArguments()
            #if DEBUG
            MemoryProbe.startIfRequested()
            #endif
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

    /// 调试与自动化验证入口。全部通过启动参数触发，正常使用时不会命中：
    /// - `-openPrompter` 直接进提词页
    /// - `-autoPlay` 进提词页后自动播放
    /// - `-autoVoice` 进提词页后自动开启语音跟读
    /// - `-tabScripts` / `-tabTemplates` / `-tabSettings` 指定首屏
    /// - `-openFloating` / `-openCapture` 打开悬浮提词 / 提词拍摄
    /// - `-stressPrompt` 注入万字长稿并进提词页，用于性能压测
    /// - `-fpsProbe` 打开帧率采样，结果输出到系统日志
    /// - `-cleanStore` 清空本地台本并重新播种示例，让自动化验证从固定状态开始
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments

        // 性能压测入口：注入一篇万字长稿并直接进提词页
        if args.contains("-stressPrompt") {
            let stress = Script(title: "性能压测稿", body: SampleText.long)
            context.insert(stress)
            try? context.save()
            deepLinkScript = stress
            return
        }

        guard args.contains("-openPrompter") else { return }
        let target = scripts.first ?? {
            let fallback = Script(title: "验证稿", body: SampleText.long)
            context.insert(fallback)
            try? context.save()
            return fallback
        }()
        deepLinkScript = target
    }

    /// `-cleanStore`：清空台本并允许重新播种示例。
    ///
    /// UI 测试每次启动都从同一状态开始，避免上一轮创建的台本污染列表与截图。
    /// 仅在启动参数命中时执行，正常启动不碰用户数据。
    private func cleanStoreIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-cleanStore") else { return }
        let existing = scripts
        for script in existing {
            context.delete(script)
        }
        try? context.save()
        settings.hasInsertedSampleScript = false
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
