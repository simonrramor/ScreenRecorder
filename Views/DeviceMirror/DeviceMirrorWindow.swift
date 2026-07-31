import AppKit
import Combine
import SwiftUI

@MainActor
class DeviceMirrorWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var imageViewRef: NSImageView?
    private var iosMirror: IOSDeviceMirror?
    private var androidMirror: AndroidDeviceMirror?
    private weak var appState: AppState?
    private var isWindowOpen = false
    private var frameCancellable: AnyCancellable?
    private var recordingStateCancellable: AnyCancellable?
    private weak var recordButton: NSButton?
    private var isClosingProgrammatically = false
    private var displaysNativeIOSFeed = false

    // MARK: - iOS Mirror Window

    func openIOSMirrorWindow(mirror: IOSDeviceMirror, deviceName: String, appState: AppState) {
        if let existingWindow = openWindow {
            guard iosMirror === mirror,
                  displaysNativeIOSFeed == mirror.isLowLatencyMirroring else {
                closeWindow()
                openIOSMirrorWindow(mirror: mirror, deviceName: deviceName, appState: appState)
                return
            }
            self.iosMirror = mirror
            self.appState = appState
            existingWindow.title = "Mirror - \(deviceName)"
            bringWindowToFront(existingWindow)
            return
        }
        if isWindowOpen {
            closeWindow()
        }

        self.iosMirror = mirror
        self.androidMirror = nil
        self.appState = appState
        displaysNativeIOSFeed = mirror.isLowLatencyMirroring

        let deviceRes = mirror.deviceResolution
        let aspect = deviceRes.width > 0 && deviceRes.height > 0 ? deviceRes.width / deviceRes.height : 9.0 / 19.5
        let windowHeight: CGFloat = 700
        let windowWidth: CGFloat = windowHeight * aspect
        let controlsHeight: CGFloat = 50

        let mirrorRect = NSRect(x: 0, y: controlsHeight, width: windowWidth, height: windowHeight)
        let mirrorView: NSView
        if mirror.isLowLatencyMirroring {
            // Native mode: host the mirror's display layer. Frames are
            // enqueued straight from the capture queue, so the view needs no
            // per-frame updates from us.
            let hostView = NSView(frame: mirrorRect)
            mirror.displayLayer.frame = hostView.bounds
            hostView.layer = mirror.displayLayer
            hostView.wantsLayer = true
            mirrorView = hostView
        } else {
            let imageView = NSImageView(frame: mirrorRect)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.backgroundColor = NSColor.black.cgColor
            if #available(macOS 14.0, *) {
                imageView.layer?.wantsExtendedDynamicRangeContent = false
            }
            if let frame = mirror.currentFrame {
                imageView.image = frame
            }
            // Repaint when a frame arrives rather than polling on a timer:
            // polling added up to a frame interval of extra judder.
            frameCancellable = mirror.$currentFrame.sink { [weak imageView] frame in
                if let frame {
                    imageView?.image = frame
                }
            }
            imageViewRef = imageView
            mirrorView = imageView
        }
        mirrorView.autoresizingMask = [.width, .height]

        let controlsView = makeControlsView(width: windowWidth, height: controlsHeight, isIOS: true)

        let contentHeight = windowHeight + controlsHeight
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: contentHeight))
        containerView.addSubview(mirrorView)
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
        win.isReleasedWhenClosed = false
        win.delegate = self

        window = win
        isWindowOpen = true
        bringWindowToFront(win)
    }

    // MARK: - Android Mirror Window

    func openAndroidMirrorWindow(mirror: AndroidDeviceMirror, appState: AppState) {
        if let existingWindow = openWindow {
            guard androidMirror === mirror else {
                closeWindow()
                openAndroidMirrorWindow(mirror: mirror, appState: appState)
                return
            }
            self.androidMirror = mirror
            self.appState = appState
            existingWindow.title = "Mirror - \(mirror.mirroringDeviceName)"
            bringWindowToFront(existingWindow)
            return
        }
        if isWindowOpen {
            closeWindow()
        }

        self.androidMirror = mirror
        self.iosMirror = nil
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
        frameCancellable = mirror.$currentFrame.sink { [weak imageView] frame in
            if let frame {
                imageView?.image = frame
            }
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
        win.isReleasedWhenClosed = false
        win.delegate = self

        window = win
        imageViewRef = imageView
        isWindowOpen = true
        bringWindowToFront(win)
    }

    private func bringWindowToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - Window Lifecycle

    private var openWindow: NSWindow? {
        guard let window, isWindowOpen, window.isVisible else { return nil }
        return window
    }

    func closeWindow() {
        isWindowOpen = false

        if let win = window {
            isClosingProgrammatically = true
            win.delegate = nil
            win.contentView = nil
            win.close()
            window = nil
            isClosingProgrammatically = false
        }
        clearViewReferences()
    }

    private func clearViewReferences() {
        imageViewRef = nil
        frameCancellable = nil
        recordingStateCancellable = nil
        recordButton = nil
        iosMirror = nil
        androidMirror = nil
        displaysNativeIOSFeed = false
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let shouldDisconnect = !self.isClosingProgrammatically
            let wasIOS = self.iosMirror != nil
            self.window = nil
            self.isWindowOpen = false
            self.clearViewReferences()

            guard shouldDisconnect, let appState = self.appState else { return }
            if wasIOS {
                await appState.disconnectIOSMirror()
            } else {
                await appState.disconnectAndroidMirror()
            }
        }
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
        recordButton = recordBtn
        if isIOS, let mirror = iosMirror {
            recordingStateCancellable = mirror.$isRecording
                .receive(on: DispatchQueue.main)
                .sink { [weak recordBtn] isRecording in
                    recordBtn?.title = isRecording ? "Stop" : "Record"
                    recordBtn?.isEnabled = true
                }
        } else if let mirror = androidMirror {
            recordingStateCancellable = mirror.$isRecording
                .combineLatest(mirror.$isFinalizingRecording)
                .receive(on: DispatchQueue.main)
                .sink { [weak recordBtn] isRecording, isFinalizing in
                    recordBtn?.title = isFinalizing ? "Saving…" : (isRecording ? "Stop" : "Record")
                    recordBtn?.isEnabled = !isFinalizing
                }
        }
        lowerXOffset += 95

        let copyBtn = makeButton(title: "Copy", x: lowerXOffset, y: 8, color: .systemBlue)
        copyBtn.target = self
        copyBtn.action = #selector(copyTapped(_:))
        controlsView.addSubview(copyBtn)
        lowerXOffset += 95

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
                    sender.isEnabled = false
                    if let url = await mirror.stopRecording() {
                        await appState?.mediaLibrary.addRecording(at: url)
                        appState?.showSavedNotification("iPhone recording saved")
                    } else if let error = mirror.errorMessage {
                        appState?.showError(error)
                    }
                    sender.isEnabled = true
                }
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
                    sender.isEnabled = false
                    if let url = await mirror.stopRecording() {
                        await appState?.mediaLibrary.addRecording(at: url)
                        appState?.showSavedNotification("Device recording saved")
                    } else {
                        appState?.showError(mirror.errorMessage ?? "Android recording could not be saved")
                    }
                    sender.isEnabled = true
                }
            } else {
                mirror.startRecording()
                if !mirror.isRecording {
                    appState?.showError(mirror.errorMessage ?? "Failed to start Android recording")
                }
            }
        }
    }

    @objc private func copyTapped(_ sender: NSButton) {
        var image: NSImage?
        if let mirror = iosMirror {
            image = mirror.takeScreenshot()
        } else if let mirror = androidMirror {
            image = mirror.takeScreenshot()
        }
        if let image = image {
            ClipboardService.copyImage(image)
            appState?.showSavedNotification("Mirror frame copied to clipboard")
        } else {
            appState?.showError("No frame available yet — wait for the mirror to start, then try again")
        }
    }

    @objc private func disconnectTapped(_ sender: NSButton) {
        sender.isEnabled = false
        Task { [weak self] in
            guard let self, let appState = self.appState else { return }
            if self.iosMirror != nil {
                await appState.disconnectIOSMirror()
            } else {
                await appState.disconnectAndroidMirror()
            }
        }
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
