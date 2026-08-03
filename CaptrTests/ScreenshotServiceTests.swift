import XCTest
@testable import Captr

@MainActor
final class ScreenshotServiceTests: XCTestCase {

    // MARK: - errorMessage cleared on success

    func testCaptureArea_clearsStaleErrorBeforeReportingFailure() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let service = ScreenshotService(screenshotsDirectory: temporaryDirectory)
        service.errorMessage = "stale error from previous capture"

        // Even when capture fails early, it should clear stale errors before
        // reporting the new failure.
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        let _ = await service.captureArea(display: nil, area: rect)

        // Whether capture succeeds or not, errorMessage should not retain
        // the stale value from before this call.
        XCTAssertNotEqual(service.errorMessage, "stale error from previous capture",
                          "errorMessage should be cleared at the start of a capture")
    }

    // MARK: - Prepared area capture

    func testPreparedAreaCapture_usesReadyCaptureWithoutAnotherPreparation() async throws {
        let expectedImage = try makeTestCGImage()
        let requestedArea = CGRect(x: 20, y: 30, width: 120, height: 80)
        var capturedAreas: [CGRect] = []
        let preparedCapture = ScreenshotService.PreparedAreaCapture(
            displayIDs: [CGMainDisplayID()]
        ) { area in
            capturedAreas.append(area)
            return expectedImage
        }

        let result = try await ScreenshotService.captureAreaCGImage(
            preparedCapture: preparedCapture,
            area: requestedArea
        )

        XCTAssertEqual(result.width, expectedImage.width)
        XCTAssertEqual(result.height, expectedImage.height)
        XCTAssertEqual(capturedAreas, [requestedArea])
    }

    func testPreparedAreaCapture_rejectsEmptyAreaBeforeCaptureRequest() async throws {
        let expectedImage = try makeTestCGImage()
        var captureRequestCount = 0
        let preparedCapture = ScreenshotService.PreparedAreaCapture(
            displayIDs: [CGMainDisplayID()]
        ) { _ in
            captureRequestCount += 1
            return expectedImage
        }

        do {
            _ = try await ScreenshotService.captureAreaCGImage(
                preparedCapture: preparedCapture,
                area: .zero
            )
            XCTFail("An empty selection should fail before requesting a screenshot")
        } catch {
            XCTAssertEqual(captureRequestCount, 0)
        }
    }

    // MARK: - errorMessage set on nil display

    func testCaptureFullScreen_nilDisplay_setsError() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let service = ScreenshotService(screenshotsDirectory: temporaryDirectory)
        let image = await service.captureFullScreen(display: nil)
        XCTAssertNil(image)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertTrue(service.errorMessage!.contains("display"),
                      "Error message should mention display")
    }

    // MARK: - saveScreenshot with valid image

    func testSaveScreenshot_producesFile() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let service = ScreenshotService(screenshotsDirectory: temporaryDirectory)
        let image = NSImage(size: NSSize(width: 50, height: 50))
        image.lockFocus()
        NSColor.green.drawSwatch(in: NSRect(x: 0, y: 0, width: 50, height: 50))
        image.unlockFocus()

        let url = service.saveScreenshot(image)
        XCTAssertNotNil(url, "saveScreenshot should return a URL")
        XCTAssertNil(service.errorMessage, "No error expected on success")

        if let url {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(url.path.hasPrefix(temporaryDirectory.path))
        }
    }

    // MARK: - saveScreenshot clears stale error

    func testSaveScreenshot_clearsStaleError() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let service = ScreenshotService(screenshotsDirectory: temporaryDirectory)
        service.errorMessage = "old error"

        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.white.drawSwatch(in: NSRect(origin: .zero, size: image.size))
        image.unlockFocus()

        let savedURL = service.saveScreenshot(image)
        XCTAssertNotEqual(service.errorMessage, "old error",
                          "saveScreenshot should clear stale errorMessage")

        if let savedURL {
            XCTAssertTrue(savedURL.path.hasPrefix(temporaryDirectory.path))
        }
    }

    // MARK: - Dock exclusion cache validation
    //
    // Window IDs are recycled by WindowServer; a stale cached exclusion can
    // name another app's window and punch it out of screenshots. Any cached
    // ID no longer backed by a live Dock-bar window must invalidate the cache.

    func testCachedExclusions_allIDsStillDockBars_isValid() {
        XCTAssertTrue(ScreenshotService.cachedExclusionsStillValid(
            cachedIDs: [101, 102],
            liveDockBarIDs: [101, 102, 103]
        ))
    }

    func testCachedExclusions_recycledID_invalidatesCache() {
        XCTAssertFalse(ScreenshotService.cachedExclusionsStillValid(
            cachedIDs: [101, 555],
            liveDockBarIDs: [101, 102]
        ))
    }

    func testCachedExclusions_emptyCache_isInvalid() {
        XCTAssertFalse(ScreenshotService.cachedExclusionsStillValid(
            cachedIDs: [],
            liveDockBarIDs: [101]
        ))
    }

    func testCachedExclusions_noLiveDockWindows_invalidatesCache() {
        XCTAssertFalse(ScreenshotService.cachedExclusionsStillValid(
            cachedIDs: [101],
            liveDockBarIDs: []
        ))
    }

    // MARK: - Which Dock windows stay in captures
    //
    // The Dock app is excluded wholesale (that's what removes transient
    // overlays like the ⌘-tab app switcher); these rules pick the windows
    // that get re-included.

    private let dockLevel = 20

    func testWallpaperWindowsAlwaysStayInCaptures() {
        XCTAssertTrue(ScreenshotService.shouldExceptDockWindow(layer: -2147483624, dockAutoHides: true, dockLevel: dockLevel))
        XCTAssertTrue(ScreenshotService.shouldExceptDockWindow(layer: -2147483624, dockAutoHides: false, dockLevel: dockLevel))
    }

    func testPinnedDockBarStaysInCaptures() {
        XCTAssertTrue(ScreenshotService.shouldExceptDockWindow(layer: dockLevel, dockAutoHides: false, dockLevel: dockLevel))
    }

    func testAutoHiddenDockBarIsExcluded() {
        XCTAssertFalse(ScreenshotService.shouldExceptDockWindow(layer: dockLevel, dockAutoHides: true, dockLevel: dockLevel))
    }

    func testAppSwitcherStyleOverlaysAreAlwaysExcluded() {
        // Transient Dock overlays live at positive non-bar levels.
        XCTAssertFalse(ScreenshotService.shouldExceptDockWindow(layer: 101, dockAutoHides: true, dockLevel: dockLevel))
        XCTAssertFalse(ScreenshotService.shouldExceptDockWindow(layer: 101, dockAutoHides: false, dockLevel: dockLevel))
    }

    func testSameSnapshotFilterExcludesAppSwitcherWithDockApplication() {
        XCTAssertEqual(
            ScreenshotService.dockWindowFilterDisposition(
                layer: 101,
                dockAutoHides: false,
                dockLevel: dockLevel,
                dockApplicationAvailable: true
            ),
            .excludedWithApplication
        )
    }

    func testSameSnapshotFilterExcludesAppSwitcherWithoutDockApplicationMetadata() {
        XCTAssertEqual(
            ScreenshotService.dockWindowFilterDisposition(
                layer: 101,
                dockAutoHides: false,
                dockLevel: dockLevel,
                dockApplicationAvailable: false
            ),
            .excludeWindow
        )
    }

    func testSameSnapshotFilterKeepsPinnedDockAndWallpaper() {
        XCTAssertEqual(
            ScreenshotService.dockWindowFilterDisposition(
                layer: dockLevel,
                dockAutoHides: false,
                dockLevel: dockLevel,
                dockApplicationAvailable: true
            ),
            .exceptFromApplicationExclusion
        )
        XCTAssertEqual(
            ScreenshotService.dockWindowFilterDisposition(
                layer: -1,
                dockAutoHides: true,
                dockLevel: dockLevel,
                dockApplicationAvailable: true
            ),
            .exceptFromApplicationExclusion
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptrScreenshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeTestCGImage() throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }
}
