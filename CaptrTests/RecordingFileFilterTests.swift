import XCTest
@testable import Captr

final class RecordingFileFilterTests: XCTestCase {

    // MARK: - Captr's own recordings are recognized

    func testRecognizes_screenRecording() {
        XCTAssertTrue(MediaLibraryManager.isRecognizedRecording(
            fileName: "Screen Recording 2026-06-09 at 12.00.00.mp4"))
    }

    func testRecognizes_iPhoneMirror() {
        XCTAssertTrue(MediaLibraryManager.isRecognizedRecording(
            fileName: "iPhone Mirror 2026-06-09 at 12.00.00.mp4"))
    }

    func testRecognizes_androidDevice() {
        XCTAssertTrue(MediaLibraryManager.isRecognizedRecording(
            fileName: "Android Device 2026-06-09 at 12.00.00.mp4"))
    }

    // MARK: - Unrelated videos in Downloads are ignored

    func testIgnores_unrelatedVideo() {
        XCTAssertFalse(MediaLibraryManager.isRecognizedRecording(fileName: "movie.mp4"))
        XCTAssertFalse(MediaLibraryManager.isRecognizedRecording(fileName: "vacation clip.mov"))
        XCTAssertFalse(MediaLibraryManager.isRecognizedRecording(
            fileName: "Zoom Recording 2026.mp4"))
    }

    // MARK: - Right prefix but wrong extension is ignored

    func testIgnores_recognizedPrefixWithNonVideoExtension() {
        XCTAssertFalse(MediaLibraryManager.isRecognizedRecording(
            fileName: "Screen Recording 2026-06-09 at 12.00.00.txt"))
    }

    // MARK: - Extension matching is case-insensitive

    func testRecognizes_uppercaseExtension() {
        XCTAssertTrue(MediaLibraryManager.isRecognizedRecording(
            fileName: "Screen Recording 2026-06-09 at 12.00.00.MP4"))
    }
}
