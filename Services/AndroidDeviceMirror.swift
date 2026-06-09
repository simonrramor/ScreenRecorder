import Foundation
import AppKit
import SwiftUI

// Continuous frame grabber using ADB screencap
class AndroidFrameGrabber: @unchecked Sendable {
    private let adbPath: String
    private let serial: String
    private let lock = NSLock()
    private var _isRunning = false

    private var isRunning: Bool {
        get { lock.withLock { _isRunning } }
        set { lock.withLock { _isRunning = newValue } }
    }

    // Delivers raw PNG data; image creation must happen on the main thread
    var onFrameData: ((Data) -> Void)?

    init(adbPath: String, serial: String) {
        self.adbPath = adbPath
        self.serial = serial
    }

    func start() {
        isRunning = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            // Cap the screencap fallback at ~10 fps; an unthrottled loop of
            // adb launches pins a core for no visible benefit.
            let minFrameInterval: TimeInterval = 0.1
            while self?.isRunning == true {
                let start = CFAbsoluteTimeGetCurrent()
                self?.captureFrame()
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                if elapsed < minFrameInterval {
                    Thread.sleep(forTimeInterval: minFrameInterval - elapsed)
                }
            }
        }
    }

    func stop() {
        isRunning = false
    }

    private func captureFrame() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, "exec-out", "screencap", "-p"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        var allData = Data()
        let fileHandle = pipe.fileHandleForReading

        do {
            try process.run()
        } catch {
            return
        }

        // Read data in chunks to prevent pipe buffer from blocking the process
        while true {
            let chunk = fileHandle.availableData
            if chunk.isEmpty { break }
            allData.append(chunk)
        }

        process.waitUntilExit()

        guard allData.count > 100 else { return }

        onFrameData?(allData)
    }
}

// Input forwarding via ADB shell input
class AndroidInputHandler: @unchecked Sendable {
    private let adbPath: String
    private let serial: String

    init(adbPath: String, serial: String) {
        self.adbPath = adbPath
        self.serial = serial
    }

    func tap(viewPoint: CGPoint, viewSize: CGSize, deviceSize: CGSize) {
        let x = Int(viewPoint.x / viewSize.width * deviceSize.width)
        let y = Int(viewPoint.y / viewSize.height * deviceSize.height)
        runAdb("shell", "input", "tap", "\(x)", "\(y)")
    }

    func swipe(from: CGPoint, to: CGPoint, viewSize: CGSize, deviceSize: CGSize, duration: Int = 300) {
        let x1 = Int(from.x / viewSize.width * deviceSize.width)
        let y1 = Int(from.y / viewSize.height * deviceSize.height)
        let x2 = Int(to.x / viewSize.width * deviceSize.width)
        let y2 = Int(to.y / viewSize.height * deviceSize.height)
        runAdb("shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(duration)")
    }

    func keyEvent(_ code: Int) {
        runAdb("shell", "input", "keyevent", "\(code)")
    }

    func text(_ text: String) {
        // `input text` runs through the device shell: spaces map to %s and
        // shell metacharacters must be backslash-escaped or they get eaten
        // (or worse, interpreted) on the device side.
        var escaped = ""
        for character in text {
            switch character {
            case " ":
                escaped += "%s"
            case "\\", "\"", "'", "`", "$", "&", "|", ";", "(", ")", "<", ">", "*", "?", "~", "#":
                escaped += "\\\(character)"
            default:
                escaped.append(character)
            }
        }
        runAdb("shell", "input", "text", escaped)
    }

    private func runAdb(_ args: String...) {
        DispatchQueue.global().async { [self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: self.adbPath)
            process.arguments = ["-s", self.serial] + args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }
}

@MainActor
class AndroidDeviceMirror: ObservableObject {
    @Published var isMirroring = false
    @Published var isLowLatencyMirroring = false
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var currentFrame: NSImage?
    @Published var errorMessage: String?
    @Published var mirroringDeviceName: String = ""
    @Published var deviceResolution: CGSize = CGSize(width: 1080, height: 2400)

    /// Android's screenrecord hard-stops at its 3-minute cap. When that
    /// happens mid-recording this fires (on the main actor) so the owner can
    /// finalize the recording instead of letting the timer run forever.
    var onRecordingAutoStopped: (() -> Void)?

    let adbPath: String
    private let scrcpyPath: String?
    private var frameGrabber: AndroidFrameGrabber?
    private var scrcpyProcess: Process?
    private(set) var inputHandler: AndroidInputHandler?
    private var recordingProcess: Process?
    private var deviceSerial: String?
    private var durationTimer: Timer?
    private var recordingStartDate: Date?
    private var mirroringDevice: ConnectedDevice?

    init(adbPath: String, scrcpyPath: String? = nil) {
        self.adbPath = adbPath
        self.scrcpyPath = scrcpyPath
    }

    func startMirroring(device: ConnectedDevice) {
        guard !isMirroring, let serial = device.adbSerial else { return }
        errorMessage = nil
        deviceSerial = serial
        mirroringDeviceName = device.name
        mirroringDevice = device

        if let scrcpyPath {
            startScrcpyMirroring(device: device, serial: serial, scrcpyPath: scrcpyPath)
            if isMirroring {
                return
            }
        }

        // Fetch device resolution
        Task.detached { [weak self] in
            guard let self = self else { return }
            let output = DeviceManager.runCommand(self.adbPath, arguments: ["-s", serial, "shell", "wm", "size"])
            if let match = output.range(of: #"\d+x\d+"#, options: .regularExpression) {
                let sizeStr = String(output[match])
                let parts = sizeStr.split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                    await MainActor.run { [weak self] in
                        self?.deviceResolution = CGSize(width: w, height: h)
                    }
                }
            }
        }

        // Start frame grabber - create NSImage on the main thread to avoid
        // cross-thread retain/release issues with Core Animation layers
        let grabber = AndroidFrameGrabber(adbPath: adbPath, serial: serial)
        grabber.onFrameData = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self = self, self.isMirroring else { return }
                if let image = NSImage(data: data) {
                    self.currentFrame = image
                }
            }
        }
        grabber.start()
        frameGrabber = grabber

        // Create input handler
        inputHandler = AndroidInputHandler(adbPath: adbPath, serial: serial)

        isMirroring = true
    }

    func stopMirroring() {
        stopScrcpyMirroring()

        frameGrabber?.stop()
        frameGrabber = nil
        inputHandler = nil

        if isRecording {
            stopRecordingOnDevice()
            isRecording = false
            stopDurationTimer()
        }

        isMirroring = false
        isLowLatencyMirroring = false
        currentFrame = nil
        mirroringDeviceName = ""
        deviceSerial = nil
        mirroringDevice = nil
    }

    func startRecording() {
        guard isMirroring, !isRecording, let serial = deviceSerial else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        // No --size: forcing 1280x720 distorts portrait devices. screenrecord
        // picks the native display resolution on its own.
        process.arguments = ["-s", serial, "shell", "screenrecord", "/sdcard/mirror_recording.mp4"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor [weak self, weak process] in
                guard let self, let process,
                      self.recordingProcess === process,
                      self.isRecording else { return }
                self.onRecordingAutoStopped?()
            }
        }

        do {
            try process.run()
            recordingProcess = process
            isRecording = true
            recordingStartDate = Date()
            startDurationTimer()
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() async -> URL? {
        guard isRecording, let serial = deviceSerial else { return nil }
        isRecording = false
        stopDurationTimer()

        stopRecordingOnDevice()

        // Wait for recording to finalize on device
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Pull file from device
        let outputDir = MediaLibraryManager.recordingsDirectory
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let fileName = "Android Device \(Date().screenRecorderFileName).mp4"
        let localURL = outputDir.appendingPathComponent(fileName)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { [self] in
                let pullProcess = Process()
                pullProcess.executableURL = URL(fileURLWithPath: self.adbPath)
                pullProcess.arguments = ["-s", serial, "pull", "/sdcard/mirror_recording.mp4", localURL.path]
                pullProcess.standardOutput = Pipe()
                pullProcess.standardError = Pipe()
                try? pullProcess.run()
                pullProcess.waitUntilExit()

                let rmProcess = Process()
                rmProcess.executableURL = URL(fileURLWithPath: self.adbPath)
                rmProcess.arguments = ["-s", serial, "shell", "rm", "-f", "/sdcard/mirror_recording.mp4"]
                rmProcess.standardOutput = Pipe()
                rmProcess.standardError = Pipe()
                try? rmProcess.run()
                rmProcess.waitUntilExit()

                continuation.resume()
            }
        }

        guard FileManager.default.fileExists(atPath: localURL.path) else {
            errorMessage = "Failed to pull the recording from the device."
            return nil
        }
        return localURL
    }

    func takeScreenshot() -> NSImage? {
        if currentFrame == nil {
            currentFrame = captureScreencapFrame()
        }
        return currentFrame
    }

    func handleTap(at point: CGPoint, viewSize: CGSize) {
        inputHandler?.tap(viewPoint: point, viewSize: viewSize, deviceSize: deviceResolution)
    }

    func handleSwipe(from: CGPoint, to: CGPoint, viewSize: CGSize) {
        inputHandler?.swipe(from: from, to: to, viewSize: viewSize, deviceSize: deviceResolution)
    }

    func sendBack() {
        inputHandler?.keyEvent(4)
    }

    func sendHome() {
        inputHandler?.keyEvent(3)
    }

    func sendRecents() {
        inputHandler?.keyEvent(187)
    }

    private func stopRecordingOnDevice() {
        guard let serial = deviceSerial else { return }
        DispatchQueue.global().async { [self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: self.adbPath)
            process.arguments = ["-s", serial, "shell", "pkill", "-2", "screenrecord"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
        recordingProcess = nil
    }

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.recordingStartDate else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingDuration = 0
        recordingStartDate = nil
    }

    private func startScrcpyMirroring(device: ConnectedDevice, serial: String, scrcpyPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scrcpyPath)
        process.arguments = [
            "--serial", serial,
            "--window-title", "Captr Android - \(device.name)",
            "--video-buffer=0",
            "--video-bit-rate=12M",
            "--max-fps=60",
            "--max-size=1280",
            "--video-codec=h264",
            "--no-audio",
            "--no-mouse-hover",
            "--always-on-top"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor [weak self, weak process] in
                guard let self else { return }
                if let process, self.scrcpyProcess === process {
                    self.scrcpyProcess = nil
                    self.isLowLatencyMirroring = false
                    self.isMirroring = false
                    self.mirroringDeviceName = ""
                    self.deviceSerial = nil
                    self.mirroringDevice = nil
                }
            }
        }

        do {
            try process.run()
            scrcpyProcess = process
            inputHandler = AndroidInputHandler(adbPath: adbPath, serial: serial)
            isLowLatencyMirroring = true
            isMirroring = true
            bringExternalMirrorWindowToFront(process)
        } catch {
            self.errorMessage = "Failed to start scrcpy: \(error.localizedDescription)"
            isLowLatencyMirroring = false
            isMirroring = false
        }
    }

    private func stopScrcpyMirroring() {
        guard let process = scrcpyProcess else { return }
        scrcpyProcess = nil
        if process.isRunning {
            process.terminate()
        }
    }

    private func captureScreencapFrame() -> NSImage? {
        guard let serial = deviceSerial else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, "exec-out", "screencap", "-p"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard data.count > 100 else { return nil }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    private func bringExternalMirrorWindowToFront(_ process: Process) {
        let processIdentifier = process.processIdentifier
        Task { @MainActor in
            for delay in [100_000_000, 300_000_000, 700_000_000, 1_200_000_000] {
                try? await Task.sleep(nanoseconds: UInt64(delay))
                NSRunningApplication(processIdentifier: processIdentifier)?
                    .activate(options: [.activateAllWindows])
            }
        }
    }
}

// Pure SwiftUI display for Android device mirror with touch input
struct AndroidMirrorDisplayView: View {
    let image: NSImage?
    let onTap: (CGPoint, CGSize) -> Void
    let onSwipe: (CGPoint, CGPoint, CGSize) -> Void

    @State private var dragStart: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let nsImage = image {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if value.translation == .zero {
                                        dragStart = value.startLocation
                                    }
                                }
                                .onEnded { value in
                                    let imageSize = nsImage.size
                                    let viewSize = geo.size

                                    let startPt = mapToImage(point: dragStart, viewSize: viewSize, imageSize: imageSize)
                                    let endPt = mapToImage(point: value.location, viewSize: viewSize, imageSize: imageSize)

                                    guard let s = startPt, let e = endPt else { return }

                                    let dist = sqrt(pow(e.x - s.x, 2) + pow(e.y - s.y, 2))
                                    if dist < 15 {
                                        onTap(s, imageSize)
                                    } else {
                                        onSwipe(s, e, imageSize)
                                    }
                                }
                        )
                }
            }
        }
    }

    private func mapToImage(point: CGPoint, viewSize: CGSize, imageSize: CGSize) -> CGPoint? {
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height

        var imageRect: CGRect
        if imageAspect > viewAspect {
            let height = viewSize.width / imageAspect
            imageRect = CGRect(x: 0, y: (viewSize.height - height) / 2, width: viewSize.width, height: height)
        } else {
            let width = viewSize.height * imageAspect
            imageRect = CGRect(x: (viewSize.width - width) / 2, y: 0, width: width, height: viewSize.height)
        }

        guard imageRect.contains(point) else { return nil }

        let relX = (point.x - imageRect.origin.x) / imageRect.width
        let relY = (point.y - imageRect.origin.y) / imageRect.height

        return CGPoint(x: relX * imageSize.width, y: relY * imageSize.height)
    }
}
