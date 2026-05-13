import AppKit
import UniformTypeIdentifiers
import OSLog

private let log = Logger(subsystem: "com.captr.app", category: "screenshot")

enum ClipboardService {

    /// Writes an image to the system clipboard in a format compatible with
    /// native macOS apps, Electron apps (WhatsApp, Slack, etc.), and browsers.
    ///
    /// Writes the NSImage directly (which provides `public.tiff` with full UTI
    /// conformance), then writes PNG data to a temporary file and puts the file
    /// URL on the pasteboard so Electron apps can read it as `image/png`.
    static func copyImage(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        log.info("ClipboardService.copyImage enter imageSize=\(String(describing:image.size), privacy: .public) reps=\(image.representations.count, privacy: .public)")
        pasteboard.clearContents()

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            log.error("ClipboardService.copyImage fallback path: tiff or png conversion failed (tiff=\(image.tiffRepresentation != nil, privacy: .public))")
            let ok = pasteboard.writeObjects([image])
            log.info("ClipboardService.copyImage fallback writeObjects=\(ok, privacy: .public)")
            return
        }

        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        item.setData(tiffData, forType: .tiff)
        let ok = pasteboard.writeObjects([item])
        log.info("ClipboardService.copyImage writeObjects=\(ok, privacy: .public) pngBytes=\(pngData.count, privacy: .public) tiffBytes=\(tiffData.count, privacy: .public)")
    }
}
