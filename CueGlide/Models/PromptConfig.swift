import Foundation
import UIKit

// MARK: - 镜像

enum MirrorMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case horizontal
    case vertical
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "关闭"
        case .horizontal: "水平翻转"
        case .vertical: "垂直翻转"
        case .both: "双向翻转"
        }
    }

    var flipsHorizontally: Bool { self == .horizontal || self == .both }
    var flipsVertically: Bool { self == .vertical || self == .both }
}

// MARK: - 阅读线位置

enum ReadingLinePosition: String, Codable, CaseIterable, Sendable, Identifiable {
    case nearCamera
    case center
    case lower

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nearCamera: "贴近镜头"
        case .center: "居中"
        case .lower: "偏下"
        }
    }

    /// 阅读线距离屏幕顶部的比例，用来算 contentOffset 的锚点。
    var viewportRatio: Double {
        switch self {
        case .nearCamera: 0.20
        case .center: 0.42
        case .lower: 0.62
        }
    }
}

// MARK: - 字重

enum FontWeightOption: String, Codable, CaseIterable, Sendable, Identifiable {
    case regular
    case medium
    case semibold
    case bold

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .regular: "常规"
        case .medium: "中等"
        case .semibold: "半粗"
        case .bold: "加粗"
        }
    }

    var uiWeight: UIFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

// MARK: - 显示配置

struct DisplayConfig: Codable, Equatable, Sendable {
    var fontSize: Double = 34
    var fontWeight: FontWeightOption = .semibold
    var lineSpacing: Double = 20
    var horizontalInset: Double = 28
    var mirror: MirrorMode = .none
    var palette: PromptPalette = .lightOnDark
    var dimReadOpacity: Double = 0.32
    var readingLine: ReadingLinePosition = .nearCamera
    var showsReadingGuide: Bool = false

    static let `default` = DisplayConfig()

    mutating func clamp() {
        fontSize = min(max(fontSize, 20), 96)
        lineSpacing = min(max(lineSpacing, 0), 48)
        horizontalInset = min(max(horizontalInset, 8), 96)
        dimReadOpacity = min(max(dimReadOpacity, 0), 0.9)
    }
}

// MARK: - 滚动模式

enum ScrollMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case constant
    case wpm
    case timed
    case voice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .constant: "恒速"
        case .wpm: "语速"
        case .timed: "定时"
        case .voice: "跟读"
        }
    }

    var detail: String {
        switch self {
        case .constant: "按固定速度滚动"
        case .wpm: "按每分钟字数滚动"
        case .timed: "设定总时长，自动配速"
        case .voice: "跟着你念到哪里滚到哪里"
        }
    }

    var symbol: String {
        switch self {
        case .constant: "arrow.down.to.line"
        case .wpm: "metronome"
        case .timed: "timer"
        case .voice: "waveform"
        }
    }
}

// MARK: - 滚动配置

struct ScrollConfig: Codable, Equatable, Sendable {
    var mode: ScrollMode = .constant
    /// 恒速模式：每秒滚动多少点
    var pointsPerSecond: Double = 56
    /// 语速模式：每分钟多少字
    var wordsPerMinute: Double = 240
    /// 定时模式：目标总时长（秒）
    var targetDuration: Double = 180
    /// 开始前的倒计时
    var countdown: Int = 3

    static let `default` = ScrollConfig()

    mutating func clamp() {
        pointsPerSecond = min(max(pointsPerSecond, 8), 400)
        wordsPerMinute = min(max(wordsPerMinute, 60), 600)
        targetDuration = min(max(targetDuration, 10), 7200)
        countdown = min(max(countdown, 0), 10)
    }
}
