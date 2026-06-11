import SwiftUI
import AppKit

// MARK: - Native Area Selection View (handles mouse events directly)

class AreaSelectionNSView: NSView {
    var onAreaSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var isDragging = false
    private var selectionLayer = CAShapeLayer()
    private var dimensionLabel = CATextLayer()
    private var overlayLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupLayers()
        setupCursorTracking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupLayers()
        setupCursorTracking()
    }

    private func setupCursorTracking() {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    private func setupLayers() {
        guard let layer = self.layer else { return }

        // Dark overlay covering everything
        overlayLayer.frame = bounds
        overlayLayer.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        layer.addSublayer(overlayLayer)

        // Selection border
        selectionLayer.fillColor = NSColor.white.withAlphaComponent(0.05).cgColor
        selectionLayer.strokeColor = NSColor.controlAccentColor.cgColor
        selectionLayer.lineWidth = 2
        selectionLayer.isHidden = true
        layer.addSublayer(selectionLayer)

        // Dimension label
        dimensionLabel.fontSize = 12
        dimensionLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        dimensionLabel.foregroundColor = NSColor.white.cgColor
        dimensionLabel.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        dimensionLabel.cornerRadius = 4
        dimensionLabel.alignmentMode = .center
        dimensionLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        dimensionLabel.isHidden = true
        layer.addSublayer(dimensionLabel)
    }

    override func layout() {
        super.layout()
        overlayLayer.frame = bounds
    }

    private var selectionRect: CGRect? {
        guard let start = startPoint, let current = currentPoint else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func clampedPoint(from event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = clampedPoint(from: event)
        startPoint = point
        currentPoint = point
        isDragging = true
        selectionLayer.isHidden = false
        dimensionLabel.isHidden = false
        updateSelectionDisplay()
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = clampedPoint(from: event)
        updateSelectionDisplay()
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = clampedPoint(from: event)
        isDragging = false

        if let rect = selectionRect, rect.width > 10, rect.height > 10 {
            // Convert from flipped view coordinates to bottom-left origin for the callback
            onAreaSelected?(rect)
        } else {
            // Too small, reset
            startPoint = nil
            currentPoint = nil
            selectionLayer.isHidden = true
            dimensionLabel.isHidden = true
        }
    }

    private func updateSelectionDisplay() {
        guard let rect = selectionRect else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Update selection rectangle - use clear cutout approach
        // First update the overlay to have a hole
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(rect)

        let maskLayer = CAShapeLayer()
        maskLayer.path = path
        maskLayer.fillRule = .evenOdd
        overlayLayer.mask = maskLayer

        // Update selection border
        selectionLayer.path = CGPath(rect: rect, transform: nil)
        selectionLayer.isHidden = false

        // Update dimension label
        let labelText = "\(Int(rect.width)) x \(Int(rect.height))"
        dimensionLabel.string = labelText
        let labelWidth = CGFloat(labelText.count) * 8 + 16
        let labelHeight: CGFloat = 22
        dimensionLabel.frame = CGRect(
            x: rect.midX - labelWidth / 2,
            y: rect.minY - labelHeight - 8,
            width: labelWidth,
            height: labelHeight
        )
        dimensionLabel.isHidden = false

        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // The overlay panel is key without the app being active, so Escape must
    // be handled here rather than relying on app-level key routing.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancelled?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            NSCursor.crosshair.set()
        }
    }
}

// MARK: - Area Selection Window Controller

class AreaSelectionWindowController {
    private var windows: [OverlayWindow] = []
    private var escapeMonitor: Any?
    private var localEscapeMonitor: Any?

    deinit {
        removeMonitors()
        let wins = windows
        windows.removeAll()
        for window in wins {
            window.orderOut(nil)
        }
    }

    @MainActor
    func showOverlay(onSelected: @escaping (CGRect) -> Void, onCancelled: @escaping () -> Void) {
        closeOverlay()

        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                onCancelled()
                self?.closeOverlay()
            }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                onCancelled()
                self?.closeOverlay()
                return nil
            }
            return event
        }

        for screen in NSScreen.screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true

            let selectionView = AreaSelectionNSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            selectionView.onAreaSelected = { [weak self] rect in
                let screenRect = self?.convertToScreenCoordinates(rect, in: screen) ?? rect
                onSelected(screenRect)
                self?.closeOverlay()
            }
            selectionView.onCancelled = { [weak self] in
                onCancelled()
                self?.closeOverlay()
            }

            window.contentView = selectionView
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(selectionView)
            windows.append(window)
        }

        // No NSApp.activate here: the overlays are non-activating key panels
        // (Spotlight-style), so they take keyboard input on their own.
        // Activating the app would also drag its regular windows (the main
        // window) in front of whatever the user is capturing.
        if let firstWindow = windows.first {
            firstWindow.makeKeyAndOrderFront(nil)
            if let view = firstWindow.contentView as? AreaSelectionNSView {
                firstWindow.makeFirstResponder(view)
            }
        }
    }

    func closeOverlay() {
        removeMonitors()

        let windowsToClose = windows
        windows.removeAll()

        for window in windowsToClose {
            // alphaValue = 0 makes the window's contents disappear in the
            // current compositor frame — orderOut alone is queued and can
            // still be on-screen when SCScreenshotManager grabs the next
            // frame for an area screenshot.
            window.alphaValue = 0
            window.orderOut(nil)
            window.close()
        }
        // Force WindowServer to commit the alpha/orderOut changes before
        // the capture pipeline reads back the screen.
        CATransaction.flush()
    }

    private func removeMonitors() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            localEscapeMonitor = nil
        }
    }

    private func convertToScreenCoordinates(_ rect: CGRect, in screen: NSScreen) -> CGRect {
        ScreenGeometry.cgRect(fromCocoaRect: rect, inScreenFrame: screen.frame)
    }
}

// MARK: - Window Selection View (highlights windows on hover, selects on click)

private struct WindowInfo {
    let windowID: CGWindowID
    let frame: CGRect
    let title: String
    let ownerName: String
}

class WindowSelectionNSView: NSView {
    var onWindowSelected: ((CGWindowID) -> Void)?
    var onCancelled: (() -> Void)?

    private var windowInfos: [WindowInfo] = []
    private var highlightedWindowID: CGWindowID?
    private var overlayLayer = CALayer()
    private var highlightLayer = CAShapeLayer()
    private var titleLabel = CATextLayer()
    private let screen: NSScreen

    init(frame: NSRect, screen: NSScreen) {
        self.screen = screen
        super.init(frame: frame)
        wantsLayer = true
        fetchWindowInfos()
        setupLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func fetchWindowInfos() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }

        for info in list {
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != myPID else { continue }

            guard let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width > 1, frame.height > 1 else { continue }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            windowInfos.append(WindowInfo(
                windowID: windowID,
                frame: frame,
                title: info[kCGWindowName as String] as? String ?? "",
                ownerName: info[kCGWindowOwnerName as String] as? String ?? ""
            ))
        }
    }

    private func setupLayers() {
        guard let layer = self.layer else { return }

        overlayLayer.frame = bounds
        overlayLayer.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        layer.addSublayer(overlayLayer)

        highlightLayer.fillColor = NSColor.white.withAlphaComponent(0.05).cgColor
        highlightLayer.strokeColor = NSColor.controlAccentColor.cgColor
        highlightLayer.lineWidth = 3
        highlightLayer.isHidden = true
        layer.addSublayer(highlightLayer)

        titleLabel.fontSize = 13
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.foregroundColor = NSColor.white.cgColor
        titleLabel.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        titleLabel.cornerRadius = 6
        titleLabel.alignmentMode = .center
        titleLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        titleLabel.isHidden = true
        layer.addSublayer(titleLabel)
    }

    override func layout() {
        super.layout()
        overlayLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    private func viewPointToCG(_ viewPoint: CGPoint) -> CGPoint {
        ScreenGeometry.cgPoint(fromCocoaPoint: viewPoint, inScreenFrame: screen.frame)
    }

    private func cgRectToView(_ cgRect: CGRect) -> CGRect {
        ScreenGeometry.cocoaRect(fromCGRect: cgRect, inScreenFrame: screen.frame)
    }

    private func windowAtPoint(_ cgPoint: CGPoint) -> WindowInfo? {
        windowInfos.first { $0.frame.contains(cgPoint) }
    }

    override func mouseMoved(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let cgPoint = viewPointToCG(viewPoint)

        if let info = windowAtPoint(cgPoint) {
            guard highlightedWindowID != info.windowID else { return }
            highlightedWindowID = info.windowID
            updateHighlight(info)
        } else if highlightedWindowID != nil {
            highlightedWindowID = nil
            clearHighlight()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let cgPoint = viewPointToCG(viewPoint)
        if let info = windowAtPoint(cgPoint) {
            onWindowSelected?(info.windowID)
        }
    }

    private func updateHighlight(_ info: WindowInfo) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let viewRect = cgRectToView(info.frame)

        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(viewRect)
        let mask = CAShapeLayer()
        mask.path = path
        mask.fillRule = .evenOdd
        overlayLayer.mask = mask

        highlightLayer.path = CGPath(rect: viewRect, transform: nil)
        highlightLayer.isHidden = false

        let text = info.title.isEmpty ? info.ownerName : "\(info.ownerName) — \(info.title)"
        titleLabel.string = text
        let labelWidth = min(CGFloat(text.count) * 8 + 24, max(viewRect.width, 120))
        let labelHeight: CGFloat = 26
        titleLabel.frame = CGRect(
            x: viewRect.midX - labelWidth / 2,
            y: viewRect.maxY + 8,
            width: labelWidth,
            height: labelHeight
        )
        titleLabel.isHidden = false

        CATransaction.commit()
    }

    private func clearHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayLayer.mask = nil
        highlightLayer.isHidden = true
        titleLabel.isHidden = true
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancelled?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Window Selection Window Controller

class WindowSelectionWindowController {
    private var panels: [NSPanel] = []
    private var escapeMonitor: Any?
    private var localEscapeMonitor: Any?

    deinit {
        removeMonitors()
        let panelsToClose = panels
        panels.removeAll()
        for panel in panelsToClose {
            panel.orderOut(nil)
        }
    }

    @MainActor
    func showOverlay(onSelected: @escaping (CGWindowID) -> Void, onCancelled: @escaping () -> Void) {
        closeOverlay()

        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                onCancelled()
                self?.closeOverlay()
            }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                onCancelled()
                self?.closeOverlay()
                return nil
            }
            return event
        }

        for screen in NSScreen.screens {
            let panel = WindowSelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true

            let selectionView = WindowSelectionNSView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen)
            selectionView.onWindowSelected = { [weak self] windowID in
                onSelected(windowID)
                self?.closeOverlay()
            }
            selectionView.onCancelled = { [weak self] in
                onCancelled()
                self?.closeOverlay()
            }

            panel.contentView = selectionView
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(selectionView)
            panels.append(panel)
        }

        // Non-activating key panels take keyboard input without activating
        // the app (which would raise the main window over the capture target).
        if let first = panels.first {
            first.makeKeyAndOrderFront(nil)
            if let view = first.contentView as? WindowSelectionNSView {
                first.makeFirstResponder(view)
            }
        }
    }

    func closeOverlay() {
        removeMonitors()
        let panelsToClose = panels
        panels.removeAll()
        for panel in panelsToClose {
            panel.orderOut(nil)
            panel.close()
        }
    }

    private func removeMonitors() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            localEscapeMonitor = nil
        }
    }
}

private class WindowSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        var panelStyle = styleMask
        panelStyle.insert(.nonactivatingPanel)
        super.init(contentRect: contentRect, styleMask: panelStyle, backing: backing, defer: flag)
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = false
    }
}

// MARK: - Recording Area Overlay (shown during area recording)

struct RecordingAreaOverlayView: NSViewRepresentable {
    let recordingRect: CGRect
    let screenFrame: CGRect

    func makeNSView(context: Context) -> RecordingOverlayNSView {
        let view = RecordingOverlayNSView()
        view.recordingRect = recordingRect
        view.screenFrame = screenFrame
        return view
    }

    func updateNSView(_ nsView: RecordingOverlayNSView, context: Context) {
        nsView.recordingRect = recordingRect
        nsView.screenFrame = screenFrame
        nsView.needsDisplay = true
    }
}

class RecordingOverlayNSView: NSView {
    var recordingRect: CGRect = .zero
    var screenFrame: CGRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Fill entire view with dark overlay
        context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        context.fill(bounds)

        // Convert from CG coordinates (top-left origin) to view coordinates (bottom-left origin)
        let localRect = ScreenGeometry.cocoaRect(fromCGRect: recordingRect, inScreenFrame: screenFrame)

        // Clear the recording area
        context.setBlendMode(.clear)
        context.fill(localRect)

        // Draw border around the recording area
        context.setBlendMode(.normal)
        context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(2)
        context.stroke(localRect.insetBy(dx: -1, dy: -1))
    }
}

class RecordingAreaOverlayController {
    private var windows: [NSWindow] = []

    deinit {
        let wins = windows
        windows.removeAll()
        for window in wins {
            window.orderOut(nil)
        }
    }

    @MainActor
    func showOverlay(recordingRect: CGRect) {
        closeOverlay()

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.hasShadow = false

            let hostingView = NSHostingView(rootView:
                RecordingAreaOverlayView(
                    recordingRect: recordingRect,
                    screenFrame: screen.frame
                )
            )
            hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
            window.contentView = hostingView
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func closeOverlay() {
        let windowsToClose = windows
        windows.removeAll()
        for window in windowsToClose {
            window.orderOut(nil)
            window.close()
        }
    }
}

// MARK: - Overlay Window

class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        var panelStyle = styleMask
        panelStyle.insert(.nonactivatingPanel)
        super.init(contentRect: contentRect, styleMask: panelStyle, backing: backing, defer: flag)
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = false
    }
}
