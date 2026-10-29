import Foundation

/// 调试与性能验证用的长文本，不参与正式界面。
enum SampleText {
    static let long: String = String(repeating: """
    这是一段用来验证长文本滚动性能的文字。提词器的核心不是把字放大，而是让视线始终停在同一个位置，文字从下往上匀速经过。\n
    """, count: 40)
}
