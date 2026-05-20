import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenGeometry {
    static var mainDisplayHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    static func cgRect(
        fromCocoaRect rect: CGRect,
        inScreenFrame screenFrame: CGRect,
        mainDisplayHeight: CGFloat = ScreenGeometry.mainDisplayHeight
    ) -> CGRect {
        let rect = rect.standardized
        let globalCocoaTop = screenFrame.origin.y + rect.origin.y + rect.height

        return CGRect(
            x: screenFrame.origin.x + rect.origin.x,
            y: mainDisplayHeight - globalCocoaTop,
            width: rect.width,
            height: rect.height
        )
    }

    static func cgPoint(
        fromCocoaPoint point: CGPoint,
        inScreenFrame screenFrame: CGRect,
        mainDisplayHeight: CGFloat = ScreenGeometry.mainDisplayHeight
    ) -> CGPoint {
        CGPoint(
            x: screenFrame.origin.x + point.x,
            y: mainDisplayHeight - (screenFrame.origin.y + point.y)
        )
    }

    static func cocoaRect(
        fromCGRect rect: CGRect,
        mainDisplayHeight: CGFloat = ScreenGeometry.mainDisplayHeight
    ) -> CGRect {
        let rect = rect.standardized
        return CGRect(
            x: rect.origin.x,
            y: mainDisplayHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func cocoaRect(
        fromCGRect rect: CGRect,
        inScreenFrame screenFrame: CGRect,
        mainDisplayHeight: CGFloat = ScreenGeometry.mainDisplayHeight
    ) -> CGRect {
        let globalRect = cocoaRect(fromCGRect: rect, mainDisplayHeight: mainDisplayHeight)
        return CGRect(
            x: globalRect.origin.x - screenFrame.origin.x,
            y: globalRect.origin.y - screenFrame.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    static func bestDisplay(for area: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        displays
            .map { display in
                (display, intersectionArea(area, CGDisplayBounds(display.displayID)))
            }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }

    static func bestDisplayBounds(for area: CGRect, in displayBounds: [CGRect]) -> CGRect? {
        displayBounds
            .map { bounds in
                (bounds, intersectionArea(area, bounds))
            }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }

    static func integralDisplayLocalRect(for area: CGRect, displayID: CGDirectDisplayID) -> CGRect? {
        integralDisplayLocalRect(for: area, displayBounds: CGDisplayBounds(displayID))
    }

    static func integralDisplayLocalRect(for area: CGRect, displayBounds: CGRect) -> CGRect? {
        let displayBounds = displayBounds.standardized
        let clipped = area.standardized.intersection(displayBounds)
        guard clipped.isNull == false, clipped.width > 0, clipped.height > 0 else {
            return nil
        }

        let localMinX = max(0, floor(clipped.minX - displayBounds.minX))
        let localMinY = max(0, floor(clipped.minY - displayBounds.minY))
        let localMaxX = min(displayBounds.width, ceil(clipped.maxX - displayBounds.minX))
        let localMaxY = min(displayBounds.height, ceil(clipped.maxY - displayBounds.minY))
        let width = localMaxX - localMinX
        let height = localMaxY - localMinY

        guard width > 0, height > 0 else {
            return nil
        }

        return CGRect(x: localMinX, y: localMinY, width: width, height: height)
    }

    static func pixelCropRect(
        for area: CGRect,
        displayID: CGDirectDisplayID,
        imageSize: CGSize
    ) -> CGRect? {
        pixelCropRect(for: area, displayBounds: CGDisplayBounds(displayID), imageSize: imageSize)
    }

    static func pixelCropRect(
        for area: CGRect,
        displayBounds: CGRect,
        imageSize: CGSize
    ) -> CGRect? {
        let displayBounds = displayBounds.standardized
        guard displayBounds.width > 0, displayBounds.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let clipped = area.standardized.intersection(displayBounds)
        guard clipped.isNull == false, clipped.width > 0, clipped.height > 0 else {
            return nil
        }

        let scaleX = imageSize.width / displayBounds.width
        let scaleY = imageSize.height / displayBounds.height
        let minX = max(0, floor((clipped.minX - displayBounds.minX) * scaleX))
        let minY = max(0, floor((clipped.minY - displayBounds.minY) * scaleY))
        let maxX = min(imageSize.width, ceil((clipped.maxX - displayBounds.minX) * scaleX))
        let maxY = min(imageSize.height, ceil((clipped.maxY - displayBounds.minY) * scaleY))
        let width = maxX - minX
        let height = maxY - minY

        guard width > 0, height > 0 else {
            return nil
        }

        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }?.backingScaleFactor
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.standardized.intersection(rhs.standardized)
        guard intersection.isNull == false, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        return intersection.width * intersection.height
    }
}
