import Foundation
import SwiftUI
import AppKit
import ScreenCaptureKit
import Combine
import NaturalLanguage
import Translation

@MainActor
class AppState: ObservableObject {
    private enum Defaults {
        static let useFastIOSMirroring = "useFastIOSMirroring"
    }

    private let userDefaults: UserDefaults
    private let fastIOSMirroringAllowed: Bool

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
    private var hasInitialized = false

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
    @Published private(set) var useFastIOSMirroring: Bool {
        didSet {
            userDefaults.set(useFastIOSMirroring, forKey: Defaults.useFastIOSMirroring)
        }
    }
    private var notificationDismissTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var translationOperationID: UUID?
    private var preparedAreaCapture: ScreenshotService.PreparedAreaCapture?

    private let areaSelectionController = AreaSelectionWindowController()
    private let windowSelectionController = WindowSelectionWindowController()
    private let recordingAreaOverlayController = RecordingAreaOverlayController()
    let annotationWindowController = AnnotationWindowController()
    let translationOverlayController = TranslationOverlayController()
    lazy var translationService = TranslationService(settings: translationSettings)
    var keyboardShortcutManager: KeyboardShortcutManager?

    init(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.userDefaults = userDefaults
        self.fastIOSMirroringAllowed = IOSDeviceMirror.nativeLowLatencyMirroringEnabled(environment: environment)

        if let storedPreference = userDefaults.object(forKey: Defaults.useFastIOSMirroring) as? Bool {
            self.useFastIOSMirroring = fastIOSMirroringAllowed ? storedPreference : false
            if storedPreference && !fastIOSMirroringAllowed {
                userDefaults.set(false, forKey: Defaults.useFastIOSMirroring)
            }
        } else {
            self.useFastIOSMirroring = fastIOSMirroringAllowed
        }
    }

    var canUseFastIOSMirroring: Bool {
        fastIOSMirroringAllowed
    }

    func setFastIOSMirroring(_ enabled: Bool) {
        guard !enabled || canUseFastIOSMirroring else {
            if useFastIOSMirroring {
                useFastIOSMirroring = false
            }
            showErrorNotification("Fast iOS mirroring is disabled in this build because macOS native iPhone capture is crashing. Stable mode is still available.")
            return
        }

        guard useFastIOSMirroring != enabled else { return }
        useFastIOSMirroring = enabled

        if iosDeviceMirror.isMirroring {
            showSavedNotification("Restart iPhone mirror to apply \(enabled ? "Fast" : "Stable") mode")
        }
    }

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
        guard !hasInitialized else { return }
        // Set before the first suspension so a second WindowGroup onAppear
        // cannot start another initialization pass while this one is waiting.
        hasInitialized = true

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
        iosDeviceMirror.onMirroringEnded = { [weak self] message in
            guard let self else { return }
            self.iosMirrorWindow.closeWindow()
            if let message {
                self.showErrorNotification(message)
            }
        }
        screenParametersCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.preparedAreaCapture = nil
                    await self?.captureEngine.refreshAvailableContent()
                }
            }
    }

    private func setupAndroidMirror() {
        guard androidDeviceMirror == nil else { return }
        guard let adb = deviceManager.adbPath else { return }

        let mirror = AndroidDeviceMirror(adbPath: adb)
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

    /// Drives the iOS button's spinner: device discovery plus native-feed
    /// startup can take several seconds.
    @Published var isStartingIOSMirror = false

    func startFirstAvailableIOSMirroring() async {
        guard !isStartingIOSMirror else { return }
        isStartingIOSMirror = true
        defer { isStartingIOSMirror = false }

        let device: ConnectedDevice?
        if let connectedDevice = deviceManager.iosDevices.first {
            device = connectedDevice
        } else {
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

        let device: ConnectedDevice?
        if let connectedDevice = deviceManager.androidDevices.first {
            device = connectedDevice
        } else {
            device = await deviceManager.refreshAndroidDevicesNow().first
        }

        guard let device else {
            showErrorNotification("Connect your Android by cable, enable USB debugging, and allow the trust prompt.")
            return
        }

        await startDeviceMirroring(device: device)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// How an iOS mirror ended up on screen after running the transport
    /// ladder (safe screenshot streaming → opt-in native low latency).
    private enum IOSMirrorMode {
        case lowLatency
        case compatibility
    }

    /// Runs the iOS mirror transport ladder shared by plain mirroring and
    /// mirror-with-recording. Returns the mode that ended up active, or nil
    /// when everything failed (an error notification was already shown).
    private func openIOSMirror(udid: String, deviceName: String) async -> IOSMirrorMode? {
        if iosDeviceMirror.isMirroring {
            iosMirrorWindow.openIOSMirrorWindow(mirror: iosDeviceMirror, deviceName: deviceName, appState: self)
            return iosDeviceMirror.isLowLatencyMirroring ? .lowLatency : .compatibility
        }

        guard canUseFastIOSMirroring, useFastIOSMirroring else {
            return openCompatibilityIOSMirror(udid: udid, deviceName: deviceName)
        }

        return await openNativeIOSMirror(udid: udid, deviceName: deviceName)
    }

    private func openNativeIOSMirror(udid: String, deviceName: String) async -> IOSMirrorMode? {
        if !iosDeviceMirror.isMirroring {
            iosDeviceMirror.startMirroring(udid: udid, deviceName: deviceName)
        }
        guard iosDeviceMirror.isMirroring else {
            showErrorNotification(iosDeviceMirror.errorMessage ?? "Failed to start iOS mirroring")
            return nil
        }

        if iosDeviceMirror.isLowLatencyMirroring {
            if await iosDeviceMirror.waitForLowLatencyStartup() {
                iosMirrorWindow.openIOSMirrorWindow(mirror: iosDeviceMirror, deviceName: deviceName, appState: self)
                return .lowLatency
            }
            let startupError = iosDeviceMirror.errorMessage ?? "The live iPhone screen feed failed to start."
            return fallBackToCompatibilityMirror(udid: udid, deviceName: deviceName, startupError: startupError)
        }

        iosMirrorWindow.openIOSMirrorWindow(mirror: iosDeviceMirror, deviceName: deviceName, appState: self)
        return .compatibility
    }

    private func fallBackToCompatibilityMirror(udid: String, deviceName: String, startupError: String) -> IOSMirrorMode? {
        let compatibilityMode = openCompatibilityIOSMirror(udid: udid, deviceName: deviceName)
        if compatibilityMode == nil {
            showErrorNotification(startupError)
        }
        return compatibilityMode
    }

    private func openCompatibilityIOSMirror(udid: String, deviceName: String) -> IOSMirrorMode? {
        iosDeviceMirror.startFallbackMirroring(udid: udid, deviceName: deviceName)
        guard iosDeviceMirror.isMirroring else {
            showErrorNotification(iosDeviceMirror.errorMessage ?? "Failed to start iOS mirroring")
            return nil
        }
        iosMirrorWindow.openIOSMirrorWindow(mirror: iosDeviceMirror, deviceName: deviceName, appState: self)
        return .compatibility
    }

    /// Sets up (or reuses) the Android mirror, returning nil with an error
    /// notification when ADB is missing.
    private func preparedAndroidMirror() -> AndroidDeviceMirror? {
        if androidDeviceMirror == nil {
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
                iosMirrorWindow.openIOSMirrorWindow(mirror: iosDeviceMirror, deviceName: device.name, appState: self)
                return
            }

            switch await openIOSMirror(udid: udid, deviceName: device.name) {
            case .lowLatency:
                showSavedNotification("iPhone mirror opened in Fast mode")
            case .compatibility:
                showSavedNotification("iPhone mirror opened in Stable mode")
            case nil:
                break
            }

        case .android:
            guard let mirror = preparedAndroidMirror() else { return }
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

            switch await openIOSMirror(udid: udid, deviceName: device.name) {
            case .lowLatency:
                iosDeviceMirror.startRecording()
                if !iosDeviceMirror.isRecording {
                    showErrorNotification(iosDeviceMirror.errorMessage ?? "Failed to start iPhone recording")
                }
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

    func disconnectIOSMirror() async {
        if iosDeviceMirror.isRecording {
            if let url = await iosDeviceMirror.stopRecording() {
                await mediaLibrary.addRecording(at: url)
                showSavedNotification("iPhone recording saved")
            } else {
                showErrorNotification(iosDeviceMirror.errorMessage ?? "iPhone recording could not be saved")
            }
        }
        iosDeviceMirror.stopMirroring()
        iosMirrorWindow.closeWindow()
    }

    func disconnectAndroidMirror() async {
        guard let mirror = androidDeviceMirror else {
            androidMirrorWindow.closeWindow()
            return
        }
        if mirror.isRecording || mirror.isFinalizingRecording {
            if let url = await mirror.stopRecording() {
                await mediaLibrary.addRecording(at: url)
                showSavedNotification("Android recording saved")
            } else {
                showErrorNotification(mirror.errorMessage ?? "Android recording could not be saved")
            }
        }
        mirror.stopMirroring()
        androidMirrorWindow.closeWindow()
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
            preparedAreaCapture = nil
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
        let capturePreparedBeforeSelection = preparedAreaCapture
        preparedAreaCapture = nil

        if let action = pendingCaptureAction {
            pendingCaptureAction = nil

            switch action {
            case .recording:
                configuration.mode = .area
                recordingAreaOverlayController.showOverlay(recordingRect: rect)
                await startEngineRecording()
            case .screenshot:
                await takeAreaScreenshot(
                    area: rect,
                    preparedCapture: capturePreparedBeforeSelection
                )
            case .textCapture:
                await performTextCapture(
                    area: rect,
                    preparedCapture: capturePreparedBeforeSelection
                )
            case .translateCapture:
                beginTranslation(
                    area: rect,
                    preparedCapture: capturePreparedBeforeSelection
                )
            }
        }
    }

    func onAreaSelectionCancelled() {
        preparedAreaCapture = nil
        pendingCaptureAction = nil
    }

    func shutdown() {
        notificationDismissTask?.cancel()
        notificationDismissTask = nil
        deviceManager.stopMonitoring()
        keyboardShortcutManager?.shutdown()
        keyboardShortcutManager = nil
        preparedAreaCapture = nil
        areaSelectionController.closeOverlay()
        windowSelectionController.closeOverlay()
        recordingAreaOverlayController.closeOverlay()
        cancelTranslationOperation(closeOverlay: true)
        annotationWindowController.closeWindow()
    }

    private func startEngineRecording() async {
        if configuration.captureMicrophone {
            let microphoneGranted = await permissionsManager.requestMicrophonePermission()
            guard microphoneGranted else {
                recordingAreaOverlayController.closeOverlay()
                showErrorNotification("Microphone access is required when microphone recording is enabled.")
                return
            }
        }
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

    /// Enumerates ScreenCaptureKit once before the selector appears, then
    /// derives every display filter from that exact snapshot. The resulting
    /// filters can be used immediately after mouse-up without another window
    /// enumeration, closing the race where the user could switch screens
    /// before the screenshot request was issued.
    private func makePreparedAreaCapture() async -> ScreenshotService.PreparedAreaCapture? {
        guard permissionsManager.requestScreenRecordingPermission() else {
            showErrorNotification("Enable Screen & System Audio Recording for Captr in System Settings, then quit and reopen Captr.")
            return nil
        }

        guard let content = await captureEngine.refreshAvailableContent(onScreenWindowsOnly: false),
              !captureEngine.availableDisplays.isEmpty,
              let preparedCapture = ScreenshotService.prepareAreaCapture(from: content) else {
            showErrorNotification(captureEngine.errorMessage ?? "No displays found. Please check screen recording permission in System Settings.")
            return nil
        }
        return preparedCapture
    }

    private func prepareAreaSelection() async -> Bool {
        preparedAreaCapture = nil
        guard let preparedCapture = await makePreparedAreaCapture() else {
            return false
        }
        self.preparedAreaCapture = preparedCapture
        return true
    }

    func takeScreenshot(mode: CaptureMode) async {
        switch mode {
        case .fullScreen:
            await takeFullScreenScreenshot()
        case .window:
            guard await ensureReadyForCapture() else { return }
            pendingCaptureAction = .screenshot
            showWindowSelection()
        case .area:
            guard await prepareAreaSelection() else { return }
            pendingCaptureAction = .screenshot
            showAreaSelection()
        }
    }

    /// Hides the area-recording border/dimming while a screenshot or OCR
    /// capture reads the screen, so captures taken mid-recording stay clean.
    private func withRecordingOverlayHidden<T>(_ body: () async -> T) async -> T {
        recordingAreaOverlayController.setHiddenForCapture(true)
        defer { recordingAreaOverlayController.setHiddenForCapture(false) }
        return await body()
    }

    func takeFullScreenScreenshot() async {
        guard await ensureReadyForCapture() else { return }

        let display = captureEngine.displayForFullScreenCapture()
        if let image = await withRecordingOverlayHidden({ await self.screenshotService.captureFullScreen(display: display) }) {
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

    func takeAreaScreenshot(
        area: CGRect,
        preparedCapture: ScreenshotService.PreparedAreaCapture? = nil
    ) async {
        let capture: ScreenshotService.PreparedAreaCapture
        if let preparedCapture {
            capture = preparedCapture
        } else {
            guard let newlyPreparedCapture = await makePreparedAreaCapture() else { return }
            capture = newlyPreparedCapture
        }

        if let image = await withRecordingOverlayHidden({
            await self.screenshotService.captureArea(
                preparedCapture: capture,
                area: area
            )
        }) {
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
        guard await prepareAreaSelection() else { return }
        pendingCaptureAction = .textCapture
        showAreaSelection()
    }

    private func performTextCapture(
        area: CGRect,
        preparedCapture: ScreenshotService.PreparedAreaCapture?
    ) async {
        let display = preparedCapture == nil
            ? captureEngine.displayContaining(area) ?? configuration.selectedDisplay ?? captureEngine.availableDisplays.first
            : nil
        if let text = await withRecordingOverlayHidden({
            await self.textCaptureService.captureAndRecognizeArea(
                display: display,
                preparedCapture: preparedCapture,
                area: area
            )
        }) {
            TextCaptureService.copyToClipboard(text)
            showSaveNotification("Text copied to clipboard")
        } else {
            showErrorNotification(textCaptureService.errorMessage ?? "No text found in the selected area")
        }
    }

    func startTranslateCapture() async {
        guard await prepareAreaSelection() else { return }
        cancelTranslationOperation(closeOverlay: true)
        // Mount the hidden translation panel while the user draws the
        // selection rectangle so the SwiftUI setup cost is hidden behind
        // their input.
        translationService.prewarm()
        pendingCaptureAction = .translateCapture
        showAreaSelection()
    }

    private func beginTranslation(
        area: CGRect,
        preparedCapture: ScreenshotService.PreparedAreaCapture? = nil
    ) {
        cancelTranslationOperation(closeOverlay: true)
        let operationID = UUID()
        translationOperationID = operationID
        translationTask = Task { [weak self] in
            guard let self else { return }
            await self.performTranslateCapture(
                area: area,
                preparedCapture: preparedCapture,
                operationID: operationID
            )
            if self.translationOperationID == operationID {
                self.translationTask = nil
            }
        }
    }

    private func cancelTranslationOperation(closeOverlay: Bool) {
        translationOperationID = nil
        translationTask?.cancel()
        translationTask = nil
        if closeOverlay {
            translationOverlayController.close(notify: false)
        }
    }

    private func isCurrentTranslation(_ operationID: UUID) -> Bool {
        translationOperationID == operationID && !Task.isCancelled
    }

    private func performTranslateCapture(
        area: CGRect,
        preparedCapture: ScreenshotService.PreparedAreaCapture?,
        operationID: UUID
    ) async {
        // Capture the screen area and run OCR first so we have an image to
        // drop into the overlay immediately — perceived latency stays tiny
        // while the translation step runs.
        let display = preparedCapture == nil
            ? captureEngine.displayContaining(area) ?? configuration.selectedDisplay ?? captureEngine.availableDisplays.first
            : nil
        guard let (cgImage, observations) = await withRecordingOverlayHidden({
            await self.textCaptureService.captureObservations(
                display: display,
                preparedCapture: preparedCapture,
                area: area
            )
        }) else {
            guard isCurrentTranslation(operationID) else { return }
            showErrorNotification(textCaptureService.errorMessage ?? "Failed to capture the selected area")
            return
        }
        guard isCurrentTranslation(operationID) else { return }

        let initialImage = NSImage(cgImage: cgImage, size: area.size)
        let engineName = translationService.currentEngineName
        translationOverlayController.showLoading(area: area, initialImage: initialImage, engineName: engineName)
        translationOverlayController.setCloseAction { [weak self] in
            guard self?.translationOperationID == operationID else { return }
            self?.cancelTranslationOperation(closeOverlay: false)
        }

        guard !observations.isEmpty else {
            translationOverlayController.showFailed(message: "No text detected") { [weak self] in
                self?.beginTranslation(area: area)
            }
            return
        }

        var blocks = observations.compactMap {
            VisionTextBlock(region: $0, imageWidth: cgImage.width, imageHeight: cgImage.height)
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
            guard isCurrentTranslation(operationID) else { return }
            for i in blocks.indices where i < translated.count {
                blocks[i].translatedText = translated[i]
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentTranslation(operationID) else { return }
            translationOverlayController.showFailed(message: error.localizedDescription) { [weak self] in
                self?.beginTranslation(area: area)
            }
            return
        }

        guard isCurrentTranslation(operationID) else { return }

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
        switch screenshotMode {
        case .fullScreen:
            guard await ensureReadyForCapture() else { return }
            let display = captureEngine.displayForFullScreenCapture()
            if let image = await withRecordingOverlayHidden({ await self.screenshotService.captureFullScreen(display: display) }) {
                copyImageToClipboard(image)
            } else if let error = screenshotService.errorMessage {
                showErrorNotification(error)
            }
        case .window:
            guard await ensureReadyForCapture() else { return }
            pendingCaptureAction = .screenshot
            showWindowSelection()
        case .area:
            guard await prepareAreaSelection() else { return }
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
