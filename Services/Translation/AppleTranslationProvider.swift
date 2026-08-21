import Foundation
import SwiftUI
@preconcurrency import Translation
import AppKit
import os

/// Drives Apple's on-device `Translation` framework from a long-lived hidden
/// NSPanel so that back-to-back translations of the same language pair reuse
/// the underlying `TranslationSession` (set up once via `.translationTask`).
/// When the pair changes we tear down the request stream, which lets SwiftUI
/// swap the session cleanly on the next config change.
@MainActor
final class AppleTranslationProvider: TranslationProvider {
    let displayName = "Apple"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.captr.app",
        category: "Translation"
    )

    private var panel: NSPanel?
    private let coordinator = TranslationCoordinator()

    func prewarm() {
        ensurePanel()
    }

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        ensurePanel()
        do {
            return try await AppleTranslationRetryPolicy.perform({
                try await coordinator.submit(text: text, source: source, target: target)
            }, beforeRetry: { error in
                Self.logger.notice(
                    "Resetting Apple translation session after failure from \(source.maximalIdentifier, privacy: .public) to \(target.maximalIdentifier, privacy: .public): \(TranslationFailureMessage.message(for: error), privacy: .public)"
                )
                coordinator.resetSession()
            })
        } catch {
            Self.logger.error(
                "Apple translation failed from \(source.maximalIdentifier, privacy: .public) to \(target.maximalIdentifier, privacy: .public): \(TranslationFailureMessage.message(for: error), privacy: .public)"
            )
            throw error
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let hostView = TranslationHostView(coordinator: coordinator)
        let hosting = NSHostingController(rootView: AnyView(hostView))
        hosting.view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        let p = NSPanel(
            contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.alphaValue = 0
        p.contentView = hosting.view
        p.orderFrontRegardless()
        panel = p
    }
}

// MARK: - Retry policy

enum AppleTranslationRetryPolicy {
    /// A stale framework session can fail even though its language pair and
    /// assets are valid. Rebuild that session and retry once, but don't repeat
    /// failures that cannot be repaired by a fresh session.
    static func shouldRetry(after error: Error) -> Bool {
        if error is CancellationError { return false }
        if TranslationError.unsupportedSourceLanguage ~= error { return false }
        if TranslationError.unsupportedTargetLanguage ~= error { return false }
        if TranslationError.unsupportedLanguagePairing ~= error { return false }
        if TranslationError.nothingToTranslate ~= error { return false }
        if #available(macOS 26.0, *), TranslationError.alreadyCancelled ~= error { return false }
        return true
    }

    @MainActor
    static func perform<Result>(
        _ operation: () async throws -> Result,
        beforeRetry: (Error) -> Void
    ) async throws -> Result {
        do {
            return try await operation()
        } catch {
            guard shouldRetry(after: error) else { throw error }
            beforeRetry(error)
            try Task.checkCancellation()
            return try await operation()
        }
    }
}

// MARK: - Coordinator

@MainActor
private class TranslationCoordinator: ObservableObject {
    struct Request {
        let id: UUID
        let generation: UUID
        let text: String
    }

    @Published var config: TranslationSession.Configuration?
    private(set) var stream: AsyncStream<Request>?
    private var streamContinuation: AsyncStream<Request>.Continuation?

    private var currentSourceID: String?
    private var currentTargetID: String?
    private var streamGeneration = UUID()
    private var shouldInvalidateConfiguration = false
    private var pending: [UUID: (generation: UUID, continuation: CheckedContinuation<String, Error>)] = [:]

    func submit(text: String, source: Locale.Language, target: Locale.Language) async throws -> String {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let sourceID = source.maximalIdentifier
                let targetID = target.maximalIdentifier
                if sourceID != currentSourceID || targetID != currentTargetID || streamContinuation == nil {
                    let previousGeneration = streamGeneration
                    streamContinuation?.finish()
                    cancelRequests(for: previousGeneration)

                    let (newStream, newContinuation) = AsyncStream<Request>.makeStream()
                    streamGeneration = UUID()
                    stream = newStream
                    streamContinuation = newContinuation
                    currentSourceID = sourceID
                    currentTargetID = targetID
                    if shouldInvalidateConfiguration,
                       config?.source?.maximalIdentifier == sourceID,
                       config?.target?.maximalIdentifier == targetID {
                        config?.invalidate()
                    } else {
                        config = .init(source: source, target: target)
                    }
                    shouldInvalidateConfiguration = false
                }

                let generation = streamGeneration
                pending[requestID] = (generation, continuation)
                streamContinuation?.yield(Request(id: requestID, generation: generation, text: text))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID: requestID)
            }
        }
    }

    /// Ends the stream owned by the failed TranslationSession. The next
    /// submission creates a new stream and invalidates the SwiftUI
    /// configuration, forcing `.translationTask` to provide a fresh session
    /// even when the language pair has not changed.
    func resetSession() {
        let previousGeneration = streamGeneration
        streamContinuation?.finish()
        stream = nil
        streamContinuation = nil
        cancelRequests(for: previousGeneration)
        shouldInvalidateConfiguration = true
    }

    func complete(_ request: Request, with result: Result<String, Error>) {
        guard let entry = pending.removeValue(forKey: request.id),
              entry.generation == request.generation else { return }
        entry.continuation.resume(with: result)
    }

    func cancelRequests(for generation: UUID) {
        let matches = pending.filter { $0.value.generation == generation }
        for (id, entry) in matches {
            pending.removeValue(forKey: id)
            entry.continuation.resume(throwing: CancellationError())
        }
    }

    private func cancel(requestID: UUID) {
        guard let entry = pending.removeValue(forKey: requestID) else { return }
        entry.continuation.resume(throwing: CancellationError())
    }
}

// MARK: - Hidden hosting view

private struct TranslationHostView: View {
    @ObservedObject var coordinator: TranslationCoordinator

    var body: some View {
        Color.clear
            .translationTask(coordinator.config) { session in
                guard let stream = coordinator.stream else { return }
                var generation: UUID?
                for await request in stream {
                    if Task.isCancelled { break }
                    generation = request.generation
                    do {
                        let response = try await session.translate(request.text)
                        coordinator.complete(request, with: .success(response.targetText))
                    } catch {
                        coordinator.complete(request, with: .failure(error))
                    }
                }
                if let generation {
                    coordinator.cancelRequests(for: generation)
                }
            }
    }
}
