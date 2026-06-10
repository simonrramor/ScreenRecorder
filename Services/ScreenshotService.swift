import Foundation
import ScreenCaptureKit
import AppKit
import CoreGraphics

@MainActor
class ScreenshotService: ObservableObject {
    @Published var lastScreenshot: NSImage?
    @Published var errorMessage: String?

    // MARK: - Auto-hidden Dock exclusion
    //
    // Area selections end with the cursor parked at a screen edge, which
    // slides the auto-hidden Dock in *under the selection overlay* right as
    // the capture fires — so a Dock the user never saw shows up in the shot.
    // Exclude the Dock bar from display captures while it's set to auto-hide;
    // a pinned (always-visible) Dock stays in shots like the system tool.
    // Only the bar itself is excluded (layer kCGDockWindowLevel): the Dock
    // process also owns the desktop wallpaper windows, which must stay.

    private static var cachedDockBarWindows: [SCWindow] = []

    private static var dockAutoHides: Bool {
        UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
    }

    private static func transientDockExclusion() async -> [SCWindow] {
        guard dockAutoHides else { return [] }

        if !cachedDockBarWindows.isEmpty {
            // Serve the cached handles and refresh behind this capture so the
            // capture itself never waits on window enumeration.
            Task { await refreshDockBarWindows() }
            return cachedDockBarWindows
        }
        return await refreshDockBarWindows()
    }

    @discardableResult
    private static func refreshDockBarWindows() async -> [SCWindow] {
        // onScreenWindowsOnly must be false: an auto-hidden Dock sits
        // offscreen at enumeration time, which is exactly when we need it.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) else {
            return cachedDockBarWindows
        }

        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        cachedDockBarWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == "com.apple.dock"
                && window.windowLayer == dockLevel
        }
        return cachedDockBarWindows
    }

    func captureFullScreen(display: SCDisplay?) async -> NSImage? {
        errorMessage = nil

        guard let display = display else {
            errorMessage = "No display available"
            return nil
        }

        do {
            let filter = SCContentFilter(display: display, excludingWindows: await Self.transientDockExclusion())
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
    static func captureAreaCGImage(display: SCDisplay?, area: CGRect) async throws -> CGImage {
        guard let display = display else {
            throw NSError(domain: "ScreenshotService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: await transientDockExclusion())
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
            for: area,
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
