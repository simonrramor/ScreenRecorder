import Foundation
import AppKit
import AVFoundation
import VideoToolbox
import os.log
import Darwin

final class IOSMirrorVideoRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let outputURL: URL
    private let frameSize: CGSize
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var lastPresentationTime: CMTime?
    private var didAppendFrame = false
    private var isFinishing = false
    private var transferSession: VTPixelTransferSession?

    init(outputURL: URL, frameSize: CGSize) throws {
        self.outputURL = outputURL
        self.frameSize = frameSize
        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let width = Int(frameSize.width)
        let height = Int(frameSize.height)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        self.input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw NSError(domain: "IOSMirrorVideoRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
        }
        writer.add(input)

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "IOSMirrorVideoRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to start writing"])
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: NSImage, elapsed: TimeInterval) {
        guard let pixelBuffer = Self.makePixelBuffer(from: image, targetSize: frameSize) else { return }
        appendSizedPixelBuffer(pixelBuffer, elapsed: elapsed)
    }

    /// Appends a captured frame using its real capture-clock offset, so the
    /// written file reproduces the device's exact frame timing. Frames whose
    /// dimensions differ from the recording canvas (odd-width devices,
    /// mid-recording rotation) are letterboxed in hardware.
    func append(_ pixelBuffer: CVPixelBuffer, elapsed: TimeInterval) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if width == Int(frameSize.width) && height == Int(frameSize.height) {
            appendSizedPixelBuffer(pixelBuffer, elapsed: elapsed)
        } else if let scaled = letterboxed(pixelBuffer) {
            appendSizedPixelBuffer(scaled, elapsed: elapsed)
        }
    }

    private func appendSizedPixelBuffer(_ pixelBuffer: CVPixelBuffer, elapsed: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinishing, input.isReadyForMoreMediaData else { return }

        let presentationTime = Self.nextPresentationTime(elapsed: elapsed, after: lastPresentationTime)
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else { return }

        didAppendFrame = true
        lastPresentationTime = presentationTime
    }

    /// Clamps timestamps to be strictly increasing (AVAssetWriter rejects
    /// non-monotonic appends) while staying on the capture clock otherwise.
    static func nextPresentationTime(elapsed: TimeInterval, after last: CMTime?) -> CMTime {
        let safeElapsed = elapsed.isFinite ? max(elapsed, 0) : 0
        var presentationTime = CMTime(seconds: safeElapsed, preferredTimescale: 600)
        if let last, CMTimeCompare(presentationTime, last) <= 0 {
            presentationTime = CMTimeAdd(last, CMTime(value: 1, timescale: 600))
        }
        return presentationTime
    }

    private func letterboxed(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        lock.lock()
        if transferSession == nil {
            var session: VTPixelTransferSession?
            if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
               let session {
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
                transferSession = session
            }
        }
        let session = transferSession
        let pool = adaptor.pixelBufferPool
        lock.unlock()

        guard let session else { return nil }

        var destination: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
        }
        if destination == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(frameSize.width),
                Int(frameSize.height),
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &destination
            )
        }
        guard let destination else { return nil }

        guard VTPixelTransferSessionTransferImage(session, from: source, to: destination) == noErr else {
            return nil
        }
        return destination
    }

    func finish() async -> URL? {
        let appended: Bool? = lock.withLock {
            guard !isFinishing else { return nil }
            isFinishing = true
            return didAppendFrame
        }
        guard let appended else { return nil }

        if !appended {
            input.markAsFinished()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        return outputURL
    }

    func cancel() {
        lock.lock()
        if isFinishing {
            lock.unlock()
            return
        }
        isFinishing = true
        lock.unlock()

        input.markAsFinished()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// H.264 requires even dimensions; floors odd sizes (e.g. 1179-wide
    /// iPhones) down by a pixel.
    static func evenSize(_ size: CGSize) -> CGSize {
        let width = max(2, Int(size.width.rounded()) & ~1)
        let height = max(2, Int(size.height.rounded()) & ~1)
        return CGSize(width: width, height: height)
    }

    static func evenFrameSize(for image: NSImage) -> CGSize {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        let width = cgImage?.width ?? Int(max(image.size.width.rounded(), 2))
        let height = cgImage?.height ?? Int(max(image.size.height.rounded(), 2))
        return evenSize(CGSize(width: width, height: height))
    }

    private static func makePixelBuffer(from image: NSImage, targetSize: CGSize) -> CVPixelBuffer? {
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [.alphaFirst, .thirtyTwoBitLittleEndian],
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = graphicsContext

        let canvas = NSRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height)
        NSColor.black.setFill()
        canvas.fill()

        let sourceSize = image.size.width > 0 && image.size.height > 0
            ? image.size
            : targetSize
        let imageRect = aspectFitRect(sourceSize: sourceSize, targetSize: targetSize)
        image.draw(
            in: imageRect,
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1.0
        )
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess,
              let pixelBuffer,
              let sourceData = bitmap.bitmapData else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let destinationData = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let sourceBytesPerRow = bitmap.bytesPerRow
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = min(sourceBytesPerRow, destinationBytesPerRow)

        for row in 0..<height {
            memcpy(
                destinationData.advanced(by: row * destinationBytesPerRow),
                sourceData.advanced(by: row * sourceBytesPerRow),
                rowBytes
            )
        }

        return pixelBuffer
    }

    private static func aspectFitRect(sourceSize: CGSize, targetSize: CGSize) -> NSRect {
        let scale = min(targetSize.width / sourceSize.width, targetSize.height / sourceSize.height)
        let width = sourceSize.width * scale
        let height = sourceSize.height * scale
        return NSRect(
            x: (targetSize.width - width) / 2,
            y: (targetSize.height - height) / 2,
            width: width,
            height: height
        )
    }
}

// Persistent frame grabber using pymobiledevice3 streaming script
class IOSFrameGrabber: @unchecked Sendable {
    private let pythonPath: String
    private let scriptPath: String
    private let udid: String
    private let lock = NSLock()
    private let frameDeliveryLock = NSLock()
    private var _process: Process?
    private var _isRunning = false
    private var latestFrameData: Data?
    private var isFrameDeliveryScheduled = false

    private var isRunning: Bool { lock.withLock { _isRunning } }

    // Delivers the newest decoded frame on the main thread, dropping stale frames.
    var onFrame: ((NSImage) -> Void)?

    init(pythonPath: String, scriptPath: String, udid: String) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.udid = udid
    }

    func start() {
        let shouldStart = lock.withLock {
            guard !_isRunning else { return false }
            _isRunning = true
            return true
        }
        guard shouldStart else { return }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.runStreamingProcess()
        }
    }

    func stop() {
        lock.lock()
        _isRunning = false
        let proc = _process
        _process = nil
        lock.unlock()

        frameDeliveryLock.lock()
        latestFrameData = nil
        isFrameDeliveryScheduled = false
        frameDeliveryLock.unlock()

        if let proc, proc.isRunning {
            let processID = proc.processIdentifier
            proc.terminate()
            Self.forceKillIfStillRunning(processID: processID)
        }
    }

    private func runStreamingProcess() {
        while isRunning {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pythonPath)
            proc.arguments = [scriptPath, udid]

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            do {
                try proc.run()
            } catch {
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }

            let shouldRead = lock.withLock {
                guard _isRunning else { return false }
                _process = proc
                return true
            }
            guard shouldRead else {
                let processID = proc.processIdentifier
                proc.terminate()
                Self.forceKillIfStillRunning(processID: processID)
                proc.waitUntilExit()
                return
            }
            let fileHandle = pipe.fileHandleForReading

            // Read length-prefixed image frames: [4 bytes big-endian length][image data]
            while isRunning && proc.isRunning {
                guard let lengthData = readExactly(from: fileHandle, count: 4) else { break }

                let length = lengthData.reduce(UInt32.zero) { partial, byte in
                    (partial << 8) | UInt32(byte)
                }
                guard length > 0 && length < 50_000_000 else { break }

                guard let frameData = readExactly(from: fileHandle, count: Int(length)) else { break }

                enqueueFrameData(frameData)
            }

            if proc.isRunning {
                let processID = proc.processIdentifier
                proc.terminate()
                Self.forceKillIfStillRunning(processID: processID)
            }
            proc.waitUntilExit()
            lock.withLock {
                if _process === proc {
                    _process = nil
                }
            }

            if isRunning {
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    private static func forceKillIfStillRunning(processID: pid_t) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            guard kill(processID, 0) == 0 else { return }
            kill(processID, SIGKILL)
        }
    }

    private func readExactly(from handle: FileHandle, count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            let chunk = handle.readData(ofLength: count - data.count)
            if chunk.isEmpty { return nil }
            data.append(chunk)
        }
        return data
    }

    private func enqueueFrameData(_ data: Data) {
        frameDeliveryLock.lock()
        latestFrameData = data

        guard !isFrameDeliveryScheduled else {
            frameDeliveryLock.unlock()
            return
        }

        isFrameDeliveryScheduled = true
        frameDeliveryLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.deliverLatestFrameOnMain()
        }
    }

    private func deliverLatestFrameOnMain() {
        frameDeliveryLock.lock()
        guard let data = latestFrameData else {
            isFrameDeliveryScheduled = false
            frameDeliveryLock.unlock()
            return
        }
        latestFrameData = nil
        frameDeliveryLock.unlock()

        if let image = NSImage(data: data) {
            onFrame?(image)
        }

        frameDeliveryLock.lock()
        let shouldContinue = latestFrameData != nil
        if !shouldContinue {
            isFrameDeliveryScheduled = false
        }
        frameDeliveryLock.unlock()

        if shouldContinue {
            DispatchQueue.main.async { [weak self] in
                self?.deliverLatestFrameOnMain()
            }
        }
    }
}

@MainActor
class IOSDeviceMirror: ObservableObject {
    @Published var isMirroring = false
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var deviceResolution: CGSize = .zero
    @Published var mirroringDeviceName: String = ""
    @Published var currentFrame: NSImage?
    @Published var isLowLatencyMirroring = false

    /// Hosts the native feed in the mirror window. Frames are enqueued from
    /// the capture queue, so playback stays smooth even when the main thread
    /// is busy.
    let displayLayer = AVSampleBufferDisplayLayer()

    /// Called when mirroring ends on its own (device unplugged, session
    /// error) so the owner can close the mirror window.
    var onMirroringEnded: ((String?) -> Void)?

    private let frameRouter = IOSMirrorFrameRouter()
    private var nativeFeed: IOSNativeScreenFeed?
    private var frameGrabber: IOSFrameGrabber?
    private var durationTimer: Timer?
    private var recordingStartDate: Date?
    private var mirroringDeviceUDID: String?
    private var videoRecorder: IOSMirrorVideoRecorder?
    private var fallbackStartupTask: Task<Void, Never>?
    private var fallbackGeneration: UUID?
    private var tunneldTask: Task<Void, Never>?

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.wantsExtendedDynamicRangeContent = false
    }

    // Tool paths, resolved per call so installing a tool while the app is
    // running is picked up.
    static var pythonPath: String? { ToolLocator.pymobiledevicePython }

    static var streamScriptPath: String? {
        Bundle.main.path(forResource: "ios_stream", ofType: "py")
    }

    /// The native CoreMediaIO iOS screen-capture path is low latency, but
    /// Apple's iOSScreenCapture plugin has produced wake/disconnect crashes
    /// on macOS 26. Keep it out of production unless explicitly enabled for
    /// local testing.
    nonisolated static func nativeLowLatencyMirroringEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["CAPTR_ENABLE_NATIVE_IOS_MIRROR"] == "1"
    }

    func startMirroring(udid: String, deviceName: String) {
        guard !isMirroring else { return }
        errorMessage = nil
        mirroringDeviceName = deviceName
        mirroringDeviceUDID = udid

        // Optimistically enter native mode; waitForLowLatencyStartup()
        // performs the actual startup and reports whether it worked, letting
        // the caller fall back to screenshot mirroring.
        isMirroring = true
        isLowLatencyMirroring = true
    }

    /// Brings up the native screen feed: camera permission, capture session,
    /// and the first real frame. Returns false when any step fails so the
    /// caller can fall back to screenshot mirroring.
    private static let log = Logger(subsystem: "com.captr.app", category: "IOSMirror")

    func waitForLowLatencyStartup() async -> Bool {
        guard isLowLatencyMirroring else { return false }

        guard await Self.ensureCameraPermission() else {
            Self.log.error("Native mirror unavailable: camera permission not granted (status \(AVCaptureDevice.authorizationStatus(for: .video).rawValue))")
            errorMessage = "Camera permission is needed for live iPhone mirroring (it covers wired screen capture)."
            teardownNativeFeed()
            return false
        }

        let feed = IOSNativeScreenFeed()
        nativeFeed = feed
        frameRouter.prepare(renderer: displayLayer.sampleBufferRenderer) { [weak self] dimensions in
            Task { @MainActor [weak self] in
                guard let self, self.deviceResolution == .zero else { return }
                self.deviceResolution = dimensions
            }
        }
        feed.onSampleBuffer = { [frameRouter] sampleBuffer in
            frameRouter.handle(sampleBuffer)
        }
        feed.onFailure = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleNativeFailure(message)
            }
        }

        do {
            let deviceName = try await feed.start(preferredDeviceName: mirroringDeviceName)
            Self.log.info("Native mirror capture session started for device: \(deviceName, privacy: .public)")
        } catch {
            Self.log.error("Native mirror failed to start: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            teardownNativeFeed()
            return false
        }

        // The session can run yet deliver nothing (e.g. locked phone right
        // after trust). Wait for a real frame before declaring success.
        for _ in 0..<50 {
            guard isLowLatencyMirroring, nativeFeed === feed else { return false }
            if frameRouter.hasReceivedFrame {
                Self.log.info("Native mirror delivering frames (\(Int(self.frameRouter.frameDimensions.width))x\(Int(self.frameRouter.frameDimensions.height)))")
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        Self.log.error("Native mirror session ran but produced no frames within 5s")
        errorMessage = "The iPhone screen feed produced no video."
        teardownNativeFeed()
        return false
    }

    private static func ensureCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    func startFallbackMirroring(udid: String, deviceName: String) {
        if isMirroring {
            stopMirroring()
        }

        guard let pythonPath = Self.pythonPath, let scriptPath = Self.streamScriptPath else {
            errorMessage = "iPhone mirroring needs the pymobiledevice3 environment (~/.pymobiledevice3-venv). See the setup instructions."
            return
        }

        mirroringDeviceName = deviceName
        mirroringDeviceUDID = udid
        isLowLatencyMirroring = false
        currentFrame = nil
        let generation = UUID()
        fallbackGeneration = generation

        // Ensure tunneld is running (needed for iOS 17+). Runs in the
        // background; the frame grabber retries until the tunnel is up.
        ensureTunneld()

        let grabber = IOSFrameGrabber(pythonPath: pythonPath, scriptPath: scriptPath, udid: udid)
        grabber.onFrame = { [weak self] image in
            Task { @MainActor [weak self] in
                guard let self = self, self.isMirroring else { return }
                self.currentFrame = image
                self.fallbackStartupTask?.cancel()
                self.fallbackStartupTask = nil
                if self.deviceResolution == .zero {
                    self.deviceResolution = image.size
                }
                // Record frames as they arrive instead of resampling on a
                // timer: the file then carries the stream's real cadence.
                if self.isRecording, let start = self.recordingStartDate {
                    self.videoRecorder?.append(image, elapsed: Date().timeIntervalSince(start))
                }
            }
        }
        grabber.start()
        frameGrabber = grabber
        isMirroring = true

        fallbackStartupTask?.cancel()
        fallbackStartupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard let self,
                  self.fallbackGeneration == generation,
                  self.currentFrame == nil else { return }
            let message = "The iPhone screen helper started but did not deliver a frame. Check that the phone is unlocked and tunneld is running."
            self.stopMirroring()
            self.errorMessage = message
            self.onMirroringEnded?(message)
        }
    }

    func stopMirroring() {
        fallbackGeneration = nil
        fallbackStartupTask?.cancel()
        fallbackStartupTask = nil
        teardownNativeFeed()

        frameGrabber?.stop()
        frameGrabber = nil

        if isRecording {
            cancelRecording()
        }

        isMirroring = false
        isLowLatencyMirroring = false
        currentFrame = nil
        mirroringDeviceName = ""
        mirroringDeviceUDID = nil
        deviceResolution = .zero
    }

    private func teardownNativeFeed() {
        nativeFeed?.onSampleBuffer = nil
        nativeFeed?.onFailure = nil
        nativeFeed?.stop()
        nativeFeed = nil
        frameRouter.reset()
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        isLowLatencyMirroring = false
    }

    private func handleNativeFailure(_ message: String) {
        guard nativeFeed != nil else { return }
        Self.log.error("Native mirror stopped mid-session: \(message, privacy: .public)")

        if isRecording {
            cancelRecording()
        }
        stopMirroring()
        errorMessage = message
        onMirroringEnded?(message)
    }

    func takeScreenshot() -> NSImage? {
        if isLowLatencyMirroring {
            return frameRouter.snapshotImage()
        }
        return currentFrame
    }

    func startRecording() {
        guard isMirroring, !isRecording else { return }
        errorMessage = nil

        let frameSize: CGSize
        if isLowLatencyMirroring {
            let dimensions = frameRouter.frameDimensions
            guard dimensions != .zero else {
                errorMessage = "Waiting for the first iPhone frame before recording."
                return
            }
            frameSize = IOSMirrorVideoRecorder.evenSize(dimensions)
        } else {
            guard let frame = currentFrame else {
                errorMessage = "Waiting for the first iPhone frame before recording."
                return
            }
            frameSize = IOSMirrorVideoRecorder.evenFrameSize(for: frame)
        }

        let outputDir = MediaLibraryManager.recordingsDirectory
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let outputURL = CaptureFileURL.unique(in: outputDir, prefix: "iPhone Mirror", pathExtension: "mp4")
            let recorder = try IOSMirrorVideoRecorder(outputURL: outputURL, frameSize: frameSize)
            videoRecorder = recorder
            isRecording = true
            recordingStartDate = Date()
            recordingDuration = 0
            if isLowLatencyMirroring {
                frameRouter.beginRecording(recorder)
            } else if let frame = currentFrame {
                recorder.append(frame, elapsed: 0)
            }
            startDurationTimer()
        } catch {
            videoRecorder = nil
            errorMessage = "Failed to start iPhone recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        stopDurationTimer()

        _ = frameRouter.endRecording()
        let outputURL = await videoRecorder?.finish()
        videoRecorder = nil

        if let outputURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           ((attributes[.size] as? Int64) ?? 0) > 0 {
            return outputURL
        }

        errorMessage = "iPhone recording failed to produce a video file."
        return nil
    }

    private func cancelRecording() {
        isRecording = false
        stopDurationTimer()
        _ = frameRouter.endRecording()
        videoRecorder?.cancel()
        videoRecorder = nil
    }

    // MARK: - Tunneld Management

    /// Starts the pymobiledevice3 tunneld daemon if it isn't already running.
    /// All process work happens off the main actor; the frame grabber retries
    /// every second, so the stream recovers once the tunnel comes up. macOS
    /// requires tunneld to run as root, so the user is asked before the
    /// admin-privileges prompt appears.
    private func ensureTunneld() {
        guard tunneldTask == nil else { return }
        guard let pymobiledevicePath = ToolLocator.pymobiledevice3 else { return }

        tunneldTask = Task { [weak self] in
            defer { self?.tunneldTask = nil }
            guard !(await Self.isTunneldRunning()) else { return }

            let approved = Self.confirmTunneldStart()
            guard approved else { return }

            await Self.startTunneld(pymobiledevicePath: pymobiledevicePath)
        }
    }

    @concurrent
    private static func isTunneldRunning() async -> Bool {
        guard let result = try? await ProcessRunner.run(
            "/usr/bin/pgrep",
            arguments: ["-f", "pymobiledevice3 remote tunneld"],
            timeout: 3
        ) else { return false }
        return result.succeeded && !result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private static func confirmTunneldStart() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Start iPhone streaming helper?"
        alert.informativeText = "Mirroring iOS 17+ devices needs the pymobiledevice3 \"tunneld\" helper, which macOS requires to run with administrator privileges. You'll be asked for your password."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @concurrent
    private static func startTunneld(pymobiledevicePath: String) async {
        let escapedPath = pymobiledevicePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedPath) remote tunneld -d\" with administrator privileges"
        _ = try? await ProcessRunner.run(
            "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 30
        )
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
