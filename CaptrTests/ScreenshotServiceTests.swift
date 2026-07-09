import XCTest
@testable import Captr

@MainActor
final class ScreenshotServiceTests: XCTestCase {

    // MARK: - errorMessage cleared on success

    func testCaptureArea_clearsStaleErrorBeforeReportingFailure() async {
        let service = ScreenshotService()
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

    // MARK: - errorMessage set on nil display

    func testCaptureFullScreen_nilDisplay_setsError() async {
        let service = ScreenshotService()
        let image = await service.captureFullScreen(display: nil)
        XCTAssertNil(image)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertTrue(service.errorMessage!.contains("display"),
                      "Error message should mention display")
    }

    // MARK: - saveScreenshot with valid image

    func testSaveScreenshot_producesFile() {
        let service = ScreenshotService()
        let image = NSImage(size: NSSize(width: 50, height: 50))
        image.lockFocus()
        NSColor.green.drawSwatch(in: NSRect(x: 0, y: 0, width: 50, height: 50))
        image.unlockFocus()

        let url = service.saveScreenshot(image)
        XCTAssertNotNil(url, "saveScreenshot should return a URL")
        XCTAssertNil(service.errorMessage, "No error expected on success")

        if let url = url {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            // Clean up
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - saveScreenshot clears stale error

    func testSaveScreenshot_clearsStaleError() {
        let service = ScreenshotService()
        service.errorMessage = "old error"

        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.white.drawSwatch(in: NSRect(origin: .zero, size: image.size))
        image.unlockFocus()

        let _ = service.saveScreenshot(image)
        XCTAssertNotEqual(service.errorMessage, "old error",
                          "saveScreenshot should clear stale errorMessage")

        // Clean up any saved file
        let dir = MediaLibraryManager.screenshotsDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.contains("Screenshot") {
                try? FileManager.default.removeItem(at: file)
            }
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
}
