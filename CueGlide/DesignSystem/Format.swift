import Foundation

enum Format {

    /// 把秒数写成「1 分 46 秒」，列表与提词页共用。
    static func duration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "0 秒" }
        if seconds < 60 { return "\(seconds) 秒" }
        let m = seconds / 60
        let s = seconds % 60
        return s == 0 ? "\(m) 分" : "\(m) 分 \(s) 秒"
    }

    /// 紧凑形式，用于提词页角落。
    static func clock(_ seconds: Int) -> String {
        let m = max(seconds, 0) / 60
        let s = max(seconds, 0) % 60
        return String(format: "%d:%02d", m, s)
    }

    static func count(_ value: Int) -> String {
        value >= 10000
            ? String(format: "%.1f 万", Double(value) / 10000)
            : "\(value)"
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
