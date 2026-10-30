import XCTest
import UIKit
@testable import CueGlide

/// 提词渲染层的排版测量、定位与高亮验证。
///
/// 这里的用例针对 0.0.2 踩过的坑：视图还没布局时测量失败，而参数没变就不再重测，
/// 表现为「提词页一个字都不显示」。排版测量是提词器的地基，回归成本高，所以单独覆盖。
@MainActor
final class PrompterRendererTests: XCTestCase {

    // MARK: - 辅助

    private let body = """
    这是一段用于渲染验证的稿件。阅读线贴在屏幕上方靠近前置摄像头的位置，文字会按设定速度向上滚动，读过的部分自动变淡，视线不会往回跑。

    横屏时前置摄像头在屏幕侧边，所以阅读列要收窄，避免眼睛左右扫离镜头。这一条是横屏适配里最容易忽略的细节。
    """

    private func makeRenderer(
        text: String? = nil,
        config: DisplayConfig = .default
    ) -> PrompterRenderer {
        let source = text ?? body
        return PrompterRenderer(tokenized: ScriptTokenizer.tokenize(source), config: config)
    }

    /// 模拟一次真实布局：宿主容器拿到尺寸，文本视图撑满，然后重新测量。
    private func layout(_ renderer: PrompterRenderer, width: CGFloat, height: CGFloat) {
        let size = CGSize(width: width, height: height)
        renderer.hostView.frame = CGRect(origin: .zero, size: size)
        renderer.hostView.layoutIfNeeded()
        if renderer.textView.bounds.width < 1 || renderer.textView.bounds.height < 1 {
            renderer.textView.frame = CGRect(origin: .zero, size: size)
        }
        renderer.setViewportHeight(height)
        renderer.updateWidth(width)
    }

    // MARK: - 阅读线

    func testPortraitAnchorFollowsReadingLineRatio() {
        let renderer = makeRenderer()
        layout(renderer, width: 393, height: 852)
        XCTAssertEqual(renderer.textView.textContainerInset.top, 852 * 0.14, accuracy: 0.5)
    }

    func testLandscapeAnchorRaisedTo22Percent() {
        let renderer = makeRenderer()
        layout(renderer, width: 852, height: 393)
        XCTAssertEqual(renderer.textView.textContainerInset.top, 393 * 0.22, accuracy: 0.5)
    }

    func testLandscapeAnchorHas76PointFloor() {
        let renderer = makeRenderer()
        layout(renderer, width: 800, height: 300)
        XCTAssertEqual(renderer.textView.textContainerInset.top, 76, accuracy: 0.5)
    }

    func testBottomInsetKeepsAtLeastOneLine() {
        let renderer = makeRenderer()
        layout(renderer, width: 800, height: 120)
        XCTAssertGreaterThanOrEqual(renderer.textView.textContainerInset.bottom, 40)
    }

    // MARK: - 列宽

    func testLandscapeColumnWidthCappedAt420() {
        var config = DisplayConfig.default
        config.horizontalInset = 28
        let renderer = makeRenderer(config: config)
        layout(renderer, width: 852, height: 393)

        // 两侧各 28 + (852 - 420) / 2 = 244，把一行压到约 12 个字
        XCTAssertEqual(renderer.textView.textContainerInset.left, 244, accuracy: 0.5)
        XCTAssertEqual(renderer.textView.textContainerInset.right, 244, accuracy: 0.5)
    }

    func testPortraitColumnKeepsBaseInsetOnNarrowScreen() {
        var config = DisplayConfig.default
        config.horizontalInset = 28
        let renderer = makeRenderer(config: config)
        layout(renderer, width: 393, height: 852)

        // 393 撑不满 560 的列宽上限，不应再额外加留白
        XCTAssertEqual(renderer.textView.textContainerInset.left, 28, accuracy: 0.5)
    }

    // MARK: - 测量

    func testMeasureProducesUsableMetrics() {
        let renderer = makeRenderer()
        layout(renderer, width: 393, height: 852)

        XCTAssertTrue(renderer.isMeasured)
        XCTAssertGreaterThan(renderer.metrics.pointsPerToken, 1)
        XCTAssertGreaterThan(renderer.metrics.totalHeight, 0)
        XCTAssertGreaterThan(renderer.metrics.unitsPerToken, 0)
    }

    /// 0.0.2 的回归点：0×0 时测量必然失败，真正布局之后必须能补测出来。
    func testMeasuresAfterZeroSizedFirstLayout() {
        let renderer = makeRenderer()
        XCTAssertFalse(renderer.isMeasured, "0×0 时不应测出结果")

        layout(renderer, width: 393, height: 852)
        XCTAssertTrue(renderer.isMeasured, "布局后必须补测成功")
    }

    func testFontSizeChangeRebuildsMetrics() {
        let renderer = makeRenderer()
        layout(renderer, width: 393, height: 852)
        let baseline = renderer.metrics.pointsPerToken

        var bigger = DisplayConfig.default
        bigger.fontSize = 64
        renderer.apply(tokenized: renderer.tokenized, config: bigger, width: 393)
        renderer.setViewportHeight(852)

        XCTAssertGreaterThan(renderer.metrics.pointsPerToken, baseline, "放大字号后行高应增加")
    }

    // MARK: - 定位

    func testContentYGrowsWithTokenIndexAndClamps() {
        let renderer = makeRenderer()
        layout(renderer, width: 393, height: 852)

        let first = renderer.contentY(forToken: 0)
        let last = renderer.contentY(forToken: renderer.tokenized.totalTokens - 1)

        XCTAssertLessThan(first, last)
        XCTAssertEqual(renderer.contentY(forToken: -10), first, accuracy: 0.5)
        XCTAssertEqual(renderer.contentY(forToken: 99_999), last, accuracy: 0.5)
    }

    func testScrollClampsWithinContentBounds() {
        let renderer = makeRenderer()
        layout(renderer, width: 393, height: 852)

        renderer.scroll(toTokenPosition: -50, viewportHeight: 852)
        XCTAssertEqual(renderer.textView.contentOffset.y, 0, accuracy: 0.5)

        renderer.scroll(toTokenPosition: Double(renderer.tokenized.totalTokens) * 10, viewportHeight: 852)
        let maxOffset = max(renderer.textView.contentSize.height - 852, 0)
        XCTAssertGreaterThanOrEqual(renderer.textView.contentOffset.y, 0)
        XCTAssertLessThanOrEqual(renderer.textView.contentOffset.y, maxOffset + 0.5)
    }

    func testTokenIndexAtViewportYReturnsSameLine() {
        let renderer = makeRenderer()
        layout(renderer, width: 393, height: 852)
        let total = renderer.tokenized.totalTokens

        for target in [0, total / 3, total / 2, total - 1] {
            renderer.scroll(toTokenPosition: Double(target), viewportHeight: 852)
            let viewportY = renderer.contentY(forToken: target) - renderer.textView.contentOffset.y
            let hit = renderer.tokenIndex(atViewportY: viewportY)

            XCTAssertLessThanOrEqual(hit, target, "命中不应越过目标词")
            XCTAssertLessThanOrEqual(target - hit, 20, "命中应落在同一行")
        }
    }

    // MARK: - 高亮

    func testHighlightMarksCurrentTokenAndDimsReadPart() {
        let renderer = makeRenderer()
        layout(renderer, width: 393, height: 852)
        renderer.highlight(currentToken: 5)

        let storage = renderer.textView.textStorage
        let current = renderer.tokenized.tokens[5].nsRange
        XCTAssertNotNil(
            storage.attribute(.backgroundColor, at: current.location, effectiveRange: nil),
            "当前词应有背景高亮"
        )

        let read = renderer.tokenized.tokens[0].nsRange
        guard let color = storage.attribute(.foregroundColor, at: read.location, effectiveRange: nil) as? UIColor else {
            return XCTFail("已读词应带前景色")
        }
        var alpha: CGFloat = 1
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        XCTAssertEqual(Double(alpha), renderer.config.dimReadOpacity, accuracy: 0.05, "已读词应变淡")
    }

    func testHighlightBackwardRestoresUnreadColor() {
        let renderer = makeRenderer()
        layout(renderer, width: 393, height: 852)
        renderer.highlight(currentToken: 8)
        renderer.highlight(currentToken: 3)

        let storage = renderer.textView.textStorage
        let rolledBack = renderer.tokenized.tokens[5].nsRange

        XCTAssertNil(
            storage.attribute(.backgroundColor, at: rolledBack.location, effectiveRange: nil),
            "往回跳之后旧当前词不应保留背景"
        )
        if let color = storage.attribute(.foregroundColor, at: rolledBack.location, effectiveRange: nil) as? UIColor {
            var alpha: CGFloat = 1
            color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            XCTAssertEqual(alpha, 1, accuracy: 0.05, "退回的词应恢复未读色")
        }
    }

    func testResetHighlightClearsAllBackground() {
        let renderer = makeRenderer()
        layout(renderer, width: 393, height: 852)
        renderer.highlight(currentToken: 6)
        renderer.resetHighlight()

        let storage = renderer.textView.textStorage
        var hasBackground = false
        storage.enumerateAttribute(
            .backgroundColor,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if value != nil { hasBackground = true }
        }
        XCTAssertFalse(hasBackground)
    }

    // MARK: - 空稿

    func testEmptyScriptIsSafe() {
        let renderer = PrompterRenderer(tokenized: .empty, config: .default)
        renderer.setViewportHeight(852)
        renderer.updateWidth(393)
        renderer.highlight(currentToken: 3)
        renderer.resetHighlight()
        renderer.scroll(toTokenPosition: 5, viewportHeight: 852)

        XCTAssertFalse(renderer.isMeasured)
        XCTAssertEqual(renderer.contentY(forToken: 2), 0)
        XCTAssertEqual(renderer.tokenIndex(atViewportY: 100), 0)
    }
}
