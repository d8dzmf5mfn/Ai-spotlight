import AppKit
import Carbon.HIToolbox

/// Global hotkey using Carbon's RegisterEventHotKey. This is the same API used
/// by Spotlight, Alfred, Raycast, and other launchers. Requires no Accessibility
/// or Input Monitoring permission — it registers at the WindowServer level.
/// Tradeoff: the hotkey must not already be in use by macOS (e.g. ⌘+Space is
/// owned by Spotlight, so a different combination must be chosen).
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onToggle: () -> Void
    private let keyCode: UInt32
    private let modifiers: UInt32
    weak var panel: NSWindow?

    /// `modifiers` is a Carbon modifiers bitmask: cmdKey=256, option=2048, etc.
    init(keyCode: UInt32 = UInt32(kVK_Space),
         carbonModifiers: UInt32 = UInt32(cmdKey | optionKey),
         onToggle: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = carbonModifiers
        self.onToggle = onToggle
    }

    func start() {
        HotkeyManager.log("start: RegisterEventHotKey keyCode=\(keyCode) mods=\(modifiers)")
        // Carbon hotkey signature: 4-byte code identifying our app's hotkey.
        // 'ASP ' = 'A','I','S','P' as OSType (big-endian).
        let signature: OSType = 0x41495053  // 'AIPS'
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)

        // Install event handler that routes hotkey presses back to us.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData = userData else { return noErr }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var receivedID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                if err == noErr && receivedID.signature == 0x41495053 && receivedID.id == 1 {
                    DispatchQueue.main.async { mgr.onToggle() }
                }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &eventHandler
        )

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            HotkeyManager.log("start: RegisterEventHotKey OK (ref=\(hotKeyRef.map { String(describing: $0) } ?? "nil"))")
        } else {
            HotkeyManager.log("start: RegisterEventHotKey FAILED status=\(status) — likely already in use by system")
        }
    }

    func stop() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let h = eventHandler { RemoveEventHandler(h) }
        hotKeyRef = nil
        eventHandler = nil
    }

    deinit { stop() }

    fileprivate static func log(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        let path = "/tmp/aispotlight-hotkey.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
        }
    }
}
