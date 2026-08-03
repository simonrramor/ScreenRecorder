import Foundation
import ScreenCaptureKit
import AppKit
import CoreGraphics
import os

@MainActor
class ScreenshotService: ObservableObject {
    @Published var lastScreenshot: NSImage?
    @Published var errorMessage: String?

    private let screenshotsDirectory: URL
    private static let areaCaptureSignposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.captr.app",
        category: "AreaCapture"
    )

    /// A display and Dock-safe content filter built from one
    /// `SCShareableContent` snapshot. AppState creates this before showing the
    /// area selector so mouse-up can go straight to `SCScreenshotManager`
    /// without enumerating the current window list again.
    struct PreparedAreaCapture {
        let displayIDs: Set<CGDirectDisplayID>
        fileprivate let captureImage: @MainActor (CGRect) async throws -> CGImage

        init(
            displayIDs: Set<CGDirectDisplayID>,
            captureImage: @escaping @MainActor (CGRect) async throws -> CGImage
        ) {
            self.displayIDs = displayIDs
            self.captureImage = captureImage
        }
    }

    private struct PreparedAreaTarget {
        let display: SCDisplay
        let filter: SCContentFilter
    }

    init(screenshotsDirectory: URL? = nil) {
        self.screenshotsDirectory = screenshotsDirectory ?? MediaLibraryManager.screenshotsDirectory
    }

    // MARK: - Dock overlay exclusion
    //
    // The Dock process draws more than its bar: the ⌘-tab app switcher,
    // Launchpad, and Mission Control chrome are all Dock windows that can
    // pop over the screen at the exact instant a capture fires (tabbing
    // away right after an area selection paints the app switcher across
    // the shot). Excluding a fixed window list can't catch those — they
    // don't exist when the list is built. Instead, exclude the whole Dock
    // application and re-include only its stable windows: the wallpaper
    // (negative layers, must stay in shots) and, when the Dock is pinned
    // visible, the bar itself so shots stay what-you-see. The auto-hidden
    // bar and every transient Dock overlay are then excluded even when
    // they appear mid-capture.

    private struct DockExclusion {
        let application: SCRunningApplication
        let exceptedWindows: [SCWindow]
        let dockPID: pid_t
        let dockWasAutoHidden: Bool
    }

    enum DockWindowFilterDisposition: Equatable {
        case exceptFromApplicationExclusion
        case excludedWithApplication
        case excludeWindow
        case unchanged
    }

    private static var cachedDockExclusion: DockExclusion?

    private static var dockAutoHides: Bool {
        UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
    }

    static func displayFilterExcludingDockOverlays(for display: SCDisplay) async -> SCContentFilter {
        guard let exclusion = await currentDockExclusion() else {
            return SCContentFilter(display: display, excludingWindows: [])
        }
        return SCContentFilter(
            display: display,
            excludingApplications: [exclusion.application],
            exceptingWindows: exclusion.exceptedWindows
        )
    }

    /// Builds a Dock-safe filter entirely from one shareable-content snapshot.
    /// Area capture must not mix its fresh display with cached SCWindow handles:
    /// that can hide the frontmost window. Excluding the Dock application and
    /// re-including only its stable windows removes the app switcher and other
    /// transient chrome without reintroducing that stale-window bug.
    static func displayFilterExcludingDockOverlays(
        for display: SCDisplay,
        in content: SCShareableContent
    ) -> SCContentFilter {
        let dockWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.dock"
        }
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let autoHides = dockAutoHides

        let dockApp = content.applications.first(where: { $0.bundleIdentifier == "com.apple.dock" })
        if let dockApp {
            let stableWindows = dockWindows.filter {
                dockWindowFilterDisposition(
                    layer: $0.windowLayer,
                    dockAutoHides: autoHides,
                    dockLevel: dockLevel,
                    dockApplicationAvailable: true
                ) == .exceptFromApplicationExclusion
            }
            return SCContentFilter(
                display: display,
                excludingApplications: [dockApp],
                exceptingWindows: stableWindows
            )
        }

        // The application metadata should always be present when Dock chrome
        // is visible. If it is not, still exclude every transient Dock window
        // that was discoverable in this snapshot.
        let transientWindows = dockWindows.filter {
            dockWindowFilterDisposition(
                layer: $0.windowLayer,
                dockAutoHides: autoHides,
                dockLevel: dockLevel,
                dockApplicationAvailable: false
            ) == .excludeWindow
        }
        return SCContentFilter(display: display, excludingWindows: transientWindows)
    }

    /// Creates all per-display filters from the same content snapshot that
    /// populated CaptureEngine. Filters remain live while the selection UI is
    /// open: newly-created Dock overlays still belong to the excluded Dock
    /// application and therefore never become part of the capture.
    static func prepareAreaCapture(from content: SCShareableContent) -> PreparedAreaCapture? {
        let targets = content.displays.map { display in
            PreparedAreaTarget(
                display: display,
                filter: displayFilterExcludingDockOverlays(for: display, in: content)
            )
        }
        guard !targets.isEmpty else { return nil }
        return PreparedAreaCapture(
            displayIDs: Set(targets.map { $0.display.displayID })
        ) { area in
            guard let display = ScreenGeometry.bestDisplay(
                for: area,
                in: targets.map(\.display)
            ), let target = targets.first(where: { $0.display.displayID == display.displayID }) else {
                throw NSError(domain: "ScreenshotService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Selected display is no longer available"])
            }
            return try await captureAreaCGImage(target: target, area: area)
        }
    }

    private static func currentDockExclusion() async -> DockExclusion? {
        if let cached = cachedDockExclusion, cachedExclusionStillValid(cached) {
            return cached
        }
        return await refreshDockExclusion()
    }

    /// WindowServer recycles window IDs and the Dock rebuilds its windows
    /// on display changes; a stale excepted handle could re-include some
    /// other app's window — or lose the wallpaper. Cheap metadata check
    /// that the Dock process and every excepted window are still what
    /// they were when cached.
    private static func cachedExclusionStillValid(_ cached: DockExclusion) -> Bool {
        guard cached.dockWasAutoHidden == dockAutoHides,
              let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
                  .first?.processIdentifier,
              dockPID == cached.dockPID,
              let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        var liveExceptableIDs = Set<CGWindowID>()
        for info in infos {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == dockPID,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer < 0 || layer == dockLevel else { continue }
            liveExceptableIDs.insert(id)
        }

        return cachedExclusionsStillValid(
            cachedIDs: cached.exceptedWindows.map(\.windowID),
            liveDockBarIDs: liveExceptableIDs
        )
    }

    static func cachedExclusionsStillValid(cachedIDs: [CGWindowID], liveDockBarIDs: Set<CGWindowID>) -> Bool {
        !cachedIDs.isEmpty && cachedIDs.allSatisfy(liveDockBarIDs.contains)
    }

    /// Which Dock windows stay in captures: wallpaper always; the bar only
    /// when it's pinned visible. Everything else the Dock draws (app
    /// switcher, Launchpad, Mission Control) is excluded.
    static func shouldExceptDockWindow(layer: Int, dockAutoHides: Bool, dockLevel: Int) -> Bool {
        layer < 0 || (!dockAutoHides && layer == dockLevel)
    }

    static func dockWindowFilterDisposition(
        layer: Int,
        dockAutoHides: Bool,
        dockLevel: Int,
        dockApplicationAvailable: Bool
    ) -> DockWindowFilterDisposition {
        let isStableWindow = shouldExceptDockWindow(
            layer: layer,
            dockAutoHides: dockAutoHides,
            dockLevel: dockLevel
        )

        if dockApplicationAvailable {
            return isStableWindow ? .exceptFromApplicationExclusion : .excludedWithApplication
        }
        return isStableWindow ? .unchanged : .excludeWindow
    }

    @discardableResult
    private static func refreshDockExclusion() async -> DockExclusion? {
        // onScreenWindowsOnly must be false: an auto-hidden Dock bar sits
        // offscreen at enumeration time.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ), let dockApp = content.applications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            return cachedDockExclusion
        }

        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let autoHides = dockAutoHides
        let excepted = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == "com.apple.dock"
                && shouldExceptDockWindow(layer: window.windowLayer, dockAutoHides: autoHides, dockLevel: dockLevel)
        }

        cachedDockExclusion = DockExclusion(
            application: dockApp,
            exceptedWindows: excepted,
            dockPID: dockApp.processID,
            dockWasAutoHidden: autoHides
        )
        return cachedDockExclusion
    }

    func captureFullScreen(display: SCDisplay?) async -> NSImage? {
        errorMessage = nil

        guard let display = display else {
            errorMessage = "No display available"
            return nil
        }

        do {
            let filter = await Self.displayFilterExcludingDockOverlays(for: display)
            let config = SCStreamConfiguration()
            let scale = ScreenGeometry.backingScale(for: display.displayID) ?? 2.0
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = true
            config.capturesAudio = false
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            let nsImage = NSImage(cgImage: image, size: NSSize(width: display.width, height: display.height))
            lastScreenshot = nsImage
            return nsImage
        } catch {
            errorMessage = "Screenshot failed: \(error.localizedDescription)"
            return nil
        }
    }

    func captureWindow(_ window: SCWindow) async -> NSImage? {
        errorMessage = nil

        do {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.capturesAudio = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.scalesToFit = false

            let scale = ScreenGeometry.backingScale(forCGRect: window.frame) ?? 2.0
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            let nsImage = NSImage(cgImage: image, size: NSSize(width: window.frame.width, height: window.frame.height))
            lastScreenshot = nsImage
            return nsImage
        } catch {
            errorMessage = "Window screenshot failed: \(error.localizedDescription)"
            return nil
        }
    }

    func captureArea(display: SCDisplay?, area: CGRect) async -> NSImage? {
        errorMessage = nil

        do {
            let cgImage = try await Self.captureAreaCGImage(display: display, area: area)
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: area.width, height: area.height))
            lastScreenshot = nsImage
            return nsImage
        } catch {
            errorMessage = "Area screenshot failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Fast path used after area selection. The prepared filter was created
    /// before the overlay appeared, so this method performs no shareable-
    /// content enumeration between mouse-up and the screenshot request.
    func captureArea(preparedCapture: PreparedAreaCapture, area: CGRect) async -> NSImage? {
        errorMessage = nil

        do {
            let cgImage = try await Self.captureAreaCGImage(
                preparedCapture: preparedCapture,
                area: area
            )
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: area.width, height: area.height))
            lastScreenshot = nsImage
            return nsImage
        } catch {
            errorMessage = "Area screenshot failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Captures an area of the screen using ScreenCaptureKit. Used by both the
    /// area-screenshot path and the OCR/translation pipeline so neither has to
    /// touch the deprecated CGWindowListCreateImage (which triggers monthly
    /// permission re-prompts on macOS 15+).
    ///
    /// Fallback path for callers that do not have a prepared capture. The
    /// display and filter must come from the same fresh content snapshot.
    /// Interactive area capture prepares this snapshot before selection so it
    /// does not pay this enumeration cost after mouse-up.
    static func captureAreaCGImage(display: SCDisplay?, area: CGRect) async throws -> CGImage {
        guard let display = display else {
            throw NSError(domain: "ScreenshotService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        let screenRect = area.standardized
        guard screenRect.width > 0, screenRect.height > 0 else {
            throw NSError(domain: "ScreenshotService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Selected area is empty"])
        }

        // Build the display and filter from one fresh shareable-content
        // snapshot after the selection overlay has closed. Reusing a display
        // from an older snapshot—or mixing it with cached window handles—can
        // make ScreenCaptureKit render a stale window stack.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let freshDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else {
            throw NSError(domain: "ScreenshotService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Selected display is no longer available"])
        }

        let filter = Self.displayFilterExcludingDockOverlays(for: freshDisplay, in: content)
        let target = PreparedAreaTarget(display: freshDisplay, filter: filter)
        return try await captureAreaCGImage(target: target, area: screenRect)
    }

    static func captureAreaCGImage(
        preparedCapture: PreparedAreaCapture,
        area: CGRect
    ) async throws -> CGImage {
        let screenRect = area.standardized
        guard screenRect.width > 0, screenRect.height > 0 else {
            throw NSError(domain: "ScreenshotService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Selected area is empty"])
        }
        return try await preparedCapture.captureImage(screenRect)
    }

    private static func captureAreaCGImage(
        target: PreparedAreaTarget,
        area screenRect: CGRect
    ) async throws -> CGImage {
        let display = target.display
        let config = SCStreamConfiguration()
        guard let localRect = ScreenGeometry.integralDisplayLocalRect(
            for: screenRect,
            displayID: display.displayID
        ) else {
            throw NSError(domain: "ScreenshotService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Selected area is outside the captured display"])
        }

        let scale = ScreenGeometry.backingScale(for: display.displayID) ?? 2.0
        config.sourceRect = localRect
        config.width = max(1, Int(localRect.width * scale))
        config.height = max(1, Int(localRect.height * scale))
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let signpostID = areaCaptureSignposter.makeSignpostID()
        let interval = areaCaptureSignposter.beginInterval(
            "Prepared Area Screenshot",
            id: signpostID
        )
        defer {
            areaCaptureSignposter.endInterval("Prepared Area Screenshot", interval)
        }

        return try await SCScreenshotManager.captureImage(
            contentFilter: target.filter,
            configuration: config
        )
    }

    func saveScreenshot(_ image: NSImage, annotated: Bool = false) -> URL? {
        errorMessage = nil
        let dir = screenshotsDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Failed to create directory: \(error.localizedDescription)"
            return nil
        }

        let prefix = annotated ? "Annotated Screenshot" : "Screenshot"
        let url = CaptureFileURL.unique(in: dir, prefix: prefix, pathExtension: "png")

        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            errorMessage = "Failed to convert image to PNG"
            return nil
        }

        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = "Failed to save screenshot: \(error.localizedDescription)"
            return nil
        }
    }
}
