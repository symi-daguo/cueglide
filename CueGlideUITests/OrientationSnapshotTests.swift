import XCTest

/// 横竖屏截图工具。用于人工核验布局，不作为断言测试。
final class OrientationSnapshotTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = true
    }

    private func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 竖屏逐页截图。
    @MainActor
    func testPortraitScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-cleanStore"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        sleep(3)
        snapshot("01-竖屏-首页")

        app.terminate()
        app.launchArguments = ["-cleanStore", "-openPrompter"]
        app.launch()
        sleep(3)
        snapshot("02-竖屏-提词页")
    }

    /// 横屏逐页截图。
    @MainActor
    func testLandscapeScreens() {
        let app = XCUIApplication()
        // 相机与麦克风的系统弹窗会挡住布局，统一点「允许」，没有弹窗时忽略
        addUIInterruptionMonitor(withDescription: "系统权限") { alert in
            for label in ["允许", "Allow", "好", "OK"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["-cleanStore"]
        app.launch()
        sleep(4)
        snapshot("11-横屏-首页")

        app.terminate()
        app.launchArguments = ["-cleanStore", "-openPrompter"]
        app.launch()
        sleep(4)
        snapshot("12-横屏-提词页")

        app.terminate()
        app.launchArguments = ["-cleanStore", "-tabScripts"]
        app.launch()
        sleep(3)
        snapshot("13-横屏-台本")

        app.terminate()
        app.launchArguments = ["-cleanStore", "-tabTemplates"]
        app.launch()
        sleep(3)
        snapshot("14-横屏-模板")

        app.terminate()
        app.launchArguments = ["-cleanStore", "-tabSettings"]
        app.launch()
        sleep(3)
        snapshot("15-横屏-设置")

        app.terminate()
        app.launchArguments = ["-cleanStore", "-openCapture"]
        app.launch()
        sleep(3)
        app.tap()
        sleep(3)
        app.tap()
        sleep(3)
        snapshot("16-横屏-拍摄")

        XCUIDevice.shared.orientation = .portrait
    }
}
