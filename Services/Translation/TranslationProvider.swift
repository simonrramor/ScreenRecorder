import Foundation

/// An engine that can translate text from one language to another. Providers
/// encapsulate both fast on-device translation (Apple) and cloud LLM-based
/// translation (Claude). See `AppleTranslationProvider` and
/// `ClaudeTranslationProvider` for concrete implementations.
@MainActor
protocol TranslationProvider {
    /// Human-readable name surfaced in the popup (e.g. "Apple", "Claude Haiku 4.5").
    var displayName: String { get }

    /// Optional warm-up hook invoked while the user is still selecting the
    /// capture area, hiding any one-time setup cost behind their input.
    func prewarm()

    /// Translate `text` from `source` to `target`. Providers may treat `source`
    /// as a hint (Claude auto-detects regardless) or a hard requirement (Apple's
    /// Translation framework needs an explicit pair).
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
}

extension TranslationProvider {
    func prewarm() {}
}

/// Picks the useful detail out of errors whose localized description is only
/// a generic heading. Apple's Translation framework, for example, reports
/// "Unable to Translate" as the description and puts the actionable reason in
/// `failureReason`.
enum TranslationFailureMessage {
    static func message(for error: Error) -> String {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let localized = error as? LocalizedError
        let reason = (localized?.failureReason ?? (error as NSError).localizedFailureReason)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let reason,
           !reason.isEmpty,
           reason.localizedCaseInsensitiveCompare(description) != .orderedSame {
            return reason
        }
        return description
    }
}

/// Errors a provider can surface to the UI with friendlier messaging than raw
/// `localizedDescription` from system frameworks.
enum TranslationProviderError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case network(String)
    case serverError(Int, String?)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Anthropic API key in Settings → Translation."
        case .invalidAPIKey:
            return "The Anthropic API key was rejected. Check it in Settings → Translation."
        case .rateLimited:
            return "Anthropic rate limit hit. Wait a moment and try again."
        case .network(let detail):
            return "Network error: \(detail)"
        case .serverError(let code, let detail):
            if let detail { return "Translation service error (\(code)): \(detail)" }
            return "Translation service error (\(code))."
        case .emptyResponse:
            return "The translator returned an empty response."
        }
    }
}
