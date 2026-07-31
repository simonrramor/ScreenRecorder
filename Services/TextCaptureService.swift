import Foundation
import Vision
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// A Sendable snapshot of the Vision data used by the rest of the app.
/// Vision observations are Objective-C reference types and should not cross
/// concurrency domains directly.
struct RecognizedTextRegion: Sendable {
    let text: String
    let boundingBox: CGRect
}

@MainActor
class TextCaptureService: ObservableObject {
    @Published var errorMessage: String?

    func captureAndRecognizeArea(display: SCDisplay?, area: CGRect) async -> String? {
        errorMessage = nil

        guard let cgImage = await captureScreenArea(display: display, area: area) else {
            return nil
        }

        guard let observations = await recognizeRegions(from: cgImage) else {
            errorMessage = "No text found in the selected area"
            return nil
        }

        let text = Self.assembleText(from: observations)
        return text.isEmpty ? nil : text
    }

    /// Captures the given screen area and returns the raw Vision observations
    /// alongside the source CGImage. Used by the in-place translation
    /// pipeline which needs per-segment bounding boxes, not assembled text.
    func captureObservations(display: SCDisplay?, area: CGRect) async -> (CGImage, [RecognizedTextRegion])? {
        errorMessage = nil

        guard let cgImage = await captureScreenArea(display: display, area: area) else {
            return nil
        }

        let regions = await recognizeRegions(from: cgImage) ?? []
        return (cgImage, regions)
    }

    private func captureScreenArea(display: SCDisplay?, area: CGRect) async -> CGImage? {
        do {
            return try await ScreenshotService.captureAreaCGImage(display: display, area: area)
        } catch {
            errorMessage = "Failed to capture the selected area: \(error.localizedDescription)"
            return nil
        }
    }

    private func recognizeRegions(from cgImage: CGImage) async -> [RecognizedTextRegion]? {
        await Self.performRecognition(on: cgImage)
    }

    /// `VNImageRequestHandler.perform` is synchronous. Reading `results`
    /// after it returns avoids the double-resume crash caused by combining a
    /// request completion handler with a throwing `perform` call.
    @concurrent
    private nonisolated static func performRecognition(on cgImage: CGImage) async -> [RecognizedTextRegion]? {
        guard !Task.isCancelled else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            return nil
        }

        guard !Task.isCancelled else { return nil }
        let regions = (request.results ?? []).compactMap { observation -> RecognizedTextRegion? in
            guard let text = observation.topCandidates(1).first?.string,
                  !text.isEmpty else { return nil }
            return RecognizedTextRegion(text: text, boundingBox: observation.boundingBox)
        }
        return regions.isEmpty ? nil : regions
    }

    /// Groups recognized text observations into paragraphs based on vertical
    /// spacing. Lines with normal line-height gaps are joined with a space;
    /// lines with larger gaps get a paragraph break.
    nonisolated static func assembleText(from observations: [RecognizedTextRegion]) -> String {
        struct Line {
            let text: String
            let minY: CGFloat  // bottom edge in normalized coords (0 = bottom of image)
            let maxY: CGFloat  // top edge
        }

        let lines: [Line] = observations.map { observation in
            let box = observation.boundingBox
            return Line(text: observation.text, minY: box.minY, maxY: box.maxY)
        }

        guard !lines.isEmpty else { return "" }

        // Vision uses bottom-left origin; sort top-to-bottom (descending maxY)
        let sorted = lines.sorted { $0.maxY > $1.maxY }

        if sorted.count == 1 { return sorted[0].text }

        // Compute median line height to adapt to any font size
        let heights = sorted.map { $0.maxY - $0.minY }.sorted()
        let medianHeight = heights[heights.count / 2]

        // Paragraph break threshold: gap > 1.2x the median line height
        let threshold = medianHeight * 1.2

        var result = sorted[0].text
        for i in 1..<sorted.count {
            let gap = sorted[i - 1].minY - sorted[i].maxY
            if gap > threshold {
                result += "\n\n" + sorted[i].text
            } else {
                result += " " + sorted[i].text
            }
        }

        return result
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
