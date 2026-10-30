import XCTest

/// 台本主链路交互验证：新建 → 编辑 → 提词 → 拖动进度。
///
/// 全程走真实控件操作（点按钮、输入文字、拖进度条），不依赖调试直链，
/// 因此覆盖的是「列表里新建一篇稿子并直接开读」这条最常用的路径。
@MainActor
final class ScriptEditorFlowUITests: XCTestCase {

    private static let titleText = "UI 验证稿"
    private static let bodyText = """
    这是一段用于自动化验证的口播稿。它会经历新建、编辑、提词和拖动进度四个步骤。

    阅读线贴在屏幕上方靠近前置摄像头的位置，文字会按设定速度向上滚动，读过的部分自动变淡。

    最后一段用来保证内容长度足够，让进度条拖动之后能看到明显位移。
    """

    override func setUp() {
        continueAfterFailure = false
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 按无障碍文案取元素，不限控件类型。
    private func anyElement(_ app: XCUIApplication, label: String) -> XCUIElement {
        app.descendants(matching: .any)[label].firstMatch
    }

    /// 取可点元素：优先按按钮类型找，找不到再跨类型兜底。
    ///
    /// SwiftUI 的 Button 在无障碍层不一定映射成 button 类型，尤其带 `.buttonStyle(.plain)`
    /// 和自定义 label 时会被拆成 otherElements / staticTexts。
    private func tappable(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let asButton = app.buttons[label].firstMatch
        if asButton.exists { return asButton }
        return anyElement(app, label: label)
    }

    func testCreateEditPromptAndScrub() {
        let app = XCUIApplication()
        app.launchArguments = ["-cleanStore", "-tabScripts"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        // 1. 列表页的新建入口
        let newButton = tappable(app, "新建台本")
        if !newButton.waitForExistence(timeout: 20) {
            print("===== 台本列表可访问性树开始 =====")
            print(app.debugDescription)
            print("===== 台本列表可访问性树结束 =====")
        }
        XCTAssertTrue(newButton.exists, "台本列表应有「新建台本」入口")
        newButton.tap()

        // 2. 进入编辑页
        let editorTitle = app.staticTexts["编辑台本"].firstMatch
        XCTAssertTrue(editorTitle.waitForExistence(timeout: 10), "点新建后应打开编辑页")

        // 3. 填标题
        let titleField = app.textFields.firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "编辑页应有标题输入框")
        titleField.tap()
        titleField.typeText(Self.titleText)

        // 4. 填正文
        let bodyView = app.textViews.firstMatch
        XCTAssertTrue(bodyView.waitForExistence(timeout: 5), "编辑页应有正文输入框")
        bodyView.tap()
        bodyView.typeText(Self.bodyText)

        // 5. 收起键盘后截图，才能看到编辑区全貌
        let dismissKeyboard = tappable(app, "收起键盘")
        if dismissKeyboard.waitForExistence(timeout: 5) {
            dismissKeyboard.tap()
            sleep(1)
        }
        snapshot("17-编辑台本-iPhone")

        // 6. 「提词」按钮应随正文可用
        let promptButton = tappable(app, "提词")
        if !promptButton.waitForExistence(timeout: 8) {
            print("===== 编辑页可访问性树开始 =====")
            print(app.debugDescription)
            print("===== 编辑页可访问性树结束 =====")
        }
        XCTAssertTrue(promptButton.exists, "编辑页应有「提词」按钮")
        XCTAssertTrue(promptButton.isEnabled, "有正文后「提词」应可用")
        promptButton.tap()

        // 6. 提词页出现，进度条可读
        let progress = anyElement(app, label: "阅读进度")
        XCTAssertTrue(progress.waitForExistence(timeout: 20), "应进入提词页并出现阅读进度")
        let before = progress.value as? String ?? ""
        snapshot("18-提词初始-iPhone")

        // 7. 真实拖动进度条：从 15% 拖到 70%
        let start = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let end = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: end)
        sleep(1)

        let after = progress.value as? String ?? ""
        XCTAssertNotEqual(before, after, "拖动进度条后进度应变化，实际 \(before) → \(after)")
        snapshot("19-提词拖动后-iPhone")

        // 8. 退回编辑页，再退回列表，确认台本已保存
        let closePrompter = tappable(app, "关闭提词")
        XCTAssertTrue(closePrompter.waitForExistence(timeout: 8), "提词页应有关闭按钮")
        closePrompter.tap()
        XCTAssertTrue(editorTitle.waitForExistence(timeout: 10), "关闭提词后应回到编辑页")
        let closeEditor = tappable(app, "关闭")
        XCTAssertTrue(closeEditor.waitForExistence(timeout: 8), "编辑页应有关闭按钮")
        closeEditor.tap()

        let savedCard = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", Self.titleText))
            .firstMatch
        XCTAssertTrue(savedCard.waitForExistence(timeout: 10), "新建的台本应出现在列表里")
        snapshot("20-台本列表-新增后-iPhone")
    }
}
