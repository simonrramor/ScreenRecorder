import XCTest
@testable import Captr

@MainActor
final class IOSMirrorTransportPolicyTests: XCTestCase {

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
    }

    func testAppStateUsesEnvironmentFlagAsInitialFastModeOnlyWhenPreferenceIsUnset() {
        let defaults = Self.temporaryDefaults()
        let appState = AppState(
            userDefaults: defaults,
            environment: ["CAPTR_ENABLE_NATIVE_IOS_MIRROR": "1"]
        )

        XCTAssertTrue(appState.useFastIOSMirroring)
    }

    func testFastModeTogglePersistsAndOverridesEnvironmentDefault() {
        let defaults = Self.temporaryDefaults()
        let firstAppState = AppState(userDefaults: defaults, environment: ["CAPTR_ENABLE_NATIVE_IOS_MIRROR": "1"])

        firstAppState.useFastIOSMirroring = false

        let secondAppState = AppState(userDefaults: defaults, environment: ["CAPTR_ENABLE_NATIVE_IOS_MIRROR": "1"])
        XCTAssertFalse(secondAppState.useFastIOSMirroring)
    }

    private static func temporaryDefaults() -> UserDefaults {
        let suiteName = "com.captr.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
