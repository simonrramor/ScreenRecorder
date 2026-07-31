import Foundation
import ScreenCaptureKit
import AppKit
import CoreGraphics

@MainActor
class ScreenshotService: ObservableObject {
    @Published var lastScreenshot: NSImage?
    @Published var errorMessage: String?

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

    private static func currentDockExclusion() async -> DockExclusion? {
        if let cached = cachedDockExclusion, cachedExclusionStillValid(cached) {
            // Serve the validated cache and refresh behind this capture so
            // the capture itself never waits on window enumeration.
            Task { await refreshDockExclusion() }
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

        // Without the wallpaper windows identified, excluding the Dock app
        // would punch the desktop picture out of shots — skip exclusion.
        guard !excepted.isEmpty else {
            cachedDockExclusion = nil
            return nil
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

    /// Captures an area of the screen using ScreenCaptureKit. Used by both the
    /// area-screenshot path and the OCR/translation pipeline so neither has to
    /// touch the deprecated CGWindowListCreateImage (which triggers monthly
    /// permission re-prompts on macOS 15+).
    ///
    /// macOS 15.2 added a region-native screenshot API. Use it whenever it is
    /// available: it captures the requested screen-space rect directly and
    /// avoids mixing a display from one SCShareableContent snapshot with
    /// cached Dock SCWindow handles from another snapshot. That mix can cause
    /// ScreenCaptureKit to omit the frontmost window and reveal the content
    /// underneath it. The filtered full-display path remains as a fallback
    /// for macOS 15.0–15.1.
    static func captureAreaCGImage(display: SCDisplay?, area: CGRect) async throws -> CGImage {
        guard let display = display else {
            throw NSError(domain: "ScreenshotService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        let screenRect = area.standardized
        guard screenRect.width > 0, screenRect.height > 0 else {
            throw NSError(domain: "ScreenshotService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Selected area is empty"])
        }

        if #available(macOS 15.2, *) {
            return try await SCScreenshotManager.captureImage(in: screenRect)
        }

        // The direct region API is unavailable on macOS 15.0–15.1. Keep the
        // fallback deliberately unfiltered so a stale Dock exception can
        // never hide the user's frontmost window.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = ScreenGeometry.backingScale(for: display.displayID) ?? 2.0
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let fullImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        let imageSize = CGSize(width: CGFloat(fullImage.width), height: CGFloat(fullImage.height))
        guard let cropRect = ScreenGeometry.pixelCropRect(
            for: screenRect,
            displayID: display.displayID,
            imageSize: imageSize
        ) else {
            throw NSError(domain: "ScreenshotService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Selected area is outside the captured display"])
        }

        guard let cropped = fullImage.cropping(to: cropRect) else {
            throw NSError(domain: "ScreenshotService", code: 2, userInfo: [NSLocalizedDescriptionKey: "crop out of bounds"])
        }

        return cropped
    }

    func saveScreenshot(_ image: NSImage, annotated: Bool = false) -> URL? {
        errorMessage = nil
        let dir = MediaLibraryManager.screenshotsDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Failed to create directory: \(error.localizedDescription)"
            return nil
        }

        let prefix = annotated ? "Annotated Screenshot" : "Screenshot"
        let fileName = "\(prefix) \(Date().screenRecorderFileName).png"
        let url = dir.appendingPathComponent(fileName)

        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            errorMessage = "Failed to convert image to PNG"
            return nil
        }

        do {
            try pngData.write(to: url)
            return url
        } catch {
            errorMessage = "Failed to save screenshot: \(error.localizedDescription)"
            return nil
        }
    }
}
