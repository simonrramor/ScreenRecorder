import XCTest
@preconcurrency import Translation
@testable import Captr

final class AppleTranslationProviderTests: XCTestCase {
    private struct DetailedError: LocalizedError {
        var errorDescription: String? { "Generic heading" }
        var failureReason: String? { "Specific reason" }
    }

    private struct DescriptionOnlyError: LocalizedError {
        var errorDescription: String? { "Useful description" }
    }

    func testFailureMessagePrefersSpecificFailureReason() {
        XCTAssertEqual(
            TranslationFailureMessage.message(for: DetailedError()),
            "Specific reason"
        )
    }

    func testFailureMessageFallsBackToLocalizedDescription() {
        XCTAssertEqual(
            TranslationFailureMessage.message(for: DescriptionOnlyError()),
            "Useful description"
        )
    }

    func testAppleFailureMessageUsesFrameworkFailureReason() throws {
        let reason = try XCTUnwrap(TranslationError.unsupportedLanguagePairing.failureReason)
        XCTAssertEqual(
            TranslationFailureMessage.message(for: TranslationError.unsupportedLanguagePairing),
            reason
        )
    }

    func testRetryPolicyRejectsCancellationAndPermanentLanguageErrors() {
        XCTAssertFalse(AppleTranslationRetryPolicy.shouldRetry(after: CancellationError()))
        XCTAssertFalse(AppleTranslationRetryPolicy.shouldRetry(after: TranslationError.unsupportedSourceLanguage))
        XCTAssertFalse(AppleTranslationRetryPolicy.shouldRetry(after: TranslationError.unsupportedTargetLanguage))
        XCTAssertFalse(AppleTranslationRetryPolicy.shouldRetry(after: TranslationError.unsupportedLanguagePairing))
        XCTAssertFalse(AppleTranslationRetryPolicy.shouldRetry(after: TranslationError.nothingToTranslate))

        if #available(macOS 26.0, *) {
            XCTAssertFalse(AppleTranslationRetryPolicy.shouldRetry(after: TranslationError.alreadyCancelled))
        }
    }

    func testRetryPolicyAllowsRecoverableFrameworkErrors() {
        XCTAssertTrue(AppleTranslationRetryPolicy.shouldRetry(after: TranslationError.internalError))
        XCTAssertTrue(AppleTranslationRetryPolicy.shouldRetry(after: TranslationError.unableToIdentifyLanguage))

        if #available(macOS 26.0, *) {
            XCTAssertTrue(AppleTranslationRetryPolicy.shouldRetry(after: TranslationError.notInstalled))
        }
    }

    @MainActor
    func testRetryPerformsOneResetThenSucceeds() async throws {
        var attempts = 0
        var resets = 0

        let result: String = try await AppleTranslationRetryPolicy.perform({
            attempts += 1
            if attempts == 1 {
                throw TranslationError.internalError
            }
            return "translated"
        }, beforeRetry: { _ in
            resets += 1
        })

        XCTAssertEqual(result, "translated")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(resets, 1)
    }

    @MainActor
    func testRetryDoesNotRepeatPermanentFailure() async {
        var attempts = 0
        var resets = 0

        do {
            let _: String = try await AppleTranslationRetryPolicy.perform({
                attempts += 1
                throw TranslationError.unsupportedLanguagePairing
            }, beforeRetry: { _ in
                resets += 1
            })
            XCTFail("Expected translation to fail")
        } catch {
            XCTAssertTrue(TranslationError.unsupportedLanguagePairing ~= error)
        }

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(resets, 0)
    }

    @MainActor
    func testRetryStopsAfterSecondRecoverableFailure() async {
        var attempts = 0
        var resets = 0

        do {
            let _: String = try await AppleTranslationRetryPolicy.perform({
                attempts += 1
                throw TranslationError.internalError
            }, beforeRetry: { _ in
                resets += 1
            })
            XCTFail("Expected translation to fail")
        } catch {
            XCTAssertTrue(TranslationError.internalError ~= error)
        }

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(resets, 1)
    }
}
