import XCTest
@testable import Captr

final class CaptureFileURLTests: XCTestCase {
    func testUniqueURLsDoNotCollideWithinTheSameSecond() {
        let directory = URL(fileURLWithPath: "/tmp/captr-filenames", isDirectory: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = CaptureFileURL.unique(
            in: directory,
            prefix: "Screen Recording",
            pathExtension: "mp4",
            date: date,
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let second = CaptureFileURL.unique(
            in: directory,
            prefix: "Screen Recording",
            pathExtension: "mp4",
            date: date,
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.pathExtension, "mp4")
        XCTAssertTrue(first.lastPathComponent.contains("11111111"))
        XCTAssertTrue(second.lastPathComponent.contains("22222222"))
    }

    func testFunctionKeyNamesAreCorrect() {
        XCTAssertEqual(KeyCombo(keyCode: 122, modifiers: 0).displayString, "F1")
        XCTAssertEqual(KeyCombo(keyCode: 120, modifiers: 0).displayString, "F2")
    }
}
