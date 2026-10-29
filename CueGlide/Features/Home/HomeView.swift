import SwiftUI
import SwiftData

struct HomeView: View {

    @Environment(AppSettings.self) private var settings
    @Query(sort: [SortDescriptor(\Script.updatedAt, order: .reverse)]) private var scripts: [Script]
    @State private var activeScript: Script?

    private var latest: Script? { scripts.first }

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
            .fullScreenCover(item: $activeScript) { script in
                PrompterView(
                    script: script,
                    display: settings.display,
                    scroll: settings.scroll
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
        VStack(alignment: .leading, spacing: 14) {
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
                    activeScript = script
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
        .padding(18)
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
        .padding(18)
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
                symbolColor: Theme.brand,
                badge: nil
            ) {
                activeScript = latest
            }

            quickCard(
                title: "提词拍摄",
                subtitle: "边读边录",
                symbol: "camera.fill",
                tint: Theme.accentGreen,
                symbolColor: Color(uiColor: UIColor(rgb: 0x2F9E64)),
                badge: "待开放"
            ) {}

            quickCard(
                title: "悬浮提词",
                subtitle: "盖在其他 App 上",
                symbol: "pip.fill",
                tint: Theme.brandSoft,
                symbolColor: Theme.brand,
                badge: "待开放"
            ) {}
        }
    }

    private func quickCard(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        symbolColor: Color,
        badge: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(symbolColor)
                    Spacer()
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
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
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
            .background(tint, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(badge != nil)
        .opacity(badge == nil ? 1 : 0.55)
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
                            activeScript = script
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
    HomeView()
        .environment(AppSettings())
        .modelContainer(for: Script.self, inMemory: true)
}
