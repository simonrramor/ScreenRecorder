import SwiftUI
import Sparkle

@main
struct CaptrApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    appDelegate.setupKeyboardShortcuts(appState: appState)
                    Task {
                        await appState.initialize()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 700, height: 52)

        MenuBarExtra("Captr", image: "MenuBarIcon") {
            MenuBarView(updater: updaterController.updater)
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var keyboardShortcutManager: KeyboardShortcutManager?
    private var hasSetupShortcuts = false
    private weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Captr lives in the menu bar. Accessory apps can still present and
        // focus their windows without occupying the Dock or Command-Tab.
        NSApp.setActivationPolicy(.accessory)

        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                window.styleMask = [.borderless, .fullSizeContentView]
                window.isMovableByWindowBackground = true
                window.backgroundColor = .clear
                window.hasShadow = true
                window.invalidateShadow()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @MainActor
    func setupKeyboardShortcuts(appState: AppState) {
        guard !hasSetupShortcuts else { return }
        hasSetupShortcuts = true
        self.appState = appState
        let manager = KeyboardShortcutManager(appState: appState)
        keyboardShortcutManager = manager
        appState.keyboardShortcutManager = manager
        keyboardShortcutManager?.registerShortcuts()
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboardShortcutManager?.unregisterShortcuts()
        appState?.shutdown()
    }
}
