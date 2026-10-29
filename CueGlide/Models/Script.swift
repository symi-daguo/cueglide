import Foundation
import SwiftData

@Model
final class Script {
    var id: UUID = UUID()
    var title: String = ""
    var body: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var groupName: String?
    /// 上次读到的词序号，用于续读。
    var lastReadTokenIndex: Int = 0
    /// 非空白字符数，列表展示用。
    var characterCount: Int = 0
    /// 朗读单位数（中文按字、西文按词），估算时长用。
    var speechUnitCount: Int = 0

    init(
        title: String = "",
        body: String = "",
        groupName: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.body = body
        self.groupName = groupName
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
        let stats = ScriptTokenizer.statistics(of: body)
        self.characterCount = stats.characters
        self.speechUnitCount = stats.speechUnits
    }

    /// 正文变更后刷新统计与时间戳。
    func refreshDerivedFields() {
        updatedAt = Date()
        let stats = ScriptTokenizer.statistics(of: body)
        characterCount = stats.characters
        speechUnitCount = stats.speechUnits
    }

    /// 按每分钟语速估算朗读时长。
    func estimatedSeconds(wordsPerMinute: Double) -> Int {
        guard wordsPerMinute > 0 else { return 0 }
        return Int((Double(speechUnitCount) / wordsPerMinute * 60).rounded())
    }

    /// 列表卡片上的一句话摘要。
    var preview: String {
        body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Script: Identifiable {}
