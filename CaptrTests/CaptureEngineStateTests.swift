import XCTest
@testable import Captr

final class CaptureEngineStateTests: XCTestCase {

    // MARK: - RecordingState

    func testIdle_isNotActive() {
        let state = RecordingState.idle
        XCTAssertFalse(state.isActive)
    }

    func testPreparing_isActive() {
        let state = RecordingState.preparing
        XCTAssertTrue(state.isActive)
    }

    func testRecording_isActive() {
        let state = RecordingState.recording
        XCTAssertTrue(state.isActive)
    }

    func testPaused_isActive() {
        let state = RecordingState.paused
        XCTAssertTrue(state.isActive)
    }

    func testStopping_isActive() {
        let state = RecordingState.stopping
        XCTAssertTrue(state.isActive)
    }

    func testCountdown_isActive() {
        let state = RecordingState.countdown(3)
        XCTAssertTrue(state.isActive)
    }

    // MARK: - CaptureEngine initial state

    @MainActor
    func testInitialState_isIdle() {
        let engine = CaptureEngine()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertNil(engine.errorMessage)
        XCTAssertEqual(engine.recordingDuration, 0)
    }

    // MARK: - CancelRecording from idle is safe

    @MainActor
    func testCancelRecording_fromIdle_doesNotCrash() async {
        let engine = CaptureEngine()
        await engine.cancelRecording()
        XCTAssertEqual(engine.state, .idle)
    }

    // MARK: - StopRecording from idle returns nil

    @MainActor
    func testStopRecording_fromIdle_returnsNil() async {
        let engine = CaptureEngine()
        let url = await engine.stopRecording()
        XCTAssertNil(url)
    }

    // MARK: - CaptureConfiguration defaults

    func testCaptureConfiguration_defaults() {
        let config = CaptureConfiguration()
        XCTAssertEqual(config.mode, .fullScreen)
        XCTAssertTrue(config.captureSystemAudio)
        XCTAssertFalse(config.captureMicrophone)
        XCTAssertTrue(config.showCursor)
        XCTAssertEqual(config.frameRate, 60)
        XCTAssertEqual(config.resolution, .native)
        XCTAssertNil(config.selectedDisplay)
        XCTAssertNil(config.selectedWindow)
        XCTAssertNil(config.selectedArea)
    }

    // MARK: - CaptureError descriptions

    func testCaptureError_noDisplay_hasDescription() {
        let error = CaptureError.noDisplay
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testCaptureError_noWindow_hasDescription() {
        let error = CaptureError.noWindow
        XCTAssertNotNil(error.errorDescription)
    }

    func testCaptureError_writingFailed_includesMessage() {
        let error = CaptureError.writingFailed("disk full")
        XCTAssertTrue(error.errorDescription!.contains("disk full"))
    }
}
