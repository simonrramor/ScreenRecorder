import Foundation
import SwiftUI
import ScreenCaptureKit
import Combine
import NaturalLanguage
import Translation
import OSLog

private let log = Logger(subsystem: "com.captr.app", category: "screenshot")

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

    @Published var selectedSidebarItem: SidebarItem = .home
    @Published var selectedMediaItem: MediaItem?
    @Published var pendingCaptureAction: CaptureType?

    // Capture UI state
    @Published var isVideoMode: Bool = false
    @Published var screenshotMode: CaptureMode = .area
    @Published var copyToClipboard: Bool = true
    @Published var screenshotTimerSeconds: Int = 0
    @Published var screenshotTimerRunning: Bool = false
    @Published var screenshotTimerRemaining: Int = 0
    private var screenshotTimerTask: Task<Void, Never>?

    @Published var showAnnotationEditor: Bool = false
    @Published var annotationImage: NSImage?
    @Published var annotationState = AnnotationState()

    @Published var showCountdown: Bool = false
    @Published var countdownValue: Int = 3

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

    enum SidebarItem: String, CaseIterable, Identifiable {
        case home = "Home"
        case allMedia = "All Media"
        case recordings = "Recordings"
        case screenshots = "Screenshots"
        case devices = "Devices"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .home: return "house.fill"
            case .allMedia: return "square.grid.2x2"
            case .recordings: return "video.fill"
            case .screenshots: return "photo.fill"
            case .devices: return "iphone.and.arrow.forward"
            }
        }

        static var libraryItems: [SidebarItem] {
            [.allMedia, .recordings, .screenshots]
        }
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

        deviceManagerCancellable = deviceManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        captureEngineCancellable = captureEngine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func setupAndroidMirror() {
        if let adb = deviceManager.adbPath {
            androidDeviceMirror = AndroidDeviceMirror(adbPath: adb)
        }
    }

    // MARK: - Device Mirroring Actions

    func startDeviceMirroring(device: ConnectedDevice) async {
        switch device.platform {
        case .iOS:
            guard let udid = device.iosUDID else {
                showErrorNotification("iOS device not available")
                return
            }
            // If already mirroring, just reopen the window
            if iosDeviceMirror.isMirroring {
                iosMirrorWindow.openIOSMirrorWindow(mirror: iosDeviceMirror, deviceName: device.name, appState: self)
                return
            }
            iosDeviceMirror.startMirroring(udid: udid, deviceName: device.name)
            if iosDeviceMirror.isMirroring {
                iosMirrorWindow.openIOSMirrorWindow(mirror: iosDeviceMirror, deviceName: device.name, appState: self)
            } else if let error = iosDeviceMirror.errorMessage {
                showErrorNotification(error)
            } else {
                showErrorNotification("Failed to start iOS mirroring")
            }

        case .android:
            guard let mirror = androidDeviceMirror else {
                setupAndroidMirror()
                guard androidDeviceMirror != nil else {
                    showErrorNotification("ADB not installed. Install via Homebrew: brew install android-platform-tools")
                    return
                }
                await startDeviceMirroring(device: device)
                return
            }
            mirror.startMirroring(device: device)
            androidMirrorWindow.openAndroidMirrorWindow(mirror: mirror, appState: self)
        }
    }

    func startDeviceMirroringWithRecording(device: ConnectedDevice) async {
        switch device.platform {
        case .iOS:
            guard let udid = device.iosUDID else {
                showErrorNotification("iOS device not available")
                return
            }
            iosDeviceMirror.startMirroring(udid: udid, deviceName: device.name)
            if iosDeviceMirror.isMirroring {
                iosMirrorWindow.openIOSMirrorWindow(mirror: iosDeviceMirror, deviceName: device.name, appState: self)
            }

        case .android:
            guard let mirror = androidDeviceMirror else {
                showErrorNotification("ADB not installed. Install via Homebrew: brew install android-platform-tools")
                return
            }
            mirror.startMirroring(device: device)
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

    // MARK: - Recording Actions

    func startRecording(mode: CaptureMode) async {
        guard await ensureReadyForCapture() else { return }
        configuration.mode = mode

        switch mode {
        case .fullScreen:
            await performCountdownAndRecord()
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
        guard await ensureReadyForCapture() else { return }
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
                await performCountdownAndRecord()
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
        log.info("onAreaSelected rect=\(String(describing:rect), privacy: .public) action=\(String(describing: self.pendingCaptureAction), privacy: .public)")
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
                await performCountdownAndRecord()
            case .screenshot:
                await takeAreaScreenshot(area: rect)
            case .textCapture:
                await performTextCapture(area: rect)
            case .translateCapture:
                await performTranslateCapture(area: rect)
            }
        } else {
            log.error("onAreaSelected fired with no pendingCaptureAction — silent exit")
        }
    }

    func onAreaSelectionCancelled() {
        pendingCaptureAction = nil
    }

    private func performCountdownAndRecord() async {
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
        if captureEngine.availableDisplays.isEmpty {
            await captureEngine.refreshAvailableContent()
        }
        if captureEngine.availableDisplays.isEmpty {
            showErrorNotification("No displays found. Please check screen recording permission in System Settings.")
            return false
        }
        return true
    }

    func takeScreenshot(mode: CaptureMode) async {
        switch mode {
        case .fullScreen:
            guard await ensureReadyForCapture() else { return }
            await takeFullScreenScreenshot()
        case .window:
            pendingCaptureAction = .screenshot
            showWindowSelection()
        case .area:
            // Show area selection immediately - no need to wait for display refresh
            pendingCaptureAction = .screenshot
            showAreaSelection()
        }
    }

    func takeFullScreenScreenshot() async {
        guard await ensureReadyForCapture() else { return }

        let display = configuration.selectedDisplay ?? captureEngine.availableDisplays.first
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
        log.info("takeAreaScreenshot enter area=\(String(describing:area), privacy: .public)")
        guard await ensureReadyForCapture() else {
            log.error("takeAreaScreenshot bailed: ensureReadyForCapture returned false")
            return
        }

        let display = captureEngine.displayContaining(area)
            ?? configuration.selectedDisplay
            ?? captureEngine.availableDisplays.first
        log.info("takeAreaScreenshot display=\(display?.displayID ?? 0, privacy: .public) (nil=\(display == nil, privacy: .public))")
        if let image = await screenshotService.captureArea(display: display, area: area) {
            log.info("takeAreaScreenshot got image size=\(String(describing:image.size), privacy: .public)")
            copyImageToClipboard(image)
        } else if let error = screenshotService.errorMessage {
            log.error("takeAreaScreenshot nil image, errorMessage=\(error, privacy: .public)")
            showErrorNotification(error)
        } else {
            log.error("takeAreaScreenshot nil image AND no errorMessage — silent exit")
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
        if let _ = screenshotService.saveScreenshot(image, annotated: annotationState.items.isEmpty == false) {
            await mediaLibrary.addScreenshot(at: MediaLibraryManager.screenshotsDirectory)
            showSaveNotification("Screenshot saved")
        }
        annotationImage = nil
    }

    func saveScreenshotWithoutAnnotation() async {
        showAnnotationEditor = false
        annotationWindowController.closeWindow()
        if let image = annotationImage {
            if let _ = screenshotService.saveScreenshot(image, annotated: false) {
                await mediaLibrary.addScreenshot(at: MediaLibraryManager.screenshotsDirectory)
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
        if screenshotService.saveScreenshot(image, annotated: true) != nil {
            await mediaLibrary.addScreenshot(at: MediaLibraryManager.screenshotsDirectory)
            showSaveNotification("Translation saved")
        } else if let error = screenshotService.errorMessage {
            showErrorNotification(error)
        }
    }

    // MARK: - Screenshot Timer

    func startScreenshotTimer() {
        guard screenshotTimerSeconds > 0 else {
            Task { await captureScreenshot() }
            return
        }
        screenshotTimerRemaining = screenshotTimerSeconds
        screenshotTimerRunning = true
        screenshotTimerTask = Task {
            while screenshotTimerRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                screenshotTimerRemaining -= 1
            }
            screenshotTimerRunning = false
            await captureScreenshot()
        }
    }

    func resetScreenshotTimer() {
        screenshotTimerTask?.cancel()
        screenshotTimerTask = nil
        screenshotTimerRunning = false
        screenshotTimerRemaining = 0
    }

    func captureScreenshot() async {
        switch screenshotMode {
        case .fullScreen:
            guard await ensureReadyForCapture() else { return }
            let display = configuration.selectedDisplay ?? captureEngine.availableDisplays.first
            if let image = await screenshotService.captureFullScreen(display: display) {
                copyImageToClipboard(image)
            } else if let error = screenshotService.errorMessage {
                showErrorNotification(error)
            }
        case .window:
            pendingCaptureAction = .screenshot
            showWindowSelection()
        case .area:
            // Show area selection immediately - no need to wait for display refresh
            pendingCaptureAction = .screenshot
            showAreaSelection()
        }
    }

    private func copyImageToClipboard(_ image: NSImage) {
        let before = NSPasteboard.general.changeCount
        log.info("copyImageToClipboard enter changeCount.before=\(before, privacy: .public)")
        ClipboardService.copyImage(image)
        let after = NSPasteboard.general.changeCount
        log.info("copyImageToClipboard done changeCount.after=\(after, privacy: .public) wrote=\(after > before, privacy: .public)")
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
