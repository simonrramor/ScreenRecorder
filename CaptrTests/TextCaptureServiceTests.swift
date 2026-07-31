import XCTest
@testable import Captr

final class TextCaptureServiceTests: XCTestCase {
    func testAssembleTextReturnsEmptyStringForNoRegions() {
        XCTAssertEqual(TextCaptureService.assembleText(from: []), "")
    }

    func testAssembleTextSortsVisionRegionsFromTopToBottom() {
        let regions = [
            RecognizedTextRegion(text: "second", boundingBox: CGRect(x: 0, y: 0.70, width: 0.4, height: 0.05)),
            RecognizedTextRegion(text: "first", boundingBox: CGRect(x: 0, y: 0.80, width: 0.4, height: 0.05))
        ]

        XCTAssertEqual(TextCaptureService.assembleText(from: regions), "first second")
    }

    func testAssembleTextInsertsParagraphBreakForLargeVerticalGap() {
        let regions = [
            RecognizedTextRegion(text: "First paragraph", boundingBox: CGRect(x: 0, y: 0.80, width: 0.4, height: 0.05)),
            RecognizedTextRegion(text: "Second paragraph", boundingBox: CGRect(x: 0, y: 0.50, width: 0.4, height: 0.05))
        ]

        XCTAssertEqual(
            TextCaptureService.assembleText(from: regions),
            "First paragraph\n\nSecond paragraph"
        )
    }
}
