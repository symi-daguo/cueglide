import Foundation
import SwiftData

/// 用户自建模板。
///
/// 内置的六个模板是静态数据（`TemplateCatalog.all`），不走数据库；
/// 用户新建或改造出来的模板存这里，两者在列表里合并展示。
@Model
final class CustomTemplate {
    var title: String = ""
    var scene: String = "自定义"
    var summary: String = ""
    var body: String = ""

    /// 配图标识。`asset:<名称>` 表示内置图库里的图，`file:<文件名>` 表示沙盒里的自定义图。
    var artwork: String = "asset:TemplateHook"

    var createdAt: Date = Date.now

    init(
        title: String,
        scene: String = "自定义",
        summary: String = "",
        body: String = "",
        artwork: String = "asset:TemplateHook",
        createdAt: Date = .now
    ) {
        self.title = title
        self.scene = scene
        self.summary = summary
        self.body = body
        self.artwork = artwork
        self.createdAt = createdAt
    }
}
