import XCTest
@testable import Captr

final class ToolLocatorTests: XCTestCase {

    // MARK: - find() returns nil for tools that exist in no probed location

    func testFind_unknownTool_returnsNil() {
        let result = ToolLocator.find("definitely-not-a-real-tool-\(UUID().uuidString)")
        XCTAssertNil(result, "A tool that exists nowhere should resolve to nil")
    }

    // MARK: - find() resolves a real path passed via extraPaths

    func testFind_extraPathPointingAtRealFile_isReturned() throws {
        // Create a real file and feed its path as an extra candidate for a
        // tool name that won't exist under any Homebrew prefix.
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("captr-tool-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: tempFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempFile.path)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = ToolLocator.find("captr-bogus-tool", extraPaths: [tempFile.path])
        XCTAssertEqual(result, tempFile.path,
                       "find() should return the first existing candidate path")
    }

    func testFind_nonExecutableFile_returnsNil() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("captr-tool-\(UUID().uuidString)")
        try Data("not executable".utf8).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        XCTAssertNil(ToolLocator.find("captr-bogus-tool", extraPaths: [tempFile.path]))
    }

    // MARK: - find() ignores extra paths that don't exist

    func testFind_nonexistentExtraPath_returnsNil() {
        let result = ToolLocator.find(
            "captr-bogus-tool",
            extraPaths: ["/tmp/captr-does-not-exist-\(UUID().uuidString)"]
        )
        XCTAssertNil(result)
    }
}
