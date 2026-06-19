import Foundation
import CoreServices

/// Wraps the macOS FSEvents C API to provide real-time file system
/// change notifications.
final class FSEventsWatcher {
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private let callbackQueue = DispatchQueue(label: "com.aispotlight.fsevents", qos: .utility)

    init(
        paths: [String],
        latency: CFTimeInterval = 1.0,
        queue: DispatchQueue = .main,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.queue = queue
        self.onChange = onChange
        self.stream = Self.createStream(paths: paths, latency: latency, observer: self)
    }

    deinit { stop() }

    func start() {
        guard let stream else { return }
        callbackQueue.async { [weak self] in
            guard self != nil else { return }

            FSEventStreamStart(stream)
            CFRunLoopRun()
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamSetDispatchQueue(stream, nil)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    func updatePaths(_ paths: [String]) {
        let wasRunning = stream != nil
        if wasRunning { stop() }
        stream = Self.createStream(paths: paths, latency: 1.0, observer: self)
        if wasRunning { start() }
    }

    // MARK: - Private

    private static func createStream(
        paths: [String],
        latency: CFTimeInterval,
        observer: FSEventsWatcher
    ) -> FSEventStreamRef? {
        let ptr = Unmanaged.passUnretained(observer).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: ptr,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // FSEventStreamCreate takes unlabeled C arguments.
        // Signature: (CFAllocator?, FSEventStreamCallback,
        //   UnsafeMutablePointer<FSEventStreamContext>?,
        //   CFArray, FSEventStreamEventId, CFTimeInterval,
        //   FSEventStreamCreateFlags) -> FSEventStreamRef?
        let callback: FSEventStreamCallback = { _, info, numEvents, rawPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.queue.async {
                watcher.onChange()
            }
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            Log.write("[FSEventsWatcher] failed to create stream")
            return nil
        }
        return stream
    }
}
