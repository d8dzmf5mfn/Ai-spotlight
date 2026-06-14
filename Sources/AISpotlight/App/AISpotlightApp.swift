import SwiftUI
import AppKit
import AISpotlightKit

@main
struct AISpotlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: SpotlightPanel!
    var hotkey: HotkeyManager!
    var state: AppState!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // no dock icon

        let settings = SettingsStore()
        let keychain: KeychainStoring = KeychainStore()
        let ai = AIFactory.makeProvider(named: settings.activeProvider, keychain: keychain)
        let interpreter = QueryInterpreter(aiProvider: ai)
        let orchestrator = SearchOrchestrator(providers: [
            FileSystemProvider(),
            AppProvider(),
        ])
        state = AppState(interpreter: interpreter, orchestrator: orchestrator)

        let host = NSHostingController(rootView: SearchWindowView(state: state))
        panel = SpotlightPanel()
        panel.contentViewController = host

        hotkey = HotkeyManager(onToggle: { [weak self] in
            guard let self else { return }
            self.state.query = ""
            self.state.results = []
            self.panel.toggle()
            // Give the window a moment to become key, then focus the text field.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let tf = self.findTextField(in: self.panel.contentView) {
                    self.panel.makeFirstResponder(tf)
                }
            }
        })
        hotkey.panel = panel  // so the hotkey ignores events from our own field
        hotkey.start()
    }

    /// Recursively walk a view tree looking for the first NSTextField.
    private func findTextField(in view: NSView?) -> NSTextField? {
        guard let v = view else { return nil }
        if let tf = v as? NSTextField { return tf }
        for sub in v.subviews {
            if let tf = findTextField(in: sub) { return tf }
        }
        return nil
    }
}
