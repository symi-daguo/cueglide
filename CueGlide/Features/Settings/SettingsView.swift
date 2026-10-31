import SwiftUI

struct SettingsView: View {

    @Environment(AppSettings.self) private var settings

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: "设置", subtitle: "提词默认参数与偏好")
                    displayGroup
                    scrollGroup
                    powerGroup
                    remoteGroup
                    aboutGroup
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 100)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - 提词显示

    private var displayGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupTitle("提词显示")

            card {
                HStack {
                    rowLabel("配色")
                    Spacer()
                    Menu {
                        ForEach(PromptPalette.allCases, id: \.self) { palette in
                            Button(palette.displayName) {
                                var next = settings.display
                                next.palette = palette
                                settings.display = next
                            }
                        }
                    } label: {
                        menuValue(settings.display.palette.displayName)
                    }
                }
                .padding(.vertical, 6)

                divider

                HStack {
                    rowLabel("镜像")
                    Spacer()
                    Menu {
                        ForEach(MirrorMode.allCases) { mode in
                            Button(mode.displayName) {
                                var next = settings.display
                                next.mirror = mode
                                settings.display = next
                            }
                        }
                    } label: {
                        menuValue(settings.display.mirror.displayName)
                    }
                }
                .padding(.vertical, 6)

                divider

                HStack {
                    rowLabel("阅读线位置")
                    Spacer()
                    Menu {
                        ForEach(ReadingLinePosition.allCases) { position in
                            Button(position.displayName) {
                                var next = settings.display
                                next.readingLine = position
                                settings.display = next
                            }
                        }
                    } label: {
                        menuValue(settings.display.readingLine.displayName)
                    }
                }
                .padding(.vertical, 6)

                divider

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        rowLabel("默认字号")
                        Spacer()
                        Text("\(Int(settings.display.fontSize)) pt")
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Slider(
                        value: Binding(
                            get: { settings.display.fontSize },
                            set: { newValue in
                                var next = settings.display
                                next.fontSize = newValue
                                settings.display = next
                            }
                        ),
                        in: 20...96,
                        step: 2
                    )
                    .tint(Theme.brand)
                }
                .padding(.vertical, 6)
            }

            hint("这些是每篇台本的初始参数，进提词页还能随时改。")
        }
    }

    // MARK: - 滚动

    private var scrollGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupTitle("滚动")

            card {
                HStack {
                    rowLabel("默认模式")
                    Spacer()
                    Menu {
                        ForEach(ScrollMode.allCases) { mode in
                            Button(mode.displayName) {
                                var next = settings.scroll
                                next.mode = mode
                                settings.scroll = next
                            }
                        }
                    } label: {
                        menuValue(settings.scroll.mode.displayName)
                    }
                }
                .padding(.vertical, 6)

                divider

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        rowLabel("语速基准")
                        Spacer()
                        Text("\(Int(settings.wordsPerMinuteBaseline)) 字/分")
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Slider(
                        value: Binding(
                            get: { settings.wordsPerMinuteBaseline },
                            set: { settings.wordsPerMinuteBaseline = $0 }
                        ),
                        in: 120...420,
                        step: 10
                    )
                    .tint(Theme.brand)
                }
                .padding(.vertical, 6)

                divider

                HStack {
                    rowLabel("开始倒计时")
                    Spacer()
                    Text("\(settings.scroll.countdown) 秒")
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    Stepper(
                        "",
                        value: Binding(
                            get: { settings.scroll.countdown },
                            set: { newValue in
                                var next = settings.scroll
                                next.countdown = newValue
                                settings.scroll = next
                            }
                        ),
                        in: 0...10
                    )
                    .labelsHidden()
                }
                .padding(.vertical, 6)

                divider

                HStack {
                    rowLabel("识别语言")
                    Spacer()
                    Menu {
                        Button("跟随系统") { settings.speechLocaleIdentifier = "" }
                        Button("中文（普通话）") { settings.speechLocaleIdentifier = "zh-CN" }
                        Button("English（美国）") { settings.speechLocaleIdentifier = "en-US" }
                    } label: {
                        menuValue(speechLocaleLabel)
                    }
                }
                .padding(.vertical, 6)
            }

            hint("语速基准同时用于台本列表里的录制时长估算。语音跟读全程在本机完成，音频不出设备。")
        }
    }

    // MARK: - 电源

    private var powerGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupTitle("显示与电源")

            card {
                Toggle(isOn: Binding(
                    get: { settings.keepScreenAwake },
                    set: { settings.keepScreenAwake = $0 }
                )) {
                    rowLabel("提词时屏幕常亮")
                }
                .tint(Theme.brand)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - 遥控

    private var remoteGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupTitle("外接遥控")

            card {
                ForEach(Array(RemoteController.keyMap.enumerated()), id: \.offset) { index, pair in
                    if index > 0 {
                        divider
                    }
                    HStack {
                        Text(pair.0)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(pair.1)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 6)
                }
            }

            hint("蓝牙演示器、翻页笔、脚踏开关在系统看来都是键盘，无需配对到应用内，连上系统即可使用。")
        }
    }

    // MARK: - 关于

    private var aboutGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupTitle("关于")

            card {
                infoRow("版本", Bundle.main.appVersion)
                divider
                infoRow("协议", "MIT")
                divider
                infoRow("数据存储", "仅本机")
                divider
                Link(destination: URL(string: "https://github.com/symi-daguo/cueglide/issues")!) {
                    HStack {
                        rowLabel("问题反馈")
                        Spacer()
                        Text("GitHub Issues")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.vertical, 6)
                }
            }

            hint("CueGlide 不收集任何数据，不需要账号，不发起网络请求。台本、设置、录像全部留在设备上。")
        }
    }

    // MARK: - 组件

    private var speechLocaleLabel: String {
        switch settings.speechLocaleIdentifier {
        case "": "跟随系统"
        case "zh-CN": "中文（普通话）"
        case "en-US": "English"
        default: settings.speechLocaleIdentifier
        }
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.leading, 4)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Theme.hairline, lineWidth: 0.5)
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Theme.textPrimary)
    }

    private func menuValue(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 14))
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Theme.textSecondary)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            rowLabel(title)
            Spacer()
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 6)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.vertical, 2)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.6.28"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(AppSettings())
}
