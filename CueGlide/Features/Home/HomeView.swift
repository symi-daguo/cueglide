import SwiftUI
import SwiftData

struct HomeView: View {

    /// 切到模板页。由 RootView 注入，避免首页自己管标签页状态。
    let onOpenTemplates: () -> Void

    @Environment(AppSettings.self) private var settings
    @Query(sort: [SortDescriptor(\Script.updatedAt, order: .reverse)]) private var scripts: [Script]
    @State private var request: PrompterRequest?
    @State private var showsFloating = false

    private var latest: Script? { scripts.first }

    struct PrompterRequest: Identifiable {
        let id = UUID()
        let script: Script
        let startVoice: Bool
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let latest {
                        heroCard(latest)
                    } else {
                        emptyHero
                    }
                    quickActions
                    templateEntry
                    if scripts.count > 1 {
                        recentSection
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.canvas)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if ProcessInfo.processInfo.arguments.contains("-openFloating") {
                    try? await Task.sleep(for: .milliseconds(400))
                    showsFloating = true
                }
            }
            .sheet(isPresented: $showsFloating) {
                FloatingPrompterView()
            }
            .fullScreenCover(item: $request) { request in
                PrompterView(
                    script: request.script,
                    display: settings.display,
                    scroll: settings.scroll,
                    autoStartVoice: request.startVoice
                )
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("CueGlide")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("免费开源")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.brand)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.brandSoft, in: .capsule)
            }
            Text("编、拍、读，只做提词")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 8)
    }

    // MARK: - 主卡

    private func heroCard(_ script: Script) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text("上次读到 · \(Format.relative(script.updatedAt))")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.textSecondary)

            Text(script.title.isEmpty ? "未命名台本" : script.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text(script.preview)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 12) {
                metric("\(Format.count(script.characterCount)) 字")
                metric("约 \(Format.duration(script.estimatedSeconds(wordsPerMinute: settings.wordsPerMinuteBaseline)))")

                Spacer()

                Button {
                    request = PrompterRequest(script: script, startVoice: false)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("开始提词")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Theme.brand, in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.hairline, lineWidth: 0.5)
        }
    }

    private var emptyHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("还没有台本")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("在「台本」里新建一篇，或者从模板挑一个骨架开始。")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.hairline, lineWidth: 0.5)
        }
    }

    // MARK: - 快捷入口

    private var quickActions: some View {
        HStack(spacing: 12) {
            quickCard(
                title: "全屏提词",
                subtitle: "纯净阅读",
                symbol: "text.alignleft",
                tint: Theme.accentBlue,
                symbolColor: Theme.brand
            ) {
                if let latest {
                    request = PrompterRequest(script: latest, startVoice: false)
                }
            }

            quickCard(
                title: "语音跟读",
                subtitle: "念到哪滚到哪",
                symbol: "waveform",
                tint: Theme.accentGreen,
                symbolColor: Color(uiColor: UIColor(rgb: 0x2F9E64))
            ) {
                if let latest {
                    request = PrompterRequest(script: latest, startVoice: true)
                }
            }

            quickCard(
                title: "悬浮提词",
                subtitle: "浮在相机之上",
                symbol: "pip.fill",
                tint: Theme.brandSoft,
                symbolColor: Theme.brand
            ) {
                showsFloating = true
            }
        }
    }

    private func quickCard(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        symbolColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(symbolColor)
                    Spacer()
                }
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
            .background(tint, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 最近

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近台本")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(scripts.dropFirst().prefix(8))) { script in
                        Button {
                            request = PrompterRequest(script: script, startVoice: false)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(script.title.isEmpty ? "未命名台本" : script.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Text("\(Format.count(script.characterCount)) 字")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(12)
                            .frame(width: 148, height: 92, alignment: .leading)
                            .background(Theme.surface, in: .rect(cornerRadius: 14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Theme.hairline, lineWidth: 0.5)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var templateEntry: some View {
        Button {
            onOpenTemplates()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                Text("不会写？从场景模板开始")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.brand)
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Theme.brandSoft.opacity(0.6), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11))
            Text("无账号、无会员、无云端，全部数据留在本机")
                .font(.system(size: 11))
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.top, 6)
    }

    private func metric(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
    }
}

#Preview {
    HomeView(onOpenTemplates: {})
        .environment(AppSettings())
        .modelContainer(for: Script.self, inMemory: true)
}
