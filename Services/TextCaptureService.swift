import Foundation
import Vision
import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
class TextCaptureService: ObservableObject {
    @Published var errorMessage: String?

    func captureAndRecognizeArea(display: SCDisplay?, area: CGRect, excludingWindowIDs: [CGWindowID] = []) async -> String? {
        errorMessage = nil

        guard let cgImage = await captureScreenArea(display: display, area: area, excludingWindowIDs: excludingWindowIDs) else {
            return nil
        }

        guard let observations = await recognizeObservations(from: cgImage) else {
            errorMessage = "No text found in the selected area"
            return nil
        }

        let text = Self.assembleText(from: observations)
        return text.isEmpty ? nil : text
    }

    /// Captures the given screen area and returns the raw Vision observations
    /// alongside the source CGImage. Used by the in-place translation
    /// pipeline which needs per-segment bounding boxes, not assembled text.
    func captureObservations(display: SCDisplay?, area: CGRect, excludingWindowIDs: [CGWindowID] = []) async -> (CGImage, [VNRecognizedTextObservation])? {
        errorMessage = nil

        guard let cgImage = await captureScreenArea(display: display, area: area, excludingWindowIDs: excludingWindowIDs) else {
            return nil
        }

        let observations = await recognizeObservations(from: cgImage) ?? []
        return (cgImage, observations)
    }

    private func captureScreenArea(display: SCDisplay?, area: CGRect, excludingWindowIDs: [CGWindowID]) async -> CGImage? {
        do {
            return try await ScreenshotService.captureAreaCGImage(display: display, area: area, excludingWindowIDs: excludingWindowIDs)
        } catch {
            errorMessage = "Failed to capture the selected area: \(error.localizedDescription)"
            return nil
        }
    }

    private func recognizeObservations(from cgImage: CGImage) async -> [VNRecognizedTextObservation]? {
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    print("Vision error: \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: observations)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("Vision perform error: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }

    /// Groups recognized text observations into paragraphs based on vertical
    /// spacing. Lines with normal line-height gaps are joined with a space;
    /// lines with larger gaps get a paragraph break.
    static func assembleText(from observations: [VNRecognizedTextObservation]) -> String {
        struct Line {
            let text: String
            let minY: CGFloat  // bottom edge in normalized coords (0 = bottom of image)
            let maxY: CGFloat  // top edge
        }

        let lines: [Line] = observations.compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let box = obs.boundingBox
            return Line(text: text, minY: box.minY, maxY: box.maxY)
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
