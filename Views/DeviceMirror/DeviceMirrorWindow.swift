import AppKit
import SwiftUI

@MainActor
class DeviceMirrorWindow {
    private var window: NSWindow?
    private var imageViewRef: NSImageView?
    private var iosMirror: IOSDeviceMirror?
    private var androidMirror: AndroidDeviceMirror?
    private weak var appState: AppState?
    private var isWindowOpen = false

    // MARK: - iOS Mirror Window

    func openIOSMirrorWindow(mirror: IOSDeviceMirror, deviceName: String, appState: AppState) {
        // Only close our own window if already open
        if isWindowOpen {
            closeWindow()
        }

        self.iosMirror = mirror
        self.appState = appState

        let deviceRes = mirror.deviceResolution
        let aspect = deviceRes.width > 0 && deviceRes.height > 0 ? deviceRes.width / deviceRes.height : 9.0 / 19.5
        let windowHeight: CGFloat = 700
        let windowWidth: CGFloat = windowHeight * aspect
        let controlsHeight: CGFloat = 50

        let mirrorRect = NSRect(x: 0, y: controlsHeight, width: windowWidth, height: windowHeight)
        let imageView = NSImageView(frame: mirrorRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        if #available(macOS 14.0, *) {
            imageView.layer?.wantsExtendedDynamicRangeContent = false
        }
        imageView.autoresizingMask = [.width, .height]
        if let frame = mirror.currentFrame {
            imageView.image = frame
        }

        let controlsView = makeControlsView(width: windowWidth, height: controlsHeight, isIOS: true)

        let contentHeight = windowHeight + controlsHeight
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: contentHeight))
        containerView.addSubview(imageView)
        containerView.addSubview(controlsView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: contentHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Mirror - \(deviceName)"
        win.contentView = containerView
        win.center()
        win.setFrameAutosaveName("IOSMirrorWindow")
        win.minSize = NSSize(width: 200, height: 400)
        win.animationBehavior = .none

        window = win
        imageViewRef = imageView
        isWindowOpen = true
        bringWindowToFront(win)

        startDisplayTimer(iosMirror: mirror, imageView: imageView)
    }

    // MARK: - Android Mirror Window

    func openAndroidMirrorWindow(mirror: AndroidDeviceMirror, appState: AppState) {
        // Only close our own window if already open
        if isWindowOpen {
            closeWindow()
        }

        self.androidMirror = mirror
        self.appState = appState

        let deviceRes = mirror.deviceResolution
        let aspect = deviceRes.width / deviceRes.height
        let windowHeight: CGFloat = 700
        let windowWidth: CGFloat = windowHeight * aspect
        let controlsHeight: CGFloat = 80

        let imageView = NSImageView(frame: NSRect(x: 0, y: controlsHeight, width: windowWidth, height: windowHeight))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.autoresizingMask = [.width, .height]
        if let frame = mirror.currentFrame {
            imageView.image = frame
        }

        let controlsView = makeControlsView(width: windowWidth, height: controlsHeight, isIOS: false)

        let contentHeight = windowHeight + controlsHeight
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: contentHeight))
        containerView.addSubview(imageView)
        containerView.addSubview(controlsView)

        let clickView = AndroidClickView(frame: NSRect(x: 0, y: controlsHeight, width: windowWidth, height: windowHeight))
        clickView.autoresizingMask = [.width, .height]
        clickView.mirror = mirror
        containerView.addSubview(clickView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: contentHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Mirror - \(mirror.mirroringDeviceName)"
        win.contentView = containerView
        win.center()
        win.setFrameAutosaveName("AndroidMirrorWindow")
        win.minSize = NSSize(width: 200, height: 400)
        win.animationBehavior = .none

        window = win
        imageViewRef = imageView
        isWindowOpen = true
        bringWindowToFront(win)

        startDisplayTimer(androidMirror: mirror, imageView: imageView)
    }

    private func bringWindowToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - Display Timers

    private func startDisplayTimer(iosMirror: IOSDeviceMirror, imageView: NSImageView) {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak iosMirror, weak imageView] timer in
            Task { @MainActor in
                guard let self = self, self.isWindowOpen,
                      let mirror = iosMirror, let iv = imageView else {
                    timer.invalidate()
                    return
                }
                // Each delivered frame is a fresh NSImage, so an identity check
                // skips the redraw when no new frame has arrived.
                if let frame = mirror.currentFrame, frame !== iv.image {
                    iv.image = frame
                }
            }
        }
    }

    private func startDisplayTimer(androidMirror: AndroidDeviceMirror, imageView: NSImageView) {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak androidMirror, weak imageView] timer in
            Task { @MainActor in
                guard let self = self, self.isWindowOpen,
                      let mirror = androidMirror, let iv = imageView else {
                    timer.invalidate()
                    return
                }
                if let frame = mirror.currentFrame, frame !== iv.image {
                    iv.image = frame
                }
            }
        }
    }

    // MARK: - Window Lifecycle

    func closeWindow() {
        isWindowOpen = false
        imageViewRef = nil

        if let win = window {
            win.contentView = nil
            win.close()
            window = nil
        }
        iosMirror = nil
        androidMirror = nil
    }

    var isOpen: Bool {
        window?.isVisible == true
    }

    // MARK: - Controls Builder

    private func makeControlsView(width: CGFloat, height: CGFloat, isIOS: Bool) -> NSView {
        let controlsView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        controlsView.wantsLayer = true
        controlsView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        controlsView.autoresizingMask = [.width]

        var xOffset: CGFloat = 10

        if !isIOS {
            let backBtn = makeButton(title: "◀", x: xOffset, y: height - 38, width: 40)
            backBtn.target = self
            backBtn.action = #selector(androidNavBack(_:))
            controlsView.addSubview(backBtn)
            xOffset += 45

            let homeBtn = makeButton(title: "●", x: xOffset, y: height - 38, width: 40)
            homeBtn.target = self
            homeBtn.action = #selector(androidNavHome(_:))
            controlsView.addSubview(homeBtn)
            xOffset += 45

            let recentsBtn = makeButton(title: "▪▪", x: xOffset, y: height - 38, width: 40)
            recentsBtn.target = self
            recentsBtn.action = #selector(androidNavRecents(_:))
            controlsView.addSubview(recentsBtn)
        }

        var lowerXOffset: CGFloat = 10

        let recordTitle = (isIOS ? iosMirror?.isRecording : androidMirror?.isRecording) == true ? "Stop" : "Record"
        let recordBtn = makeButton(title: recordTitle, x: lowerXOffset, y: 8, color: .systemRed)
        recordBtn.target = self
        recordBtn.action = #selector(recordTapped(_:))
        controlsView.addSubview(recordBtn)
        lowerXOffset += 95

        let ssBtn = makeButton(title: "Screenshot", x: lowerXOffset, y: 8, color: .systemBlue)
        ssBtn.target = self
        ssBtn.action = #selector(screenshotTapped(_:))
        controlsView.addSubview(ssBtn)
        lowerXOffset += 105

        let disconnectBtn = makeButton(title: "Disconnect", x: lowerXOffset, y: 8, color: .systemGray)
        disconnectBtn.target = self
        disconnectBtn.action = #selector(disconnectTapped(_:))
        controlsView.addSubview(disconnectBtn)

        return controlsView
    }

    private func makeButton(title: String, x: CGFloat, y: CGFloat, width: CGFloat = 90, color: NSColor = .controlTextColor) -> NSButton {
        let button = NSButton(frame: NSRect(x: x, y: y, width: width, height: 28))
        button.title = title
        button.bezelStyle = .rounded
        button.contentTintColor = color
        button.font = .systemFont(ofSize: 12, weight: .medium)
        return button
    }

    // MARK: - Button Actions

    @objc private func recordTapped(_ sender: NSButton) {
        if let mirror = iosMirror {
            if mirror.isRecording {
                Task {
                    if let url = await mirror.stopRecording() {
                        await appState?.mediaLibrary.addRecording(at: url)
                        appState?.showSavedNotification("iPhone recording saved")
                    } else if let error = mirror.errorMessage {
                        appState?.showError(error)
                    }
                }
                sender.title = "Record"
            } else {
                mirror.startRecording()
                if mirror.isRecording {
                    sender.title = "Stop"
                } else {
                    appState?.showError(mirror.errorMessage ?? "Failed to start iPhone recording")
                }
            }
        } else if let mirror = androidMirror {
            if mirror.isRecording {
                Task {
                    if let url = await mirror.stopRecording() {
                        await appState?.mediaLibrary.addRecording(at: url)
                        appState?.showSavedNotification("Device recording saved")
                    }
                }
                sender.title = "Record"
            } else {
                mirror.startRecording()
                sender.title = "Stop"
            }
        }
    }

    @objc private func screenshotTapped(_ sender: NSButton) {
        var image: NSImage?
        if let mirror = iosMirror {
            image = mirror.takeScreenshot()
        } else if let mirror = androidMirror {
            image = mirror.takeScreenshot()
        }
        if let image = image {
            ClipboardService.copyImage(image)
            appState?.showSavedNotification("Screenshot copied to clipboard")
        } else {
            appState?.showError("No frame available yet — wait for the mirror to start, then try again")
        }
    }

    @objc private func disconnectTapped(_ sender: NSButton) {
        iosMirror?.stopMirroring()
        androidMirror?.stopMirroring()
        closeWindow()
    }

    @objc private func androidNavBack(_ sender: NSButton) {
        androidMirror?.sendBack()
    }

    @objc private func androidNavHome(_ sender: NSButton) {
        androidMirror?.sendHome()
    }

    @objc private func androidNavRecents(_ sender: NSButton) {
        androidMirror?.sendRecents()
    }
}

// MARK: - Android Click/Drag View

class AndroidClickView: NSView {
    weak var mirror: AndroidDeviceMirror?
    private var dragStartPoint: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        let endPoint = convert(event.locationInWindow, from: nil)
        guard let mirror = mirror else { return }

        let viewSize = bounds.size
        let start = CGPoint(x: dragStartPoint.x, y: viewSize.height - dragStartPoint.y)
        let end = CGPoint(x: endPoint.x, y: viewSize.height - endPoint.y)

        let dist = sqrt(pow(end.x - start.x, 2) + pow(end.y - start.y, 2))

        Task { @MainActor in
            if dist < 15 {
                mirror.handleTap(at: start, viewSize: viewSize)
            } else {
                mirror.handleSwipe(from: start, to: end, viewSize: viewSize)
            }
        }
    }
}
