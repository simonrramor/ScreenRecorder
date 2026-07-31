import Foundation
import AppKit
import Carbon

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt

    var isEmpty: Bool {
        keyCode == 0 && modifiers == 0
    }

    var displayString: String {
        if isEmpty { return "Not Set" }

        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)

        if flags.contains(.control) { parts.append("^") }
        if flags.contains(.option) { parts.append("\u{2325}") }
        if flags.contains(.shift) { parts.append("\u{21E7}") }
        if flags.contains(.command) { parts.append("\u{2318}") }

        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    private func keyName(for keyCode: UInt16) -> String {
        let keyNames: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            48: "Tab", 49: "Space", 50: "`",
            51: "Delete", 53: "Esc",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 107: "F14",
            109: "F10", 111: "F12", 113: "F15",
            118: "F4", 120: "F2",
            122: "F1", 123: "\u{2190}", 124: "\u{2192}",
            125: "\u{2193}", 126: "\u{2191}",
            36: "\u{21A9}", // Return
        ]
        return keyNames[keyCode] ?? "Key\(keyCode)"
    }

    func matches(event: NSEvent) -> Bool {
        guard !isEmpty else { return false }
        let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        return event.keyCode == keyCode && eventMods == modifiers
    }

    static let empty = KeyCombo(keyCode: 0, modifiers: 0)
}

enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case fullScreenScreenshot = "Full Screen Screenshot"
    case windowScreenshot = "Window Screenshot"
    case areaScreenshot = "Area Screenshot"
    case toggleRecording = "Toggle Recording"
    case textCapture = "Text Capture"
    case translateCapture = "Translate to English"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .fullScreenScreenshot: return "camera.fill"
        case .windowScreenshot: return "macwindow"
        case .areaScreenshot: return "rectangle.dashed"
        case .toggleRecording: return "record.circle"
        case .textCapture: return "text.viewfinder"
        case .translateCapture: return "character.book.closed"
        }
    }
}

@MainActor
class ShortcutSettings: ObservableObject {
    @Published var bindings: [ShortcutAction: KeyCombo] {
        didSet { save() }
    }

    private let storageKey = "com.screenrecorder.shortcuts"

    init() {
        bindings = Self.defaults
        load()
    }

    static let defaults: [ShortcutAction: KeyCombo] = [
        .fullScreenScreenshot: KeyCombo(
            keyCode: 20,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        ),
        .windowScreenshot: KeyCombo(
            keyCode: 19,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        ),
        .areaScreenshot: KeyCombo(
            keyCode: 21,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        ),
        .toggleRecording: KeyCombo(
            keyCode: 23,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        ),
        .textCapture: KeyCombo(
            keyCode: 17,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        ),
        .translateCapture: KeyCombo(
            keyCode: 14,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        ),
    ]

    func binding(for action: ShortcutAction) -> KeyCombo {
        bindings[action] ?? .empty
    }

    func setBinding(_ combo: KeyCombo, for action: ShortcutAction) {
        bindings[action] = combo
    }

    func conflictingAction(for combo: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        guard !combo.isEmpty else { return nil }
        return bindings.first { $0.key != action && $0.value == combo }?.key
    }

    func resetToDefaults() {
        bindings = Self.defaults
    }

    private func save() {
        let simplified = bindings.map { (key: $0.key.rawValue, keyCode: $0.value.keyCode, mods: $0.value.modifiers) }
        if let data = try? JSONEncoder().encode(simplified.map { EncodableBinding(action: $0.key, keyCode: $0.keyCode, modifiers: $0.mods) }) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([EncodableBinding].self, from: data) else { return }

        for item in decoded {
            if let action = ShortcutAction(rawValue: item.action) {
                bindings[action] = KeyCombo(keyCode: item.keyCode, modifiers: item.modifiers)
            }
        }
    }
}

private struct EncodableBinding: Codable {
    let action: String
    let keyCode: UInt16
    let modifiers: UInt
}
