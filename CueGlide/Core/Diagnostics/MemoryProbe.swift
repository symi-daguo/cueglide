#if DEBUG
import Foundation
import os

/// 调试期内存采样。
///
/// 真机上没有 `ps`，`devicectl` 的进程列表也只有 PID 和路径，读不到内存。
/// 所以在进程内部读 `task_vm_info`：`phys_footprint` 就是 Xcode 内存计量用的值，
/// 和 Instruments 的 "Memory" 口径一致。
///
/// 只在 DEBUG 编译，发布产物里不存在这段代码。
enum MemoryProbe {

    private static let log = Logger(subsystem: "com.symi.cueglide", category: "Memory")
    private static let startedAt = Date()
    /// `startIfRequested` 只从主线程调一次，这里不额外加锁。
    nonisolated(unsafe) private static var task: Task<Void, Never>?

    /// 由启动参数 `-memoryProbe` 触发，避免普通调试被刷屏。
    static func startIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-memoryProbe") else { return }
        guard task == nil else { return }

        task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let line = snapshot()
                log.info("\(line, privacy: .public)")
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    static func snapshot() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "内存读取失败" }

        // phys_footprint 是 Xcode 内存计量与 Instruments 用的口径；
        // resident_size 含 clean 文件页，通常比 footprint 大。
        // virtual_size 在 64 位进程里是地址空间预留，动辄几百 GB，没有参考意义，不输出。
        let footprint = Double(info.phys_footprint) / 1_048_576
        let resident = Double(info.resident_size) / 1_048_576
        let elapsed = Int(Date().timeIntervalSince(startedAt))

        return String(
            format: "内存 %.1fMB ｜ 常驻 %.1fMB ｜ 已运行 %d 秒",
            footprint, resident, elapsed
        )
    }
}
#endif
