import SwiftUI
import UIKit

/// 全局视觉 token。外围界面走 iOS 27 Liquid Glass，提词页走独立的深色高对比主题。
enum Theme {

    // MARK: - 品牌色

    static let brand = Color(light: 0x4B6EF5, dark: 0x6B88FF)
    static let brandSoft = Color(light: 0xEEE9FF, dark: 0x1E2140)
    static let accentGreen = Color(light: 0xE8F7EE, dark: 0x12291C)
    static let accentOrange = Color(light: 0xFFF0E3, dark: 0x2A1E12)
    static let accentBlue = Color(light: 0xE6F0FF, dark: 0x14203A)

    // MARK: - 文字

    static let textPrimary = Color(light: 0x1A1D26, dark: 0xF2F3F7)
    static let textSecondary = Color(light: 0x6B7280, dark: 0x9BA1AE)
    static let textTertiary = Color(light: 0x9CA3AF, dark: 0x6C7280)
    static let danger = Color(light: 0xE5484D, dark: 0xFF6B6F)

    // MARK: - 表面

    static let canvas = Color(light: 0xF5F6FA, dark: 0x0B0C0F)
    static let surface = Color(light: 0xFFFFFF, dark: 0x16181D)
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x1D2027)
    static let hairline = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.08)

    // MARK: - 尺寸

    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 12

    // MARK: - 字体

    static let titleFont = Font.system(size: 22, weight: .semibold)
    static let cardTitleFont = Font.system(size: 17, weight: .semibold)
    static let bodyFont = Font.system(size: 15, weight: .regular)
    static let captionFont = Font.system(size: 13, weight: .regular)
}

/// 提词页专用配色。与外围界面解耦，因为提词场景要求最高对比度且不受系统深浅色影响。
enum PromptPalette: String, CaseIterable, Codable, Sendable {
    case darkOnLight
    case lightOnDark
    case blackOnWhite
    case yellowOnBlack
    case greenOnBlack

    var displayName: String {
        switch self {
        case .darkOnLight: "深字浅底"
        case .lightOnDark: "浅字深底"
        case .blackOnWhite: "纯白高对比"
        case .yellowOnBlack: "黄字黑底"
        case .greenOnBlack: "绿字黑底"
        }
    }

    var background: UIColor {
        switch self {
        case .darkOnLight, .blackOnWhite: .white
        case .lightOnDark: UIColor(white: 0.07, alpha: 1)
        case .yellowOnBlack, .greenOnBlack: .black
        }
    }

    var foreground: UIColor {
        switch self {
        case .darkOnLight: UIColor(white: 0.10, alpha: 1)
        case .lightOnDark: UIColor(white: 0.96, alpha: 1)
        case .blackOnWhite: .black
        case .yellowOnBlack: UIColor(red: 1.0, green: 0.84, blue: 0.20, alpha: 1)
        case .greenOnBlack: UIColor(red: 0.45, green: 0.95, blue: 0.55, alpha: 1)
        }
    }

    var highlight: UIColor {
        switch self {
        case .darkOnLight, .blackOnWhite: UIColor(red: 0.294, green: 0.431, blue: 0.961, alpha: 1)
        case .lightOnDark: UIColor(red: 0.49, green: 0.60, blue: 1.0, alpha: 1)
        case .yellowOnBlack: UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)
        case .greenOnBlack: UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)
        }
    }

    var readsDarkText: Bool {
        switch self {
        case .darkOnLight, .blackOnWhite: true
        default: false
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
