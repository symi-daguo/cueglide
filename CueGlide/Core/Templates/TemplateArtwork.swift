import SwiftUI
import UIKit

/// 模板配图的存取。
///
/// 两种来源：内置图库（打包在 Assets 里，标识 `asset:<名称>`）与用户从相册选的图
/// （压缩后存进沙盒 `Documents/TemplateArtwork/`，标识 `file:<文件名>`）。
enum TemplateArtwork {

    /// 内置图库。编辑模板时以网格列出供选择。
    static let builtIn: [String] = [
        "TemplateHook",
        "TemplateProduct",
        "TemplateKnowledge",
        "TemplateStore",
        "TemplateLive",
        "TemplateEmotion",
        "ArtworkFlow",
        "ArtworkGrid",
        "ArtworkWave",
        "ArtworkPaper",
    ]

    /// 按标识取图，取不到时退回第一张内置图，避免界面出现空白。
    static func image(for identifier: String) -> Image {
        if identifier.hasPrefix("asset:") {
            let name = String(identifier.dropFirst("asset:".count))
            return Image(name)
        }
        if identifier.hasPrefix("file:"),
           let loaded = UIImage(contentsOfFile: path(for: String(identifier.dropFirst("file:".count)))) {
            return Image(uiImage: loaded)
        }
        return Image(builtIn[0])
    }

    /// 把相册选的图压到卡片尺寸后存盘，返回可直接写进模型的标识。
    static func save(_ image: UIImage) -> String? {
        // 卡片图区最大约 260×108pt，2x 下 520×216；留到 900 宽足够，再大没意义
        let target = 900.0
        let scale = min(target / image.size.width, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return nil }

        let name = UUID().uuidString + ".jpg"
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return "file:" + name
        } catch {
            return nil
        }
    }

    /// 删除自定义图。内置图不做任何事。
    static func delete(_ identifier: String) {
        guard identifier.hasPrefix("file:") else { return }
        let name = String(identifier.dropFirst("file:".count))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TemplateArtwork", isDirectory: true)
    }

    private static func path(for name: String) -> String {
        directory.appendingPathComponent(name).path
    }
}
