import SwiftUI
import SwiftData

@main
struct CueGlideApp: App {

    @State private var settings = AppSettings()
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Script.self, CustomTemplate.self)
        } catch {
            fatalError("本地数据库初始化失败：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .modelContainer(container)
        }
    }
}
