import XCTest
@testable import Captr

final class AndroidInputEscapingTests: XCTestCase {

    // MARK: - Spaces become %s (the adb input convention)

    func testSpaces_becomePercentS() {
        XCTAssertEqual(AndroidInputHandler.escapedInputText("hello world"), "hello%sworld")
    }

    // MARK: - Plain text is untouched

    func testPlainText_isUnchanged() {
        XCTAssertEqual(AndroidInputHandler.escapedInputText("Hello123"), "Hello123")
    }

    // MARK: - Shell metacharacters are backslash-escaped

    func testShellMetacharacters_areEscaped() {
        XCTAssertEqual(AndroidInputHandler.escapedInputText("a&b"), "a\\&b")
        XCTAssertEqual(AndroidInputHandler.escapedInputText("$HOME"), "\\$HOME")
        XCTAssertEqual(AndroidInputHandler.escapedInputText("a|b;c"), "a\\|b\\;c")
        XCTAssertEqual(AndroidInputHandler.escapedInputText("a\"b"), "a\\\"b")
    }

    // MARK: - Mixed input

    func testMixedInput_escapesMetacharsAndSpaces() {
        XCTAssertEqual(
            AndroidInputHandler.escapedInputText("rm -rf $HOME & echo hi"),
            "rm%s-rf%s\\$HOME%s\\&%secho%shi"
        )
    }

    // MARK: - Empty string

    func testEmptyString_returnsEmpty() {
        XCTAssertEqual(AndroidInputHandler.escapedInputText(""), "")
    }
}
