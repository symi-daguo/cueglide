import Foundation
import GameController
import Observation

/// 外接遥控。
///
/// 蓝牙演示器、脚踏开关、翻页笔在系统看来都是键盘设备，所以用 GCKeyboard 一套就能全部覆盖，
/// 不需要为每种硬件单独适配。
@MainActor
@Observable
final class RemoteController {

    enum Command: String, Sendable {
        case togglePlayback
        case speedUp
        case speedDown
        case jumpForward
        case jumpBackward
        case restart
        case exit

        var displayName: String {
            switch self {
            case .togglePlayback: "播放 / 暂停"
            case .speedUp: "加速"
            case .speedDown: "减速"
            case .jumpForward: "往前跳"
            case .jumpBackward: "往回跳"
            case .restart: "回到开头"
            case .exit: "退出提词"
            }
        }
    }

    /// 最近一次收到的指令，用于界面上给出即时反馈。
    private(set) var lastCommand: Command?
    private(set) var isConnected = false

    @ObservationIgnored var onCommand: ((Command) -> Void)?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start() {
        refreshConnectionState()

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: .GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.attachHandler()
                    self?.isConnected = true
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: .GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isConnected = false
                }
            }
        )

        attachHandler()
    }

    func stop() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        isConnected = false
        lastCommand = nil
    }

    private func refreshConnectionState() {
        isConnected = GCKeyboard.coalesced != nil
    }

    private func attachHandler() {
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return }
        keyboard.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard pressed else { return }
            guard let command = Self.command(for: keyCode) else { return }
            // GameController 的回调不保证在主线程
            Task { @MainActor in
                self?.dispatch(command)
            }
        }
    }

    private func dispatch(_ command: Command) {
        lastCommand = command
        onCommand?(command)
    }

    private static func command(for keyCode: GCKeyCode) -> Command? {
        switch keyCode {
        case .spacebar, .returnOrEnter:
            .togglePlayback
        case .upArrow:
            .speedUp
        case .downArrow:
            .speedDown
        case .rightArrow, .pageDown:
            .jumpForward
        case .leftArrow, .pageUp:
            .jumpBackward
        case .keyR:
            .restart
        case .escape:
            .exit
        default:
            nil
        }
    }

    /// 给设置页展示的按键说明。
    static let keyMap: [(String, String)] = [
        ("空格 / 回车", "播放暂停"),
        ("↑ / ↓", "加速减速"),
        ("← / →", "回退前进"),
        ("R", "回到开头"),
        ("Esc", "退出提词"),
        ("演示器上下键", "等效方向键"),
        ("脚踏左/右键", "等效方向键")
    ]
}
