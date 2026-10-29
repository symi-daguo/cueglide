import Foundation
import Observation

/// 全局默认参数。持久化在 UserDefaults，跟着 App 走，不进 SwiftData。
@MainActor
@Observable
final class AppSettings {

    var display: DisplayConfig {
        didSet { persist() }
    }

    var scroll: ScrollConfig {
        didSet { persist() }
    }

    /// 用于台本列表估算录制时长，也作为语速模式的默认值。
    var wordsPerMinuteBaseline: Double {
        didSet {
            scroll.wordsPerMinute = wordsPerMinuteBaseline
            persist()
        }
    }

    var keepScreenAwake: Bool {
        didSet { persist() }
    }

    /// 语音跟读的识别语言。空字符串表示跟随系统语言。
    var speechLocaleIdentifier: String {
        didSet { persist() }
    }

    var hasInsertedSampleScript: Bool {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    private enum Key {
        static let display = "cueglide.display"
        static let scroll = "cueglide.scroll"
        static let wpm = "cueglide.wpm"
        static let awake = "cueglide.keepAwake"
        static let speechLocale = "cueglide.speechLocale"
        static let sample = "cueglide.sampleInserted"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Key.display),
           let decoded = try? JSONDecoder().decode(DisplayConfig.self, from: data) {
            display = decoded
        } else {
            display = .default
        }

        if let data = defaults.data(forKey: Key.scroll),
           let decoded = try? JSONDecoder().decode(ScrollConfig.self, from: data) {
            scroll = decoded
        } else {
            scroll = .default
        }

        let storedWPM = defaults.double(forKey: Key.wpm)
        wordsPerMinuteBaseline = storedWPM > 0 ? storedWPM : 240

        keepScreenAwake = defaults.object(forKey: Key.awake) as? Bool ?? true
        speechLocaleIdentifier = defaults.string(forKey: Key.speechLocale) ?? ""
        hasInsertedSampleScript = defaults.bool(forKey: Key.sample)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(display) {
            defaults.set(data, forKey: Key.display)
        }
        if let data = try? JSONEncoder().encode(scroll) {
            defaults.set(data, forKey: Key.scroll)
        }
        defaults.set(wordsPerMinuteBaseline, forKey: Key.wpm)
        defaults.set(keepScreenAwake, forKey: Key.awake)
        defaults.set(speechLocaleIdentifier, forKey: Key.speechLocale)
        defaults.set(hasInsertedSampleScript, forKey: Key.sample)
    }
}
