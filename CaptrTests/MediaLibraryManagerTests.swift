import XCTest
@testable import Captr

@MainActor
final class MediaLibraryManagerTests: XCTestCase {
    func testLoadLibrary_emptyDirectories_producesEmptyLists() async throws {
        let (root, directories) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = MediaLibraryManager(directories: directories)

        await manager.loadLibrary()

        XCTAssertTrue(manager.recordings.isEmpty)
        XCTAssertTrue(manager.screenshots.isEmpty)
        XCTAssertTrue(manager.allItems.isEmpty)
        XCTAssertNil(manager.errorMessage)
    }

    func testDeleteItem_failureKeepsItemAndReportsError() throws {
        let (root, directories) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directories.screenshots.appendingPathComponent("missing.png")
        let item = makeItem(url: file)
        let manager = MediaLibraryManager(directories: directories) { _ in
            throw CocoaError(.fileNoSuchFile)
        }
        manager.screenshots = [item]
        manager.allItems = [item]

        manager.deleteItem(item)

        XCTAssertEqual(manager.screenshots, [item])
        XCTAssertEqual(manager.allItems, [item])
        XCTAssertNotNil(manager.errorMessage)
    }

    func testDeleteItem_successRemovesFileAndLists() throws {
        let (root, directories) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directories.screenshots.appendingPathComponent("test.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data([1])))
        let item = makeItem(url: file)
        let manager = MediaLibraryManager(directories: directories) { url in
            try FileManager.default.removeItem(at: url)
        }
        manager.screenshots = [item]
        manager.allItems = [item]

        manager.deleteItem(item)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(manager.screenshots.isEmpty)
        XCTAssertTrue(manager.allItems.isEmpty)
        XCTAssertNil(manager.errorMessage)
    }

    func testIDsAreStableAcrossReloads() async throws {
        let (root, directories) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directories.screenshots.appendingPathComponent("Screenshot.png")
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try png.write(to: file)
        let manager = MediaLibraryManager(directories: directories)

        await manager.loadLibrary()
        let firstID = try XCTUnwrap(manager.screenshots.first?.id)
        await manager.loadLibrary()

        XCTAssertEqual(manager.screenshots.first?.id, firstID)
    }

    func testBaseDirectory_isInMovies() {
        let path = MediaLibraryManager.baseDirectory.path
        XCTAssertTrue(path.contains("Movies") || path.contains("Captr"))
    }

    func testScreenshotsDirectory_isUnderBase() {
        XCTAssertTrue(MediaLibraryManager.screenshotsDirectory.path.hasPrefix(MediaLibraryManager.baseDirectory.path))
    }

    private func makeDirectories() throws -> (URL, MediaLibraryDirectories) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptrMediaTests-\(UUID().uuidString)", isDirectory: true)
        let directories = MediaLibraryDirectories(
            recordings: root.appendingPathComponent("Recordings", isDirectory: true),
            screenshots: root.appendingPathComponent("Screenshots", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: directories.recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directories.screenshots, withIntermediateDirectories: true)
        return (root, directories)
    }

    private func makeItem(url: URL) -> MediaItem {
        MediaItem(
            id: url.standardizedFileURL.path,
            url: url,
            type: .screenshot,
            createdAt: Date(),
            fileSize: 1,
            duration: nil,
            thumbnail: nil
        )
    }
}
