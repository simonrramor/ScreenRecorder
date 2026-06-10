import XCTest
import CoreMedia
@testable import Captr

final class IOSMirrorRecorderTimingTests: XCTestCase {

    // MARK: - Presentation times follow the capture clock

    func testElapsedTimeMapsDirectlyToPresentationTime() {
        let time = IOSMirrorVideoRecorder.nextPresentationTime(elapsed: 1.5, after: nil)
        XCTAssertEqual(time.seconds, 1.5, accuracy: 0.001)
    }

    func testNegativeElapsedClampsToZero() {
        let time = IOSMirrorVideoRecorder.nextPresentationTime(elapsed: -0.25, after: nil)
        XCTAssertEqual(time.seconds, 0, accuracy: 0.001)
    }

    // MARK: - Timestamps never go backwards (AVAssetWriter rejects that)

    func testEqualTimestampIsNudgedForward() {
        let last = CMTime(seconds: 2.0, preferredTimescale: 600)
        let time = IOSMirrorVideoRecorder.nextPresentationTime(elapsed: 2.0, after: last)
        XCTAssertEqual(CMTimeCompare(time, last), 1)
    }

    func testEarlierTimestampIsNudgedPastPrevious() {
        let last = CMTime(seconds: 3.0, preferredTimescale: 600)
        let time = IOSMirrorVideoRecorder.nextPresentationTime(elapsed: 1.0, after: last)
        XCTAssertEqual(CMTimeCompare(time, last), 1)
    }

    func testLaterTimestampIsKeptExactly() {
        let last = CMTime(seconds: 1.0, preferredTimescale: 600)
        let time = IOSMirrorVideoRecorder.nextPresentationTime(elapsed: 1.5, after: last)
        XCTAssertEqual(time.seconds, 1.5, accuracy: 0.001)
    }

    // MARK: - H.264 frame sizes must be even

    func testOddDimensionsAreFlooredToEven() {
        // iPhone 14 Pro native width is 1179 (odd).
        let size = IOSMirrorVideoRecorder.evenSize(CGSize(width: 1179, height: 2556))
        XCTAssertEqual(size, CGSize(width: 1178, height: 2556))
    }

    func testEvenDimensionsAreUnchanged() {
        let size = IOSMirrorVideoRecorder.evenSize(CGSize(width: 1170, height: 2532))
        XCTAssertEqual(size, CGSize(width: 1170, height: 2532))
    }

    func testTinySizesClampToMinimumEncodableSize() {
        let size = IOSMirrorVideoRecorder.evenSize(CGSize(width: 1, height: 0))
        XCTAssertEqual(size, CGSize(width: 2, height: 2))
    }
}
