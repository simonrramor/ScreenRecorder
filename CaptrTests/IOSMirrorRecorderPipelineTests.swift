import XCTest
import AVFoundation
@testable import Captr

/// End-to-end check of the mirror recorder: odd-width capture buffers (real
/// iPhones are 1179 wide) letterboxed into an even-sized H.264 file whose
/// timestamps follow the capture clock.
final class IOSMirrorRecorderPipelineTests: XCTestCase {

    func testRecordsOddWidthVariableRateFramesIntoPlayableH264() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputURL = dir.appendingPathComponent("mirror.mp4")

        let canvas = IOSMirrorVideoRecorder.evenSize(CGSize(width: 589, height: 1278))
        XCTAssertEqual(canvas, CGSize(width: 588, height: 1278))
        let recorder = try IOSMirrorVideoRecorder(outputURL: outputURL, frameSize: canvas)

        // Variable frame spacing like a real capture: alternating 30/60 fps.
        var elapsed: TimeInterval = 0
        for index in 0..<30 {
            let buffer = try Self.makeBuffer(width: 589, height: 1278, shade: UInt8((index * 8) % 255))
            recorder.append(buffer, elapsed: elapsed)
            elapsed += index.isMultiple(of: 3) ? 1.0 / 30.0 : 1.0 / 60.0
            // Real-time writer input: give it a moment between frames.
            try await Task.sleep(nanoseconds: 8_000_000)
        }

        let finished = await recorder.finish()
        let url = try XCTUnwrap(finished, "recorder produced no file")

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)

        let naturalSize = try await track.load(.naturalSize)
        XCTAssertEqual(naturalSize, canvas, "odd-width frames should letterbox into the even canvas")

        let duration = try await asset.load(.duration).seconds
        // Sum of deltas ≈ 0.667s; allow slack for dropped not-ready frames.
        XCTAssertGreaterThan(duration, 0.4)
        XCTAssertLessThan(duration, 0.8)

        let descriptions = try await track.load(.formatDescriptions)
        let codec = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) }
        XCTAssertEqual(codec, kCMVideoCodecType_H264)
    }

    func testFinishWithoutFramesProducesNoFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputURL = dir.appendingPathComponent("empty.mp4")

        let recorder = try IOSMirrorVideoRecorder(outputURL: outputURL, frameSize: CGSize(width: 588, height: 1278))
        let finished = await recorder.finish()

        XCTAssertNil(finished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    private static func makeBuffer(width: Int, height: Int, shade: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "IOSMirrorRecorderPipelineTests", code: Int(status))
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, Int32(shade), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
}
