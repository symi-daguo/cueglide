import SwiftUI

/// 各页统一的页头：28pt 粗体标题 + 可选副标题 + 可选右侧操作。
///
/// 抽出来是为了让四个 Tab 的内容起点完全对齐。此前只有首页自定义了页头，
/// 其余页面用系统大标题，顶部比首页多出约 90pt 空白，切换 Tab 时内容会跳。
struct PageHeader<Trailing: View>: View {

    let title: String
    let subtitle: String?
    private let trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing
            }
            if let subtitle {
                Text(subtitle)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.top, 8)
    }
}

extension PageHeader where Trailing == EmptyView {

    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
