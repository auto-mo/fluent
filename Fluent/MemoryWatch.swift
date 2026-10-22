import AppKit
import Darwin

/// Fluent runs all day, so it watches its own memory (the long-running-process rule): past the
/// ceiling it restarts itself cleanly, turning any slow leak into a quiet restart rather than a
/// sluggish Mac.
@MainActor
enum MemoryWatch {
    static let ceilingBytes: UInt64 = 1_500_000_000
    private static var timer: Timer?
    private static var canRestart: () -> Bool = { false }

    /// Physical footprint, the number Activity Monitor shows as Memory.
    nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func start(canRestart check: @escaping () -> Bool) {
        canRestart = check
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                guard footprint() > ceilingBytes, canRestart() else { return }
                NSLog("Fluent: memory %llu bytes is over the ceiling; restarting", footprint())
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            }
        }
    }
}
