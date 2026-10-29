import UIKit

/// 把提词内容离屏渲染成一帧图片，供画中画浮窗使用。
///
/// 画中画要求输入的是视频帧，所以不能直接塞一个 UIView 进去。
/// 这里用 NSLayoutManager 离屏排版，每次只绘制可视范围的字形，避免全稿重排。
@MainActor
final class FloatingFrameRenderer {

    private let storage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let container: NSTextContainer
    private let tokenized: TokenizedScript
    private let config: DisplayConfig
    private let canvasSize: CGSize
    private var lastHighlighted: NSRange?

    init(tokenized: TokenizedScript, config: DisplayConfig, canvasSize: CGSize) {
        self.tokenized = tokenized
        self.config = config
        self.canvasSize = canvasSize

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = config.lineSpacing
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: config.fontSize, weight: config.fontWeight.uiWeight),
            .foregroundColor: config.palette.foreground,
            .paragraphStyle: paragraph
        ]

        let attributed = NSAttributedString(string: tokenized.source, attributes: attributes)
        storage = NSTextStorage(attributedString: attributed)

        let container = NSTextContainer(
            size: CGSize(
                width: max(canvasSize.width - config.horizontalInset * 2, 80),
                height: .greatestFiniteMagnitude
            )
        )
        container.lineFragmentPadding = 0

        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        self.container = container
        self.layoutManager = manager
        manager.ensureLayout(for: container)
    }

    /// 当前词在排版坐标系里的纵坐标。
    private func contentY(forToken index: Int) -> CGFloat {
        guard !tokenized.tokens.isEmpty else { return 0 }
        let clamped = min(max(index, 0), tokenized.tokens.count - 1)
        let charRange = tokenized.tokens[clamped].nsRange
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        return rect.minY
    }

    /// 渲染一帧。当前词固定落在画面的 26% 高度处。
    func image(atToken index: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        // 2 倍输出，720×1280 像素对应 360×640 点
        format.scale = 2
        format.opaque = true

        let anchorRatio: CGFloat = 0.26
        let anchorY = canvasSize.height * anchorRatio
        let targetY = contentY(forToken: index)
        let offset = targetY - anchorY

        applyHighlight(at: index)

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { context in
            let cg = context.cgContext
            config.palette.background.setFill()
            cg.fill(CGRect(origin: .zero, size: canvasSize))

            cg.saveGState()
            cg.translateBy(x: config.horizontalInset, y: -offset)
            let drawRect = CGRect(
                x: 0,
                y: offset,
                width: canvasSize.width - config.horizontalInset * 2,
                height: canvasSize.height
            )
            let glyphRange = layoutManager.glyphRange(forBoundingRect: drawRect, in: container)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
            cg.restoreGState()
        }
    }

    /// 只改当前词的背景色，其他词保持原样，避免每次重建整段属性。
    private func applyHighlight(at index: Int) {
        guard !tokenized.tokens.isEmpty else { return }
        let clamped = min(max(index, 0), tokenized.tokens.count - 1)
        let newRange = tokenized.tokens[clamped].nsRange

        if let last = lastHighlighted, last.location != newRange.location {
            storage.removeAttribute(.backgroundColor, range: last)
            storage.addAttribute(.foregroundColor, value: config.palette.foreground, range: last)
        }
        if lastHighlighted?.location != newRange.location {
            storage.addAttribute(
                .backgroundColor,
                value: config.palette.highlight.withAlphaComponent(0.28),
                range: newRange
            )
            storage.addAttribute(.foregroundColor, value: config.palette.highlight, range: newRange)
            lastHighlighted = newRange
        }
    }

    var totalTokens: Int { tokenized.totalTokens }
}
