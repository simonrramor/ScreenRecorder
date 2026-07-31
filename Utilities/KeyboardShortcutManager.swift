import Foundation
import AppKit
import Carbon

@MainActor
class KeyboardShortcutManager {
    private weak var appState: AppState?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var idToAction: [UInt32: ShortcutAction] = [:]

    // The Carbon hot-key callback is a C function pointer that can't capture
    // context, so it reaches the manager through this static. Only one
    // instance may exist at a time or hot keys would route to the wrong one.
    private static var shared: KeyboardShortcutManager?

    init(appState: AppState) {
        assert(KeyboardShortcutManager.shared == nil, "KeyboardShortcutManager must only be created once")
        self.appState = appState
        KeyboardShortcutManager.shared = self
    }

    func registerShortcuts() {
        unregisterShortcuts()
        guard let appState = appState else { return }

        installCarbonHandler()

        let shortcuts = appState.shortcutSettings
        var nextID: UInt32 = 1

        for action in ShortcutAction.allCases {
            let combo = shortcuts.binding(for: action)
            guard !combo.isEmpty else { continue }

            let carbonMods = carbonModifiers(from: NSEvent.ModifierFlags(rawValue: combo.modifiers))

            var hotKeyID = EventHotKeyID()
            hotKeyID.signature = OSType(0x53524543) // "SREC"
            hotKeyID.id = nextID

            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(combo.keyCode),
                carbonMods,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if status == noErr {
                hotKeyRefs.append(hotKeyRef)
                idToAction[nextID] = action
            }

            nextID += 1
        }
    }

    func unregisterShortcuts() {
        for ref in hotKeyRefs {
            if let ref = ref {
                UnregisterEventHotKey(ref)
            }
        }
        hotKeyRefs.removeAll()
        idToAction.removeAll()

        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    func shutdown() {
        unregisterShortcuts()
        if KeyboardShortcutManager.shared === self {
            KeyboardShortcutManager.shared = nil
        }
        appState = nil
    }

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr else { return OSStatus(eventNotHandledErr) }

            Task { @MainActor in
                KeyboardShortcutManager.shared?.handleHotKey(id: hotKeyID.id)
            }

            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }

    private func handleHotKey(id: UInt32) {
        guard let appState = appState else { return }
        guard !appState.isRecordingShortcut else { return }

        guard let action = idToAction[id] else { return }

        switch action {
        case .toggleRecording:
            Task { @MainActor in
                if appState.captureEngine.state.isActive {
                    await appState.stopRecording()
                } else {
                    await appState.startRecording(mode: .fullScreen)
                }
            }
        case .fullScreenScreenshot:
            Task { @MainActor in
                await appState.takeFullScreenScreenshot()
            }
        case .windowScreenshot:
            Task { @MainActor in
                await appState.takeScreenshot(mode: .window)
            }
        case .areaScreenshot:
            Task { @MainActor in
                await appState.takeScreenshot(mode: .area)
            }
        case .textCapture:
            Task { @MainActor in
                await appState.startTextCapture()
            }
        case .translateCapture:
            Task { @MainActor in
                await appState.startTranslateCapture()
            }
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

}
