import UIKit

/// 提词文本渲染层。负责三件事：
/// 1. 把稿件排版成一份 NSAttributedString，并缓存「词 → 行 → y 坐标」；
/// 2. 按浮点词索引设置 contentOffset；
/// 3. 增量更新已读变淡与当前词高亮，每次只改 1–3 个词的属性。
/// 承载 UITextView 的容器。SwiftUI 只管理这个容器，容器自己把 textView 撑满，
/// 避免 UIViewRepresentable 的自动布局与手动设 frame 打架导致高度为 1。
final class PrompterHostView: UIView {

    let textView = UITextView(usingTextLayoutManager: false)
    var onLayout: ((CGSize) -> Void)?
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if textView.frame != bounds {
            textView.frame = bounds
        }
        guard bounds.width > 1, bounds.height > 1 else { return }
        if abs(bounds.width - lastSize.width) > 0.5 || abs(bounds.height - lastSize.height) > 0.5 {
            lastSize = bounds.size
            onLayout?(bounds.size)
        }
    }
}

@MainActor
final class PrompterRenderer {

    struct Metrics {
        var pointsPerToken: Double = 40
        var unitsPerToken: Double = 1.4
        var totalHeight: CGFloat = 0
    }

    private struct LineInfo {
        let charRange: NSRange
        let minY: CGFloat
    }

    let hostView: PrompterHostView
    var textView: UITextView { hostView.textView }

    private(set) var tokenized: TokenizedScript
    private(set) var config: DisplayConfig
    private(set) var metrics = Metrics()
    private var lines: [LineInfo] = []
    private var lastCurrentToken: Int = -1
    private var lastReadBoundary: Int = 0
    private var lastLayoutWidth: CGFloat = 0
    private var viewportHeight: CGFloat = 0

    init(tokenized: TokenizedScript, config: DisplayConfig) {
        self.tokenized = tokenized
        self.config = config

        // 提词需要全篇精确坐标，用 TextKit 1 的 NSLayoutManager 一次性测量更直接。
        let host = PrompterHostView()
        let view = host.textView
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = true
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = .zero
        view.contentInset = .zero
        view.layoutManager.allowsNonContiguousLayout = false
        self.hostView = host

        rebuildText()
    }

    // MARK: - 配置

    func apply(tokenized newTokenized: TokenizedScript, config newConfig: DisplayConfig, width: CGFloat) {
        var needsRebuild = false
        if newTokenized.source != tokenized.source {
            tokenized = newTokenized
            needsRebuild = true
        }
        if newConfig.fontSize != config.fontSize
            || newConfig.fontWeight != config.fontWeight
            || newConfig.lineSpacing != config.lineSpacing
            || newConfig.horizontalInset != config.horizontalInset
            || newConfig.palette != config.palette {
            needsRebuild = true
        }
        config = newConfig

        // 上一次测量如果在视图还没布局时失败，参数虽未变也必须重建，否则永远测不出来。
        if needsRebuild || !isMeasured || abs(width - lastLayoutWidth) > 0.5 {
            rebuildText(width: width)
        } else {
            textView.backgroundColor = config.palette.background
        }
    }

    // MARK: - 排版

    private func rebuildText(width: CGFloat = 0) {
        lastLayoutWidth = width
        textView.backgroundColor = config.palette.background
        textView.textContainerInset = insets(for: viewportHeight, width: width)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = config.lineSpacing
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping

        let font = UIFont.systemFont(ofSize: config.fontSize, weight: config.fontWeight.uiWeight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: config.palette.foreground,
            .paragraphStyle: paragraph
        ]

        textView.attributedText = NSAttributedString(string: tokenized.source, attributes: attributes)
        lastCurrentToken = -1
        lastReadBoundary = 0
        measure()
    }

    /// 遍历行片段建立「字符区间 → y」索引，词坐标由二分查找得到，避免逐词测量。
    private func measure() {
        let layoutManager = textView.layoutManager
        let textContainer = textView.textContainer
        let storage = textView.textStorage
        guard storage.length > 0, textView.bounds.width > 1, textView.bounds.height > 1 else {
            lines = []
            metrics = Metrics()
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let fullGlyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: storage.length),
            actualCharacterRange: nil
        )

        var collected: [LineInfo] = []
        collected.reserveCapacity(1024)
        layoutManager.enumerateLineFragments(forGlyphRange: fullGlyphRange) { _, usedRect, _, glyphRange, _ in
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            collected.append(LineInfo(charRange: charRange, minY: usedRect.minY))
        }
        lines = collected

        let contentHeight = layoutManager.usedRect(for: textContainer).height
        let tokenCount = max(tokenized.totalTokens, 1)
        let lineCount = max(collected.count, 1)

        var pointsPerToken = Double(contentHeight) / Double(tokenCount)
        if lineCount > 1 {
            let avgLineHeight = (collected[lineCount - 1].minY - collected[0].minY) / CGFloat(lineCount - 1)
            let tokensPerLine = Double(tokenCount) / Double(lineCount)
            if tokensPerLine > 0.2, avgLineHeight > 1 {
                pointsPerToken = Double(avgLineHeight) / tokensPerLine
            }
        }

        metrics = Metrics(
            pointsPerToken: max(pointsPerToken, 1),
            unitsPerToken: Double(max(tokenized.speechUnitCount, 1)) / Double(tokenCount),
            totalHeight: contentHeight
        )
    }

    var isMeasured: Bool { !lines.isEmpty }

    /// 阅读列的最大宽度。iPhone Duo 展开、iPad 横屏时若不限宽，一行会排到十几个词，
    /// 视线扫视距离过长，朗读节奏会被拖慢。
    private let maxReadingColumn: CGFloat = 560

    /// 阅读线以上留出整段空白，保证第 0 个词也落在阅读线上而不是顶到状态栏。
    private func insets(for height: CGFloat, width: CGFloat = 0) -> UIEdgeInsets {
        let anchor = height > 0
            ? height * config.readingLine.viewportRatio
            : 120
        let bottom = max(height - anchor - 40, 40)

        let availableWidth = width > 1 ? width : textView.bounds.width
        let extraSide = max((availableWidth - maxReadingColumn) / 2, 0)
        let side = config.horizontalInset + extraSide

        return UIEdgeInsets(top: anchor, left: side, bottom: bottom, right: side)
    }

    /// 视口尺寸确定或变化后调用，重设内容内边距并重新测量。
    func setViewportHeight(_ height: CGFloat) {
        guard height > 1 else { return }
        let changed = abs(height - viewportHeight) > 1
        if changed {
            viewportHeight = height
            textView.textContainerInset = insets(for: height)
        }
        if changed || !isMeasured {
            measure()
        }
    }

    /// 宽度变化时（折叠展开、旋转、外接屏）重算列宽与内边距。
    func updateWidth(_ width: CGFloat) {
        guard width > 1 else { return }
        textView.textContainerInset = insets(for: viewportHeight, width: width)
        measure()
    }

    // MARK: - 定位

    /// 词序号对应的内容 y 坐标。
    func contentY(forToken index: Int) -> CGFloat {
        guard !lines.isEmpty, !tokenized.tokens.isEmpty else { return 0 }
        let clamped = min(max(index, 0), tokenized.tokens.count - 1)
        let charOffset = tokenized.tokens[clamped].nsRange.location
        return contentY(forCharacterOffset: charOffset) + textView.textContainerInset.top
    }

    private func contentY(forCharacterOffset offset: Int) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        var low = 0
        var high = lines.count - 1
        var result = lines[0].minY
        while low <= high {
            let mid = (low + high) / 2
            let line = lines[mid]
            if offset < line.charRange.location {
                high = mid - 1
            } else if offset >= line.charRange.location + max(line.charRange.length, 1) {
                result = line.minY
                low = mid + 1
            } else {
                return line.minY
            }
        }
        return result
    }

    /// 把浮点词索引滚到阅读线位置。
    func scroll(toTokenPosition position: Double, viewportHeight: CGFloat) {
        guard !lines.isEmpty else { return }
        let index = Int(position.rounded())
        let y = contentY(forToken: index)
        let anchor = viewportHeight * config.readingLine.viewportRatio
        var target = y - anchor

        let maxOffset = max(textView.contentSize.height - viewportHeight, 0)
        target = min(max(target, 0), maxOffset)
        textView.contentOffset = CGPoint(x: 0, y: target)
    }

    /// 视口某一点对应的词序号，用于点按跳转。
    func tokenIndex(atViewportY viewportY: CGFloat) -> Int {
        guard !lines.isEmpty, !tokenized.tokens.isEmpty else { return 0 }
        let contentY = viewportY + textView.contentOffset.y - textView.textContainerInset.top
        var low = 0
        var high = lines.count - 1
        var chosen = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].minY <= contentY {
                chosen = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return tokenIndex(forCharacterOffset: lines[chosen].charRange.location)
    }

    private func tokenIndex(forCharacterOffset offset: Int) -> Int {
        tokenized.tokenIndex(forUTF16Offset: offset)
    }

    // MARK: - 高亮

    /// 增量更新：已读区间只推进不回溯，当前词只改相邻两处。
    func highlight(currentToken: Int) {
        let storage = textView.textStorage
        guard storage.length > 0, !tokenized.tokens.isEmpty else { return }
        let current = min(max(currentToken, 0), tokenized.tokens.count - 1)
        guard current != lastCurrentToken else { return }

        let dimColor = config.palette.foreground.withAlphaComponent(config.dimReadOpacity)
        let baseColor = config.palette.foreground
        let highlightColor = config.palette.highlight
        let highlightBackground = config.palette.highlight.withAlphaComponent(0.16)

        storage.beginEditing()

        // 已读边界推进
        if current > lastReadBoundary {
            if let range = tokenized.nsRange(forTokenRange: lastReadBoundary...(current - 1)) {
                storage.addAttribute(.foregroundColor, value: dimColor, range: range)
                storage.removeAttribute(.backgroundColor, range: range)
            }
            lastReadBoundary = current
        } else if current < lastReadBoundary {
            // 往回跳：把退回的部分恢复成未读色
            if let range = tokenized.nsRange(forTokenRange: current...(lastReadBoundary - 1)) {
                storage.addAttribute(.foregroundColor, value: baseColor, range: range)
            }
            lastReadBoundary = current
        }

        // 清掉上一个当前词
        if lastCurrentToken >= 0, lastCurrentToken < tokenized.tokens.count {
            let old = tokenized.tokens[lastCurrentToken].nsRange
            storage.addAttribute(.foregroundColor, value: dimColor, range: old)
            storage.removeAttribute(.backgroundColor, range: old)
            storage.addAttribute(.foregroundColor, value: dimColor, range: old)
        }

        // 标记新的当前词
        let tokenRange = tokenized.tokens[current].nsRange
        storage.addAttribute(.foregroundColor, value: highlightColor, range: tokenRange)
        storage.addAttribute(.backgroundColor, value: highlightBackground, range: tokenRange)

        storage.endEditing()
        lastCurrentToken = current
    }

    /// 跳到开头时把高亮状态一起复位。
    func resetHighlight() {
        let storage = textView.textStorage
        guard storage.length > 0 else { return }
        storage.beginEditing()
        storage.addAttribute(
            .foregroundColor,
            value: config.palette.foreground,
            range: NSRange(location: 0, length: storage.length)
        )
        storage.removeAttribute(
            .backgroundColor,
            range: NSRange(location: 0, length: storage.length)
        )
        storage.endEditing()
        lastCurrentToken = -1
        lastReadBoundary = 0
    }
}
