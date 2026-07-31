import Foundation
import AppKit
import SwiftUI

// Continuous frame grabber using ADB screencap
@MainActor
final class AndroidFrameGrabber {
    private let adbPath: String
    private let serial: String
    private var captureTask: Task<Void, Never>?

    // Delivers raw PNG data; image creation must happen on the main thread
    var onFrameData: ((Data) -> Void)?

    init(adbPath: String, serial: String) {
        self.adbPath = adbPath
        self.serial = serial
    }

    func start() {
        guard captureTask == nil else { return }
        let adbPath = adbPath
        let serial = serial
        captureTask = Task { [weak self] in
            // Cap the screencap fallback at ~10 fps; an unthrottled loop of
            // adb launches pins a core for no visible benefit.
            while !Task.isCancelled {
                let start = ContinuousClock.now
                if let data = await Self.captureFrame(adbPath: adbPath, serial: serial),
                   !Task.isCancelled {
                    self?.onFrameData?(data)
                }

                let elapsed = start.duration(to: .now)
                let remaining = Duration.milliseconds(100) - elapsed
                if remaining > .zero {
                    try? await Task.sleep(for: remaining)
                }
            }
        }
    }

    func stop() {
        captureTask?.cancel()
        captureTask = nil
    }

    @concurrent
    private static func captureFrame(adbPath: String, serial: String) async -> Data? {
        guard let result = try? await ProcessRunner.run(
            adbPath,
            arguments: ["-s", serial, "exec-out", "screencap", "-p"],
            timeout: 3
        ), result.succeeded, result.standardOutputData.count > 100 else {
            return nil
        }
        return result.standardOutputData
    }
}

// Input forwarding via ADB shell input
@MainActor
final class AndroidInputHandler {
    private let adbPath: String
    private let serial: String
    private var pendingCommands: [[String]] = []
    private var workerTask: Task<Void, Never>?

    init(adbPath: String, serial: String) {
        self.adbPath = adbPath
        self.serial = serial
    }

    func tap(viewPoint: CGPoint, viewSize: CGSize, deviceSize: CGSize) {
        let x = Int(viewPoint.x / viewSize.width * deviceSize.width)
        let y = Int(viewPoint.y / viewSize.height * deviceSize.height)
        enqueue(["shell", "input", "tap", "\(x)", "\(y)"])
    }

    func swipe(from: CGPoint, to: CGPoint, viewSize: CGSize, deviceSize: CGSize, duration: Int = 300) {
        let x1 = Int(from.x / viewSize.width * deviceSize.width)
        let y1 = Int(from.y / viewSize.height * deviceSize.height)
        let x2 = Int(to.x / viewSize.width * deviceSize.width)
        let y2 = Int(to.y / viewSize.height * deviceSize.height)
        enqueue(["shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(duration)"])
    }

    func keyEvent(_ code: Int) {
        enqueue(["shell", "input", "keyevent", "\(code)"])
    }

    func text(_ text: String) {
        enqueue(["shell", "input", "text", Self.escapedInputText(text)])
    }

    /// Escapes a string for `adb shell input text`, which runs through the
    /// device shell: spaces map to %s and shell metacharacters must be
    /// backslash-escaped or they get eaten (or worse, interpreted) on the
    /// device side.
    nonisolated static func escapedInputText(_ text: String) -> String {
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
        return escaped
    }

    func stop() {
        workerTask?.cancel()
        workerTask = nil
        pendingCommands.removeAll()
    }

    private func enqueue(_ arguments: [String]) {
        // Bound the queue so a disconnected or slow device cannot turn rapid
        // input into an unbounded number of adb processes.
        if pendingCommands.count >= 32 {
            pendingCommands.removeFirst()
        }
        pendingCommands.append(arguments)
        guard workerTask == nil else { return }

        workerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.pendingCommands.isEmpty {
                let arguments = self.pendingCommands.removeFirst()
                _ = try? await ProcessRunner.run(
                    self.adbPath,
                    arguments: ["-s", self.serial] + arguments,
                    timeout: 3
                )
            }
            self.workerTask = nil
        }
    }
}

@MainActor
class AndroidDeviceMirror: ObservableObject {
    @Published var isMirroring = false
    @Published var isRecording = false
    @Published private(set) var isFinalizingRecording = false
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
    private var frameGrabber: AndroidFrameGrabber?
    private(set) var inputHandler: AndroidInputHandler?
    private var recordingProcess: Process?
    private var recordingRemotePath: String?
    private var recordingFinalizationTask: Task<URL?, Never>?
    private var deviceSerial: String?
    private var durationTimer: Timer?
    private var recordingStartDate: Date?
    private var mirroringDevice: ConnectedDevice?
    private var mirroringStartupTask: Task<Void, Never>?
    private var mirroringGeneration: UUID?

    init(adbPath: String) {
        self.adbPath = adbPath
    }

    func startMirroring(device: ConnectedDevice) {
        guard !isMirroring, let serial = device.adbSerial else { return }
        errorMessage = nil
        deviceSerial = serial
        mirroringDeviceName = device.name
        mirroringDevice = device

        startScreencapMirroring(serial: serial)
    }

    /// In-app screencap mirroring backed by ADB. This intentionally stays
    /// inside Captr instead of launching scrcpy as a separate viewer.
    private func startScreencapMirroring(serial: String) {
        let generation = UUID()
        mirroringGeneration = generation
        currentFrame = nil
        isMirroring = true

        // Fetch device resolution
        Task { [weak self] in
            guard let self else { return }
            let output = (try? await ProcessRunner.run(
                self.adbPath,
                arguments: ["-s", serial, "shell", "wm", "size"],
                timeout: 3
            ))?.standardOutput ?? ""
            if let match = output.range(of: #"\d+x\d+"#, options: .regularExpression) {
                let sizeStr = String(output[match])
                let parts = sizeStr.split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                    guard self.mirroringGeneration == generation else { return }
                    self.deviceResolution = CGSize(width: w, height: h)
                }
            }
        }

        // Start frame grabber - create NSImage on the main thread to avoid
        // cross-thread retain/release issues with Core Animation layers
        let grabber = AndroidFrameGrabber(adbPath: adbPath, serial: serial)
        grabber.onFrameData = { [weak self] data in
            guard let self, self.isMirroring, self.mirroringGeneration == generation else { return }
            if let image = NSImage(data: data) {
                self.currentFrame = image
                self.mirroringStartupTask?.cancel()
                self.mirroringStartupTask = nil
            }
        }
        grabber.start()
        frameGrabber = grabber

        // Create input handler
        inputHandler = AndroidInputHandler(adbPath: adbPath, serial: serial)

        mirroringStartupTask?.cancel()
        mirroringStartupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self,
                  self.mirroringGeneration == generation,
                  self.currentFrame == nil else { return }
            self.errorMessage = "Android screen did not respond. Check the cable, USB debugging, and the trust prompt."
            self.finishStoppingMirror()
        }
    }

    func stopMirroring() {
        if isRecording || isFinalizingRecording {
            Task { [weak self] in
                _ = await self?.stopRecording()
                self?.finishStoppingMirror()
            }
            return
        }
        finishStoppingMirror()
    }

    private func finishStoppingMirror() {
        mirroringGeneration = nil
        mirroringStartupTask?.cancel()
        mirroringStartupTask = nil
        frameGrabber?.stop()
        frameGrabber = nil
        inputHandler?.stop()
        inputHandler = nil

        isMirroring = false
        currentFrame = nil
        mirroringDeviceName = ""
        deviceSerial = nil
        mirroringDevice = nil
    }

    func startRecording() {
        guard isMirroring, !isRecording, !isFinalizingRecording, let serial = deviceSerial else { return }

        let remotePath = "/sdcard/captr-\(UUID().uuidString.lowercased()).mp4"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        // No --size: forcing 1280x720 distorts portrait devices. screenrecord
        // picks the native display resolution on its own.
        process.arguments = ["-s", serial, "shell", "screenrecord", remotePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

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
            recordingRemotePath = remotePath
            isRecording = true
            recordingStartDate = .now
            startDurationTimer()
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() async -> URL? {
        if let recordingFinalizationTask {
            return await recordingFinalizationTask.value
        }
        guard (isRecording || recordingProcess != nil),
              let serial = deviceSerial,
              let remotePath = recordingRemotePath else { return nil }

        isRecording = false
        isFinalizingRecording = true
        stopDurationTimer()

        let process = recordingProcess
        let task = Task { [weak self] () -> URL? in
            guard let self else { return nil }
            return await self.finalizeRecording(
                serial: serial,
                remotePath: remotePath,
                recordingProcess: process
            )
        }
        recordingFinalizationTask = task
        let localURL = await task.value
        recordingFinalizationTask = nil
        recordingProcess = nil
        recordingRemotePath = nil
        isFinalizingRecording = false

        return localURL
    }

    private func finalizeRecording(
        serial: String,
        remotePath: String,
        recordingProcess: Process?
    ) async -> URL? {
        if let recordingProcess {
            // Signal only the adb process Captr launched. This lets
            // screenrecord finish its MP4 footer without touching an
            // unrelated screenrecord process on the device.
            if recordingProcess.isRunning {
                recordingProcess.interrupt()
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while recordingProcess.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }

            // Some adb versions do not forward the local interrupt. Use a
            // device-wide signal only as a last-resort fallback.
            if recordingProcess.isRunning {
                _ = try? await ProcessRunner.run(
                    adbPath,
                    arguments: ["-s", serial, "shell", "pkill", "-2", "screenrecord"],
                    timeout: 3
                )
                let fallbackDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while recordingProcess.isRunning, ContinuousClock.now < fallbackDeadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            if recordingProcess.isRunning {
                recordingProcess.terminate()
            }
        }

        await waitForStableRemoteFile(serial: serial, remotePath: remotePath)

        let outputDir = MediaLibraryManager.recordingsDirectory
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not create the recordings folder: \(error.localizedDescription)"
            return nil
        }
        let localURL = CaptureFileURL.unique(in: outputDir, prefix: "Android Device", pathExtension: "mp4")

        guard let pullResult = try? await ProcessRunner.run(
            adbPath,
            arguments: ["-s", serial, "pull", remotePath, localURL.path],
            timeout: 30
        ), pullResult.succeeded,
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size]) as? NSNumber,
        size.int64Value > 0 else {
            try? FileManager.default.removeItem(at: localURL)
            errorMessage = "Failed to pull the recording from the device. The on-device copy was left in place."
            return nil
        }

        _ = try? await ProcessRunner.run(
            adbPath,
            arguments: ["-s", serial, "shell", "rm", "-f", remotePath],
            timeout: 5
        )
        return localURL
    }

    private func waitForStableRemoteFile(serial: String, remotePath: String) async {
        var previousSize: Int64?
        var stableSamples = 0

        for _ in 0..<20 {
            guard let result = try? await ProcessRunner.run(
                adbPath,
                arguments: ["-s", serial, "shell", "stat", "-c", "%s", remotePath],
                timeout: 2
            ), result.succeeded,
            let size = Int64(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)),
            size > 0 else {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }

            if size == previousSize {
                stableSamples += 1
                if stableSamples >= 2 { return }
            } else {
                previousSize = size
                stableSamples = 0
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func takeScreenshot() -> NSImage? {
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
