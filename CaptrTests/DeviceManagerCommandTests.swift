import XCTest
@testable import Captr

final class DeviceManagerCommandTests: XCTestCase {

    func testRunCommandReturnsOutputForFastCommand() {
        let output = DeviceManager.runCommand(
            "/bin/echo",
            arguments: ["IOS_READY"],
            timeout: 1
        )

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "IOS_READY")
    }

    func testRunCommandTimesOutHungCommand() {
        let start = Date()

        let output = DeviceManager.runCommand(
            "/bin/sleep",
            arguments: ["2"],
            timeout: 0.1
        )

        XCTAssertEqual(output, "")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}
