import Foundation
import ScreenCaptureKit
import AppKit
import CoreGraphics

@MainActor
class ScreenshotService: ObservableObject {
    @Published var lastScreenshot: NSImage?
    @Published var errorMessage: String?

    func captureFullScreen(display: SCDisplay?) async -> NSImage? {
        errorMessage = nil

        guard let display = display else {
            errorMessage = "No display available"
            return nil
        }

        do {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(display.width) * 2
            config.height = Int(display.height) * 2
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

            if let frame = Optional(window.frame) {
                config.width = Int(frame.width) * 2
                config.height = Int(frame.height) * 2
            }

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

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width) * 2
        config.height = Int(display.height) * 2
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let fullImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        let displayOrigin = CGDisplayBounds(display.displayID).origin
        let scale = CGFloat(fullImage.width) / CGFloat(display.width)
        let cropRect = CGRect(
            x: (area.origin.x - displayOrigin.x) * scale,
            y: (area.origin.y - displayOrigin.y) * scale,
            width: area.width * scale,
            height: area.height * scale
        )

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
