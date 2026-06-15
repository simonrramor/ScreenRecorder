import XCTest
@testable import Captr

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
}
