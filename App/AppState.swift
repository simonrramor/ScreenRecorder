import Foundation
import SwiftUI
import AppKit
import ScreenCaptureKit
import Combine
import NaturalLanguage
import Translation

@MainActor
class AppState: ObservableObject {
    @Published var captureEngine = CaptureEngine()
    @Published var screenshotService = ScreenshotService()
    @Published var textCaptureService = TextCaptureService()
    @Published var mediaLibrary = MediaLibraryManager()
    @Published var permissionsManager = PermissionsManager()
    @Published var shortcutSettings = ShortcutSettings()
    @Published var translationSettings = TranslationSettings()

    @Published var deviceManager = DeviceManager()
    @Published var iosDeviceMirror = IOSDeviceMirror()
    @Published var androidDeviceMirror: AndroidDeviceMirror?
    var iosMirrorWindow = DeviceMirrorWindow()
    var androidMirrorWindow = DeviceMirrorWindow()
    private var deviceManagerCancellable: AnyCancellable?
    private var captureEngineCancellable: AnyCancellable?
    private var iosMirrorCancellable: AnyCancellable?
    private var androidMirrorCancellable: AnyCancellable?
    private var screenParametersCancellable: AnyCancellable?

    @Published var pendingCaptureAction: CaptureType?

    // Capture UI state
    @Published var isVideoMode: Bool = false
    @Published var screenshotMode: CaptureMode = .area

    @Published var showAnnotationEditor: Bool = false
    @Published var annotationImage: NSImage?
    @Published var annotationState = AnnotationState()

    @Published var showNotification: Bool = false
    @Published var notificationMessage: String = ""
    @Published var notificationIsError: Bool = false
    @Published var isRecordingShortcut: Bool = false
    @Published var showSettingsPopover: Bool = false
    private var notificationDismissTask: Task<Void, Never>?

    private let areaSelectionController = AreaSelectionWindowController()
    private let windowSelectionController = WindowSelectionWindowController()
    private let recordingAreaOverlayController = RecordingAreaOverlayController()
    let annotationWindowController = AnnotationWindowController()
    let translationOverlayController = TranslationOverlayController()
    lazy var translationService = TranslationService(settings: translationSettings)
    var keyboardShortcutManager: KeyboardShortcutManager?

    func unregisterShortcutsTemporarily() {
        keyboardShortcutManager?.unregisterShortcuts()
    }

    func reregisterShortcuts() {
        keyboardShortcutManager?.registerShortcuts()
    }

    var configuration: CaptureConfiguration {
        get { captureEngine.configuration }
        set { captureEngine.configuration = newValue }
    }

    func initialize() async {
        await permissionsManager.checkAllPermissions()
        await captureEngine.refreshAvailableContent()
        await mediaLibrary.loadLibrary()
        deviceManager.startMonitoring()
        setupAndroidMirror()

        captureEngine.onStreamError = { [weak self] message in
            self?.recordingAreaOverlayController.closeOverlay()
            self?.showErrorNotification(message)
        }
        captureEngine.onWarning = { [weak self] message in
            self?.showErrorNotification(message)
        }

        // @Published on reference types only fires on reassignment, so
        // forward the sub-objects' changes for views that read them through
        // appState (menu bar status, recording duration, ...).
        deviceManagerCancellable = deviceManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        captureEngineCancellable = captureEngine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        iosMirrorCancellable = iosDeviceMirror.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        screenParametersCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.captureEngine.refreshAvailableContent()
                }
            }
    }

    private func setupAndroidMirror() {
        guard let adb = deviceManager.adbPath else { return }

        let mirror = AndroidDeviceMirror(adbPath: adb, scrcpyPath: deviceManager.scrcpyPath)
        mirror.onRecordingAutoStopped = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let mirror = self.androidDeviceMirror else { return }
                if let url = await mirror.stopRecording() {
                    await self.mediaLibrary.addRecording(at: url)
                    self.showSavedNotification("Android recording hit the 3-minute system limit and was saved")
                } else {
                    self.showErrorNotification(mirror.errorMessage ?? "Android recording stopped unexpectedly")
                }
            }
        }
        androidMirrorCancellable = mirror.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        androidDeviceMirror = mirror
    }

    // MARK: - Device Mirroring Actions

    func startFirstAvailableIOSMirroring() async {
        var device = deviceManager.iosDevices.first

        if deviceManager.iosDevices.isEmpty {
            deviceManager.scanIOSDevices()

            for _ in 0..<20 where deviceManager.iosDevices.isEmpty {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            device = deviceManager.iosDevices.first
        }

        if device == nil {
            device = await deviceManager.refreshIOSDevicesNow().first
        }

        guard let device else {
            let message = await deviceManager.iosConnectionIssueMessage()
            showErrorNotification(message)
            return
        }

        await startDeviceMirroring(device: device)
        NSApp.activate(ignoringOtherApps: true)
    }

    func startFirstAvailableAndroidMirroring() async {
        if androidDeviceMirror == nil || androidDeviceMirror?.isMirroring == false {
            setupAndroidMirror()
        }

        guard deviceManager.adbAvailable else {
            showErrorNotification("ADB not installed. Install via Homebrew: brew install android-platform-tools")
            return
        }

        if deviceManager.androidDevices.isEmpty {
            deviceManager.scanAndroidDevices()

            for _ in 0..<10 where deviceManager.androidDevices.isEmpty {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        guard let device = deviceManager.androidDevices.first else {
            showErrorNotification("Connect your Android by cable, enable USB debugging, and allow the trust prompt.")
            return
        }

        await startDeviceMirroring(device: device)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// How an iOS mirror ended up on screen after running the transport
    /// ladder (native → low-latency H.264 → screenshot compatibility).
    private enum IOSMirrorMode {
        case native
        case lowLatency
        case compatibility
    }

    /// Runs the iOS mirror transport ladder shared by plain mirroring and
    /// mirror-with-recording. Returns the mode that ended up active, or nil
    /// when everything failed (an error notification was already shown).
    private func openIOSMirror(udid: String, deviceName: String) async -> IOSMirrorMode? {
        if !iosDeviceMirror.isMirroring {
            // Avoid the native CoreMediaIO iOS screen-capture path for now.
            // On macOS 26 it can crash the process after falling back to the
            // in-app mirror, so try H.264 low latency without native preview.
            iosDeviceMirror.startMirroring(udid: udid, deviceName: deviceName, allowNative: false)
        }
        guard iosDeviceMirror.isMirroring else {
            showErrorNotification(iosDeviceMirror.errorMessage ?? "Failed to start iOS mirroring")
            return nil
        }

        if iosDeviceMirror.isNativeMirroring {
            iosMirrorWindow.openIOSMirrorWindow(mirror: iosDeviceMirror, deviceName: deviceName, appState: self)
            if await iosDeviceMirror.waitForNativeStartup() {
                return .native
            }
            let startupError = iosDeviceMirror.errorMessage ?? "Native iPhone mirror opened, but no video frames arrived."
            return fallBackToCompatibilityMirror(udid: udid, deviceName: deviceName, startupError: startupError)
        }

        if iosDeviceMirror.isLowLatencyMirroring {
            if await iosDeviceMirror.waitForLowLatencyStartup() {
                return .lowLatency
            }
            let startupError = iosDeviceMirror.errorMessage ?? "iPhone mirror closed before the player window opened."
            return fallBackToCompatibilityMirror(udid: udid, deviceName: deviceName, startupError: startupError)
        }

        iosMirrorWindow.openIOSMirrorWindow(mirror: iosDeviceMirror, deviceName: deviceName, appState: self)
        return .compatibility
    }

    private func fallBackToCompatibilityMirror(udid: String, deviceName: String, startupError: String) -> IOSMirrorMode? {
        iosDeviceMirror.startFallbackMirroring(udid: udid, deviceName: deviceName)
        guard iosDeviceMirror.isMirroring else {
            showErrorNotification(startupError)
            return nil
        }
        iosMirrorWindow.openIOSMirrorWindow(mirror: iosDeviceMirror, deviceName: deviceName, appState: self)
        return .compatibility
    }

    /// Sets up (or reuses) the Android mirror, returning nil with an error
    /// notification when ADB is missing.
    private func preparedAndroidMirror() -> AndroidDeviceMirror? {
        if androidDeviceMirror == nil || androidDeviceMirror?.isMirroring == false {
            setupAndroidMirror()
        }
        guard let mirror = androidDeviceMirror else {
            showErrorNotification("ADB not installed. Install via Homebrew: brew install android-platform-tools")
            return nil
        }
        return mirror
    }

    func startDeviceMirroring(device: ConnectedDevice) async {
        switch device.platform {
        case .iOS:
            guard let udid = device.iosUDID else {
                showErrorNotification("iOS device not available")
                return
            }
            // If already mirroring, just reopen the window
            if iosDeviceMirror.isMirroring {
                if iosDeviceMirror.isLowLatencyMirroring {
                    iosDeviceMirror.bringLowLatencyMirrorWindowToFront()
                    showSavedNotification("iPhone mirror is already open in low-latency mode")
                } else {
                    iosMirrorWindow.openIOSMirrorWindow(mirror: iosDeviceMirror, deviceName: device.name, appState: self)
                    if iosDeviceMirror.isNativeMirroring {
                        showSavedNotification("iPhone mirror is already open in native mode")
                    }
                }
                return
            }

            switch await openIOSMirror(udid: udid, deviceName: device.name) {
            case .native:
                showSavedNotification("iPhone mirror opened in native low-latency mode")
            case .lowLatency:
                showSavedNotification("iPhone mirror opened in low-latency mode")
            case .compatibility:
                showSavedNotification("Opened iPhone mirror in compatibility mode")
            case nil:
                break
            }

        case .android:
            guard let mirror = preparedAndroidMirror() else { return }
            mirror.startMirroring(device: device)
            if mirror.isLowLatencyMirroring {
                showSavedNotification("Android mirror opened in low-latency mode")
            } else {
                androidMirrorWindow.openAndroidMirrorWindow(mirror: mirror, appState: self)
            }
        }
    }

    func startDeviceMirroringWithRecording(device: ConnectedDevice) async {
        switch device.platform {
        case .iOS:
            guard let udid = device.iosUDID else {
                showErrorNotification("iOS device not available")
                return
            }

            switch await openIOSMirror(udid: udid, deviceName: device.name) {
            case .native, .lowLatency:
                showSavedNotification("Use Start Recording and select the iPhone mirror window")
            case .compatibility:
                for _ in 0..<20 where iosDeviceMirror.currentFrame == nil {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                iosDeviceMirror.startRecording()
                if !iosDeviceMirror.isRecording {
                    showErrorNotification(iosDeviceMirror.errorMessage ?? "Failed to start iPhone recording")
                }
            case nil:
                break
            }

        case .android:
            guard let mirror = preparedAndroidMirror() else { return }
            mirror.startMirroring(device: device)
            if mirror.isLowLatencyMirroring {
                showSavedNotification("Use Start Recording and select the Android mirror window")
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                mirror.startRecording()
            }
            androidMirrorWindow.openAndroidMirrorWindow(mirror: mirror, appState: self)
        }
    }

    func takeDeviceScreenshot(device: ConnectedDevice) async {
        switch device.platform {
        case .iOS:
            if iosDeviceMirror.isMirroring {
                if let image = iosDeviceMirror.takeScreenshot() {
                    copyImageToClipboard(image)
                } else {
                    showErrorNotification("Failed to capture screenshot from iOS device")
                }
            } else {
                showErrorNotification("Start mirroring first to take a screenshot")
            }

        case .android:
            guard let mirror = androidDeviceMirror else {
                showErrorNotification("ADB not installed")
                return
            }
            if mirror.isMirroring, let image = mirror.takeScreenshot() {
                copyImageToClipboard(image)
            } else {
                showErrorNotification("Start mirroring first to take a screenshot")
            }
        }
    }

    func takeIOSDeviceScreenshot() async {
        guard iosDeviceMirror.isMirroring else { return }
        if let image = iosDeviceMirror.takeScreenshot() {
            presentAnnotationEditor(with: image)
        } else {
            showErrorNotification("Failed to capture screenshot")
        }
    }

    func showSavedNotification(_ message: String) {
        showSaveNotification(message)
    }

    func showError(_ message: String) {
        showErrorNotification(message)
    }

    // MARK: - Recording Actions

    func startRecording(mode: CaptureMode) async {
        guard await ensureReadyForCapture() else { return }
        configuration.mode = mode

        switch mode {
        case .fullScreen:
            await startEngineRecording()
        case .window:
            pendingCaptureAction = .recording
            showWindowSelection()
        case .area:
            pendingCaptureAction = .recording
            showAreaSelection()
        }
    }

    private func showWindowSelection() {
        windowSelectionController.showOverlay(
            onSelected: { [weak self] windowID in
                guard let self = self else { return }
                Task { @MainActor in
                    await self.onWindowSelected(windowID)
                }
            },
            onCancelled: { }
        )
    }

    private func onWindowSelected(_ windowID: CGWindowID) async {
        guard await ensureReadyForCapture() else {
            pendingCaptureAction = nil
            return
        }
        await captureEngine.refreshAvailableContent()

        // Brief delay to let the overlay disappear before capturing
        try? await Task.sleep(nanoseconds: 50_000_000)

        guard let scWindow = captureEngine.availableWindows.first(where: { $0.windowID == windowID }) else {
            showErrorNotification("Could not capture the selected window")
            pendingCaptureAction = nil
            return
        }

        if let action = pendingCaptureAction {
            pendingCaptureAction = nil

            switch action {
            case .recording:
                configuration.mode = .window
                configuration.selectedWindow = scWindow
                await startEngineRecording()
            case .screenshot:
                if let image = await screenshotService.captureWindow(scWindow) {
                    copyImageToClipboard(image)
                } else if let error = screenshotService.errorMessage {
                    showErrorNotification(error)
                }
            case .textCapture:
                break
            case .translateCapture:
                break
            }
        } else {
            if let image = await screenshotService.captureWindow(scWindow) {
                copyImageToClipboard(image)
            } else if let error = screenshotService.errorMessage {
                showErrorNotification(error)
            }
        }
    }

    private func showAreaSelection() {
        areaSelectionController.showOverlay(
            onSelected: { [weak self] rect in
                guard let self = self else { return }
                Task { @MainActor in
                    await self.onAreaSelected(rect)
                }
            },
            onCancelled: { [weak self] in
                Task { @MainActor in
                    self?.onAreaSelectionCancelled()
                }
            }
        )
    }

    func onAreaSelected(_ rect: CGRect) async {
        configuration.selectedArea = rect

        if let action = pendingCaptureAction {
            pendingCaptureAction = nil

            // Brief delay to let the overlay window fully disappear from the screen
            // before capturing, so it doesn't appear in the screenshot
            try? await Task.sleep(nanoseconds: 150_000_000)

            switch action {
            case .recording:
                configuration.mode = .area
                recordingAreaOverlayController.showOverlay(recordingRect: rect)
                await startEngineRecording()
            case .screenshot:
                await takeAreaScreenshot(area: rect)
            case .textCapture:
                await performTextCapture(area: rect)
            case .translateCapture:
                await performTranslateCapture(area: rect)
            }
        }
    }

    func onAreaSelectionCancelled() {
        pendingCaptureAction = nil
    }

    private func startEngineRecording() async {
        await captureEngine.startRecording()
        if captureEngine.state == .idle {
            recordingAreaOverlayController.closeOverlay()
            if let error = captureEngine.errorMessage {
                showErrorNotification(error)
            }
        }
    }

    func stopRecording() async {
        recordingAreaOverlayController.closeOverlay()
        if let url = await captureEngine.stopRecording() {
            await mediaLibrary.addRecording(at: url)
            showSaveNotification("Recording saved")
        } else if let error = captureEngine.errorMessage {
            showErrorNotification(error)
        }
    }

    func cancelRecording() async {
        recordingAreaOverlayController.closeOverlay()
        await captureEngine.cancelRecording()
    }

    // MARK: - Screenshot Actions

    private func ensureReadyForCapture() async -> Bool {
        guard permissionsManager.requestScreenRecordingPermission() else {
            showErrorNotification("Enable Screen & System Audio Recording for Captr in System Settings, then quit and reopen Captr.")
            return false
        }

        await captureEngine.refreshAvailableContent()
        if captureEngine.availableDisplays.isEmpty {
            showErrorNotification(captureEngine.errorMessage ?? "No displays found. Please check screen recording permission in System Settings.")
            return false
        }
        return true
    }

    func takeScreenshot(mode: CaptureMode) async {
        guard await ensureReadyForCapture() else { return }

        switch mode {
        case .fullScreen:
            await takeFullScreenScreenshot()
        case .window:
            pendingCaptureAction = .screenshot
            showWindowSelection()
        case .area:
            pendingCaptureAction = .screenshot
            showAreaSelection()
        }
    }

    func takeFullScreenScreenshot() async {
        guard await ensureReadyForCapture() else { return }

        let display = captureEngine.displayForFullScreenCapture()
        if let image = await screenshotService.captureFullScreen(display: display) {
            presentAnnotationEditor(with: image)
        } else if let error = screenshotService.errorMessage {
            showErrorNotification(error)
        }
    }

    func takeWindowScreenshot(_ window: SCWindow) async {
        guard await ensureReadyForCapture() else { return }

        if let image = await screenshotService.captureWindow(window) {
            presentAnnotationEditor(with: image)
        } else if let error = screenshotService.errorMessage {
            showErrorNotification(error)
        }
    }

    func takeAreaScreenshot(area: CGRect) async {
        guard await ensureReadyForCapture() else { return }

        let display = captureEngine.displayContaining(area)
            ?? configuration.selectedDisplay
            ?? captureEngine.availableDisplays.first
        if let image = await screenshotService.captureArea(display: display, area: area) {
            copyImageToClipboard(image)
        } else if let error = screenshotService.errorMessage {
            showErrorNotification(error)
        }
    }

    private func presentAnnotationEditor(with image: NSImage) {
        annotationImage = image
        annotationState = AnnotationState()
        showAnnotationEditor = true
        annotationWindowController.openAnnotationWindow(image: image, appState: self)
    }

    func saveAnnotatedScreenshot(_ image: NSImage) async {
        showAnnotationEditor = false
        annotationWindowController.closeWindow()
        if let url = screenshotService.saveScreenshot(image, annotated: annotationState.items.isEmpty == false) {
            await mediaLibrary.addScreenshot(at: url)
            showSaveNotification("Screenshot saved")
        }
        annotationImage = nil
    }

    func saveScreenshotWithoutAnnotation() async {
        showAnnotationEditor = false
        annotationWindowController.closeWindow()
        if let image = annotationImage {
            if let url = screenshotService.saveScreenshot(image, annotated: false) {
                await mediaLibrary.addScreenshot(at: url)
                showSaveNotification("Screenshot saved")
            }
        }
        annotationImage = nil
    }

    // MARK: - Text Capture Actions

    func startTextCapture() async {
        guard await ensureReadyForCapture() else { return }
        pendingCaptureAction = .textCapture
        showAreaSelection()
    }

    private func performTextCapture(area: CGRect) async {
        let display = captureEngine.displayContaining(area)
            ?? configuration.selectedDisplay
            ?? captureEngine.availableDisplays.first
        if let text = await textCaptureService.captureAndRecognizeArea(display: display, area: area) {
            TextCaptureService.copyToClipboard(text)
            showSaveNotification("Text copied to clipboard")
        } else {
            showErrorNotification(textCaptureService.errorMessage ?? "No text found in the selected area")
        }
    }

    func startTranslateCapture() async {
        guard await ensureReadyForCapture() else { return }
        // Mount the hidden translation panel while the user draws the
        // selection rectangle so the SwiftUI setup cost is hidden behind
        // their input.
        translationService.prewarm()
        pendingCaptureAction = .translateCapture
        showAreaSelection()
    }

    private func performTranslateCapture(area: CGRect) async {
        // Capture the screen area and run OCR first so we have an image to
        // drop into the overlay immediately — perceived latency stays tiny
        // while the translation step runs.
        let display = captureEngine.displayContaining(area)
            ?? configuration.selectedDisplay
            ?? captureEngine.availableDisplays.first
        guard let (cgImage, observations) = await textCaptureService.captureObservations(display: display, area: area) else {
            showErrorNotification(textCaptureService.errorMessage ?? "Failed to capture the selected area")
            return
        }

        let initialImage = NSImage(cgImage: cgImage, size: area.size)
        let engineName = translationService.currentEngineName
        translationOverlayController.showLoading(area: area, initialImage: initialImage, engineName: engineName)

        guard !observations.isEmpty else {
            translationOverlayController.showFailed(message: "No text detected") { [weak self] in
                Task { await self?.performTranslateCapture(area: area) }
            }
            return
        }

        var blocks = observations.compactMap {
            VisionTextBlock(observation: $0, imageWidth: cgImage.width, imageHeight: cgImage.height)
        }

        for i in blocks.indices {
            let sample = BackgroundColorSampler.sample(cgImage: cgImage, pixelRect: blocks[i].pixelRect)
            blocks[i].backgroundColor = sample.color
            blocks[i].isBackgroundDark = sample.isDark
        }

        // Detect source language from the concatenation of all segments so
        // per-segment text (often short) doesn't foil the recognizer.
        let joined = blocks.map(\.originalText).joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(joined)
        let source = Locale.Language(identifier: recognizer.dominantLanguage?.rawValue ?? "und")
        let target = Locale.Language(identifier: "en")

        do {
            let translated = try await translationService.translateBatch(blocks.map(\.originalText), from: source, to: target)
            for i in blocks.indices where i < translated.count {
                blocks[i].translatedText = translated[i]
            }
        } catch {
            translationOverlayController.showFailed(message: "Retry") { [weak self] in
                Task { await self?.performTranslateCapture(area: area) }
            }
            return
        }

        let composited = TranslationCompositor.composite(
            cgImage: cgImage,
            blocks: blocks,
            pointSize: area.size
        )
        translationOverlayController.showLoaded(composited: composited)
        translationOverlayController.setCopyAction { [weak self] in
            ClipboardService.copyImage(composited)
            self?.showSaveNotification("Copied to clipboard")
        }
        translationOverlayController.setSaveAction { [weak self] in
            Task { @MainActor in
                await self?.saveTranslationOverlay(composited)
            }
        }
    }

    private func saveTranslationOverlay(_ image: NSImage) async {
        if let url = screenshotService.saveScreenshot(image, annotated: true) {
            await mediaLibrary.addScreenshot(at: url)
            showSaveNotification("Translation saved")
        } else if let error = screenshotService.errorMessage {
            showErrorNotification(error)
        }
    }

    func captureScreenshot() async {
        guard await ensureReadyForCapture() else { return }

        switch screenshotMode {
        case .fullScreen:
            let display = captureEngine.displayForFullScreenCapture()
            if let image = await screenshotService.captureFullScreen(display: display) {
                copyImageToClipboard(image)
            } else if let error = screenshotService.errorMessage {
                showErrorNotification(error)
            }
        case .window:
            pendingCaptureAction = .screenshot
            showWindowSelection()
        case .area:
            pendingCaptureAction = .screenshot
            showAreaSelection()
        }
    }

    private func copyImageToClipboard(_ image: NSImage) {
        ClipboardService.copyImage(image)
        showSaveNotification("Screenshot copied to clipboard")
    }

    // MARK: - Notifications

    private func showSaveNotification(_ message: String) {
        showNotificationBanner(message: message, isError: false, duration: 3_000_000_000)
    }

    private func showErrorNotification(_ message: String) {
        showNotificationBanner(message: message, isError: true, duration: 5_000_000_000)
    }

    private func showNotificationBanner(message: String, isError: Bool, duration: UInt64) {
        notificationDismissTask?.cancel()
        notificationMessage = message
        notificationIsError = isError
        showNotification = true

        notificationDismissTask = Task {
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else { return }
            showNotification = false
        }
    }
}
