import AppKit
import CoreGraphics

/// A single recognized text segment from Vision, enriched with everything the
/// in-place translation pipeline needs to redraw it. Decouples downstream
/// stages (translation, compositing) from Vision's normalized-coordinate
/// bounding-box convention.
struct VisionTextBlock {
    /// Bounding box in CGImage pixel space (top-left origin).
    let pixelRect: CGRect

    /// The recognized text.
    let originalText: String

    /// Filled in by the batch translator. Nil until the translate stage runs,
    /// and remains nil on a per-item failure (compositor treats as "leave
    /// original text visible").
    var translatedText: String?

    /// Sampled average color of the region immediately surrounding the
    /// bounding box. Used as the mask fill so the translated text sits on
    /// something close to the original background.
    var backgroundColor: NSColor?

    /// Luminance threshold of `backgroundColor`. Dark backgrounds get light
    /// text and vice versa.
    var isBackgroundDark: Bool = false

    /// Builds a block from a Vision observation plus the image dimensions,
    /// converting from normalized bottom-left coords to pixel top-left.
    init?(region: RecognizedTextRegion, imageWidth: Int, imageHeight: Int) {
        guard !region.text.isEmpty else { return nil }
        let bb = region.boundingBox
        let w = CGFloat(imageWidth)
        let h = CGFloat(imageHeight)
        self.pixelRect = CGRect(
            x: bb.minX * w,
            y: (1 - bb.maxY) * h,
            width: bb.width * w,
            height: bb.height * h
        )
        self.originalText = region.text
    }
}
