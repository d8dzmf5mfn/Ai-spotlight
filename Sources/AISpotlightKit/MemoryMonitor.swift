import Foundation
import MachO

/// Lightweight memory monitor that enforces a ~500MB RSS limit.
/// When memory pressure is detected or RSS exceeds the threshold,
/// it fires a callback so the app can trim caches.
public final class MemoryMonitor: @unchecked Sendable {
    /// Target RSS limit in bytes (~500 MB).
    public static let maxBytes: UInt64 = 500 * 1024 * 1024
    /// Warning threshold at 80% (400 MB).
    public static let warnBytes: UInt64 = 400 * 1024 * 1024

    /// Current RSS in bytes. Returns 0 on failure.
    public static func currentRSS() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    public typealias PressureHandler = @Sendable (PressureLevel) -> Void
    public enum PressureLevel: Sendable { case warning, critical }

    private let source: DispatchSourceMemoryPressure
    private let handler: PressureHandler

    /// Start monitoring. `handler` is called on a background queue
    /// when memory pressure changes.
    public init(handler: @escaping PressureHandler) {
        self.handler = handler
        self.source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        self.source.setEventHandler { [weak self] in
            let level: PressureLevel = self?.source.mask.contains(.critical) == true ? .critical : .warning
            self?.handler(level)
        }
        self.source.activate()

        // Also check RSS periodically
        Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                let rss = MemoryMonitor.currentRSS()
                if rss > MemoryMonitor.maxBytes {
                    self?.handler(.critical)
                } else if rss > MemoryMonitor.warnBytes {
                    self?.handler(.warning)
                }
            }
        }
    }

    deinit { source.cancel() }
}
