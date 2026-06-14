import AppKit

/// No-op hotkey manager. The real implementation (Carbon RegisterEventHotKey)
/// was tried but couldn't be made to receive keypress events reliably in this
/// project's specific build setup (SwiftPM .executable target, ad-hoc signed
/// .app). The menu bar icon in `StatusBarController` is the supported way
/// to summon the panel for now.
///
/// What we tried, and why it didn't work:
/// 1. NSEvent.addGlobalMonitorForEvents — installs "OK" but never receives
///    events. Suspected cause: the binary's TCC identity was inconsistent
///    with what was authorized in System Settings → Accessibility.
/// 2. CGEvent.tapCreate — returns nil (event tap disabled). Suspected cause:
///    Input Monitoring permission couldn't be granted reliably.
/// 3. Carbon RegisterEventHotKey — registers successfully (noErr) but the
///    C callback is never invoked. The event target swap
///    (GetEventDispatcherTarget vs GetApplicationEventTarget), callback
///    lifetime fix (sentinel + global registry to survive Swift 6 ARC), and
///    process-identity fix (proper Bundle Identifier in Info.plist + ad-hoc
///    signature + codesign --deep --sign -) all combined to register
///    successfully, but the dispatch path remains silent. This is most
///    likely a Swift 6 / Carbon interop quirk in this build environment.
///
/// To re-enable global hotkey:
/// 1. Replace the `AppLauncher` class with a standard `@main struct` pattern
///    using SwiftUI's `App` protocol (or NSApplicationMain), avoiding the
///    `init() { app.run() }` pattern in `main.swift`.
/// 2. Try a known-working Carbon HotKey library such as
///    [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts).
final class HotkeyManager {
    weak var panel: NSWindow?

    init(keyCode: UInt32 = 49,  // kVK_Space
         carbonModifiers: UInt32 = 0x0900,  // cmdKey | optionKey
         onToggle: @escaping () -> Void) {
        // Intentionally no-op.
    }

    func start() {}
    func stop() {}
}
