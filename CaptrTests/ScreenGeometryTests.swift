import XCTest
@testable import Captr

final class ScreenGeometryTests: XCTestCase {
    func testCocoaRectToCGRectHandlesDisplayAboveMainScreen() {
        let mainDisplayHeight: CGFloat = 982
        let externalScreenFrame = CGRect(x: -312, y: 982, width: 1920, height: 1080)
        let selection = CGRect(x: 212, y: 680, width: 500, height: 300)

        let rect = ScreenGeometry.cgRect(
            fromCocoaRect: selection,
            inScreenFrame: externalScreenFrame,
            mainDisplayHeight: mainDisplayHeight
        )

        XCTAssertEqual(rect, CGRect(x: -100, y: -980, width: 500, height: 300))
    }

    func testBestDisplayBoundsChoosesLargestIntersection() {
        let mainDisplay = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let externalDisplay = CGRect(x: -312, y: -1080, width: 1920, height: 1080)
        let selection = CGRect(x: 100, y: -300, width: 400, height: 200)

        let display = ScreenGeometry.bestDisplayBounds(
            for: selection,
            in: [mainDisplay, externalDisplay]
        )

        XCTAssertEqual(display, externalDisplay)
    }

    func testPixelCropRectHandlesNegativeDisplayOrigin() {
        let externalDisplay = CGRect(x: -312, y: -1080, width: 1920, height: 1080)
        let selection = CGRect(x: -100, y: -980, width: 500, height: 300)
        let imageSize = CGSize(width: 3840, height: 2160)

        let crop = ScreenGeometry.pixelCropRect(
            for: selection,
            displayBounds: externalDisplay,
            imageSize: imageSize
        )

        XCTAssertEqual(crop, CGRect(x: 424, y: 200, width: 1000, height: 600))
    }

    func testPixelCropRectClampsSelectionAtDisplayEdge() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let selection = CGRect(x: 1500, y: 970, width: 50, height: 50)
        let imageSize = CGSize(width: 3024, height: 1964)

        let crop = ScreenGeometry.pixelCropRect(
            for: selection,
            displayBounds: display,
            imageSize: imageSize
        )

        XCTAssertEqual(crop, CGRect(x: 3000, y: 1940, width: 24, height: 24))
    }

    func testIntegralDisplayLocalRectClampsSelectionAtDisplayEdge() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let selection = CGRect(x: 1500.4, y: 970.4, width: 50, height: 50)

        let localRect = ScreenGeometry.integralDisplayLocalRect(
            for: selection,
            displayBounds: display
        )

        XCTAssertEqual(localRect, CGRect(x: 1500, y: 970, width: 12, height: 12))
    }
}
