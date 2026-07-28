import XCTest
@testable import Captr

@MainActor
final class IOSMirrorTransportPolicyTests: XCTestCase {
    private static let useFastIOSMirroringKey = "useFastIOSMirroring"

    func testNativeLowLatencyMirrorIsDisabledWithoutExplicitFlag() {
        XCTAssertFalse(IOSDeviceMirror.nativeLowLatencyMirroringEnabled(environment: [:]))
    }

    func testNativeLowLatencyMirrorRequiresExactOptInFlag() {
        XCTAssertFalse(IOSDeviceMirror.nativeLowLatencyMirroringEnabled(environment: [
            "CAPTR_ENABLE_NATIVE_IOS_MIRROR": "true"
        ]))
        XCTAssertTrue(IOSDeviceMirror.nativeLowLatencyMirroringEnabled(environment: [
            "CAPTR_ENABLE_NATIVE_IOS_MIRROR": "1"
        ]))
    }

    func testAppStateDefaultsToStableModeWithoutStoredPreferenceOrEnvironmentFlag() {
        let defaults = Self.temporaryDefaults()
        let appState = AppState(userDefaults: defaults, environment: [:])

        XCTAssertFalse(appState.useFastIOSMirroring)
        XCTAssertFalse(appState.canUseFastIOSMirroring)
    }

    func testAppStateUsesEnvironmentFlagAsInitialFastModeOnlyWhenPreferenceIsUnset() {
        let defaults = Self.temporaryDefaults()
        let appState = AppState(
            userDefaults: defaults,
            environment: ["CAPTR_ENABLE_NATIVE_IOS_MIRROR": "1"]
        )

        XCTAssertTrue(appState.useFastIOSMirroring)
        XCTAssertTrue(appState.canUseFastIOSMirroring)
    }

    func testFastModeTogglePersistsAndOverridesEnvironmentDefault() {
        let defaults = Self.temporaryDefaults()
        let firstAppState = AppState(userDefaults: defaults, environment: ["CAPTR_ENABLE_NATIVE_IOS_MIRROR": "1"])

        firstAppState.setFastIOSMirroring(false)

        let secondAppState = AppState(userDefaults: defaults, environment: ["CAPTR_ENABLE_NATIVE_IOS_MIRROR": "1"])
        XCTAssertFalse(secondAppState.useFastIOSMirroring)
    }

    func testStoredFastModeIsIgnoredAndClearedWithoutExplicitFlag() {
        let defaults = Self.temporaryDefaults()
        defaults.set(true, forKey: Self.useFastIOSMirroringKey)

        let appState = AppState(userDefaults: defaults, environment: [:])

        XCTAssertFalse(appState.canUseFastIOSMirroring)
        XCTAssertFalse(appState.useFastIOSMirroring)
        XCTAssertFalse(defaults.bool(forKey: Self.useFastIOSMirroringKey))
    }

    func testFastModeToggleIsRejectedWithoutExplicitFlag() {
        let defaults = Self.temporaryDefaults()
        let appState = AppState(userDefaults: defaults, environment: [:])

        appState.setFastIOSMirroring(true)

        XCTAssertFalse(appState.useFastIOSMirroring)
        XCTAssertFalse(defaults.bool(forKey: Self.useFastIOSMirroringKey))
    }

    private static func temporaryDefaults() -> UserDefaults {
        let suiteName = "com.captr.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
