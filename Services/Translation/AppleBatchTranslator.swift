import Foundation

/// Apple's Translation framework has no batch endpoint, so this adapter feeds
/// strings through its single session in order.
@MainActor
final class AppleBatchTranslator: BatchTranslator {
    private let provider: AppleTranslationProvider

    init(provider: AppleTranslationProvider) {
        self.provider = provider
    }

    func translateBatch(_ strings: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        guard !strings.isEmpty else { return [] }

        // Apple's TranslationSession consumes the coordinator stream in
        // order, so task-group fan-out only created actor-transfer hazards;
        // it did not run translations in parallel.
        var results: [String] = []
        results.reserveCapacity(strings.count)
        for string in strings {
            try Task.checkCancellation()
            results.append(try await provider.translate(string, from: source, to: target))
        }
        return results
    }
}
