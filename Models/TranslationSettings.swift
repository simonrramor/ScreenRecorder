import Foundation
import SwiftUI

enum TranslationEngine: String, Codable, CaseIterable, Identifiable {
    case apple
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple (on-device)"
        case .claude: return "Claude (cloud)"
        }
    }

    var description: String {
        switch self {
        case .apple: return "Fast, offline, private. Literal translations."
        case .claude: return "Higher quality. Handles idioms and OCR noise."
        }
    }
}

enum ClaudeModel: String, Codable, CaseIterable, Identifiable {
    case haiku45
    case sonnet46
    case opus47

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .haiku45: return "Haiku 4.5"
        case .sonnet46: return "Sonnet 4.6"
        case .opus47: return "Opus 4.7"
        }
    }

    var apiIdentifier: String {
        switch self {
        case .haiku45: return "claude-haiku-4-5"
        case .sonnet46: return "claude-sonnet-4-6"
        case .opus47: return "claude-opus-4-7"
        }
    }

    var costHint: String {
        switch self {
        case .haiku45: return "Cheapest, fast"
        case .sonnet46: return "Better reasoning"
        case .opus47: return "Highest quality"
        }
    }
}

@MainActor
final class TranslationSettings: ObservableObject {
    @Published private var storedClaudeAPIKey: String?
    @Published private(set) var keychainError: String?

    @Published var engine: TranslationEngine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: Keys.engine) }
    }

    @Published var claudeModel: ClaudeModel {
        didSet { UserDefaults.standard.set(claudeModel.rawValue, forKey: Keys.claudeModel) }
    }

    /// API key is persisted in Keychain, not UserDefaults. `objectWillChange`
    /// is fired manually so SwiftUI pickers re-evaluate when the key status
    /// changes (empty ↔ present gates the Claude option).
    var claudeAPIKey: String? {
        storedClaudeAPIKey
    }

    var hasClaudeAPIKey: Bool {
        guard let key = claudeAPIKey else { return false }
        return !key.isEmpty
    }

    func setClaudeAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try TranslationKeychain.delete()
                storedClaudeAPIKey = nil
            } else {
                try TranslationKeychain.save(trimmed)
                storedClaudeAPIKey = trimmed
            }
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    init() {
        do {
            self.storedClaudeAPIKey = try TranslationKeychain.load()
            self.keychainError = nil
        } catch {
            self.storedClaudeAPIKey = nil
            self.keychainError = error.localizedDescription
        }

        let rawEngine = UserDefaults.standard.string(forKey: Keys.engine) ?? ""
        self.engine = TranslationEngine(rawValue: rawEngine) ?? .apple

        let rawModel = UserDefaults.standard.string(forKey: Keys.claudeModel) ?? ""
        self.claudeModel = ClaudeModel(rawValue: rawModel) ?? .haiku45
    }

    private enum Keys {
        static let engine = "com.captr.translation.engine"
        static let claudeModel = "com.captr.translation.claudeModel"
    }
}
