import XCTest
@testable import Captr

final class ProcessRunnerTests: XCTestCase {
    func testAsyncRunnerCapturesLargeOutputWithoutPipeDeadlock() async throws {
        let result = try await ProcessRunner.run(
            "/usr/bin/seq",
            arguments: ["1", "100000"],
            timeout: 5
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertGreaterThan(result.standardOutputData.count, 500_000)
        XCTAssertTrue(result.standardOutput.hasSuffix("100000\n"))
    }

    func testAsyncRunnerTimesOutHungProcess() async {
        let start = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run("/bin/sleep", arguments: ["5"], timeout: 0.05)
            XCTFail("Expected timeout")
        } catch ProcessRunnerError.timedOut {
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSynchronousRunnerCapturesLargeOutput() {
        let result = ProcessRunner.runSynchronously(
            "/usr/bin/seq",
            arguments: ["1", "100000"],
            timeout: 5
        )

        XCTAssertTrue(result?.succeeded == true)
        XCTAssertGreaterThan(result?.standardOutputData.count ?? 0, 500_000)
    }
}
