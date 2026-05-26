import Foundation
import AppKit
import AVFoundation
import CoreMediaIO

@MainActor
private final class IOSMirrorVideoRecorder {
    private let outputURL: URL
    private let frameSize: CGSize
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var lastPresentationTime: CMTime?
    private var didAppendFrame = false
    private var isFinishing = false

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
                AVVideoAverageBitRateKey: 8_000_000,
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
        guard !isFinishing, input.isReadyForMoreMediaData else { return }

        var presentationTime = CMTime(seconds: max(elapsed, 0), preferredTimescale: 600)
        if let lastPresentationTime, CMTimeCompare(presentationTime, lastPresentationTime) <= 0 {
            presentationTime = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 600))
        }

        guard let pixelBuffer = Self.makePixelBuffer(from: image, targetSize: frameSize),
              adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            return
        }

        didAppendFrame = true
        lastPresentationTime = presentationTime
    }

    func finish() async -> URL? {
        guard !isFinishing else { return nil }
        isFinishing = true

        if !didAppendFrame {
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
        guard !isFinishing else { return }
        isFinishing = true
        input.markAsFinished()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    static func evenFrameSize(for image: NSImage) -> CGSize {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        var width = cgImage?.width ?? Int(max(image.size.width.rounded(), 2))
        var height = cgImage?.height ?? Int(max(image.size.height.rounded(), 2))

        width = max(2, width - (width % 2))
        height = max(2, height - (height % 2))
        return CGSize(width: width, height: height)
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

private final class IOSNativeFrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.captr.ios-native-mirror.session", qos: .userInitiated)
    private let sessionQueueKey = DispatchSpecificKey<Void>()
    private let sampleQueue = DispatchQueue(label: "com.captr.ios-native-mirror.sample", qos: .userInteractive)
    private let ciContext = CIContext()
    private let stateLock = NSLock()
    private var output: AVCaptureVideoDataOutput?
    private var input: AVCaptureDeviceInput?
    private var notificationTokens: [NSObjectProtocol] = []
    private var _isRunning = false
    private var lastDeliveredFrameTime: CFAbsoluteTime = 0

    var onFrame: ((NSImage) -> Void)?
    var onFailure: ((String) -> Void)?

    private var isRunning: Bool {
        get { stateLock.withLock { _isRunning } }
        set { stateLock.withLock { _isRunning = newValue } }
    }

    override init() {
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: ())
    }

    deinit {
        stop()
    }

    func start(preferredDeviceName: String) throws -> String {
        var result: Result<String, Error>!
        sessionQueue.sync {
            result = Result {
                try self.configureSession(preferredDeviceName: preferredDeviceName)
            }
        }

        let localizedName = try result.get()
        isRunning = true

        sessionQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.session.startRunning()
        }

        return localizedName
    }

    func stop() {
        isRunning = false

        let teardown = {
            self.teardownSession()
        }

        if DispatchQueue.getSpecific(key: sessionQueueKey) != nil {
            teardown()
        } else {
            sessionQueue.sync(execute: teardown)
        }
    }

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        if #available(macOS 14.0, *) {
            previewLayer.wantsExtendedDynamicRangeContent = false
        }
        return previewLayer
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        autoreleasepool {
            guard isRunning,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }

            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastDeliveredFrameTime >= 1.0 / 60.0 else { return }
            lastDeliveredFrameTime = now

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                return
            }

            let size = NSSize(width: cgImage.width, height: cgImage.height)

            DispatchQueue.main.async { [weak self] in
                guard self?.isRunning == true else { return }
                self?.onFrame?(NSImage(cgImage: cgImage, size: size))
            }
        }
    }

    private func configureSession(preferredDeviceName: String) throws -> String {
        teardownSession()

        guard Self.enableScreenCaptureDevices() else {
            throw NSError(
                domain: "IOSNativeFrameGrabber",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not enable macOS iOS screen capture devices."]
            )
        }

        guard let device = Self.findMuxedDevice(preferredDeviceName: preferredDeviceName) else {
            throw NSError(
                domain: "IOSNativeFrameGrabber",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No wired iPhone screen capture device is available."]
            )
        }

        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        session.sessionPreset = .high

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(
                domain: "IOSNativeFrameGrabber",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not attach the iPhone screen input."]
            )
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
            self.output = output
        } else {
            output.setSampleBufferDelegate(nil, queue: nil)
        }
        session.commitConfiguration()

        self.input = input
        installSessionObservers(for: device)

        return device.localizedName
    }

    private func teardownSession() {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()

        output?.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning {
            session.stopRunning()
        }

        session.beginConfiguration()
        if let output, session.outputs.contains(output) {
            session.removeOutput(output)
        }
        if let input, session.inputs.contains(input) {
            session.removeInput(input)
        }
        session.commitConfiguration()

        output = nil
        input = nil
    }

    private func installSessionObservers(for device: AVCaptureDevice) {
        let center = NotificationCenter.default

        notificationTokens.append(
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.handleSessionFailure(error?.localizedDescription ?? "The native iPhone mirror session stopped.")
            }
        )

        notificationTokens.append(
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
                self?.handleSessionFailure("The native iPhone mirror was interrupted.")
            }
        )

        notificationTokens.append(
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                self?.handleSessionFailure("The iPhone disconnected from the native mirror.")
            }
        )
    }

    private func handleSessionFailure(_ message: String) {
        guard isRunning else { return }
        isRunning = false

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.teardownSession()
            DispatchQueue.main.async { [weak self] in
                self?.onFailure?(message)
            }
        }
    }

    private static func enableScreenCaptureDevices() -> Bool {
        var allow: UInt32 = 1
        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
        return status == noErr
    }

    private static func findMuxedDevice(preferredDeviceName: String) -> AVCaptureDevice? {
        for _ in 0..<15 {
            let devices = AVCaptureDevice.devices(for: .muxed)
            if let exact = devices.first(where: { device in
                device.localizedName.localizedCaseInsensitiveContains(preferredDeviceName)
                    || preferredDeviceName.localizedCaseInsensitiveContains(device.localizedName)
            }) {
                return exact
            }
            if let first = devices.first {
                return first
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        return nil
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

    private var isRunning: Bool {
        get { lock.withLock { _isRunning } }
        set { lock.withLock { _isRunning = newValue } }
    }

    // Delivers the newest decoded frame on the main thread, dropping stale frames.
    var onFrame: ((NSImage) -> Void)?

    init(pythonPath: String, scriptPath: String, udid: String) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.udid = udid
    }

    func start() {
        isRunning = true
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

        proc?.terminate()
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

            lock.withLock { _process = proc }
            let fileHandle = pipe.fileHandleForReading

            // Read length-prefixed image frames: [4 bytes big-endian length][image data]
            while isRunning && proc.isRunning {
                guard let lengthData = readExactly(from: fileHandle, count: 4) else { break }

                let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                guard length > 0 && length < 50_000_000 else { break }

                guard let frameData = readExactly(from: fileHandle, count: Int(length)) else { break }

                enqueueFrameData(frameData)
            }

            proc.terminate()
            proc.waitUntilExit()
            lock.withLock { _process = nil }

            if isRunning {
                Thread.sleep(forTimeInterval: 1.0)
            }
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
    @Published var isNativeMirroring = false

    private var nativeFrameGrabber: IOSNativeFrameGrabber?
    private var frameGrabber: IOSFrameGrabber?
    private var lowLatencyStreamProcess: Process?
    private var lowLatencyPlayerProcess: Process?
    private var lowLatencyErrorOutput = ""
    private var durationTimer: Timer?
    private var recordingFrameTimer: Timer?
    private var recordingStartDate: Date?
    private var mirroringDeviceUDID: String?
    private var videoRecorder: IOSMirrorVideoRecorder?
    private var nativeLifecycleObserverRemovers: [() -> Void] = []

    init() {
        installNativeLifecycleObservers()
    }

    deinit {
        nativeLifecycleObserverRemovers.forEach { $0() }
    }

    // Paths
    static let pythonPath = "\(NSHomeDirectory())/.pymobiledevice3-venv/bin/python3.13"
    static let pymobiledevicePath = "\(NSHomeDirectory())/.pymobiledevice3-venv/bin/pymobiledevice3"
    static let ideviceIdPath = "/opt/homebrew/bin/idevice_id"
    static var ffplayPath: String? {
        [
            "/opt/homebrew/bin/ffplay",
            "/usr/local/bin/ffplay"
        ].first { FileManager.default.fileExists(atPath: $0) }
    }

    // Path to streaming script (bundled in app or in source tree)
    static var streamScriptPath: String {
        if let bundled = Bundle.main.path(forResource: "ios_stream", ofType: "py") {
            return bundled
        }
        return "\(NSHomeDirectory())/ScreenRecorder/Resources/ios_stream.py"
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: pythonPath) &&
        FileManager.default.fileExists(atPath: ideviceIdPath)
    }

    func startMirroring(udid: String, deviceName: String, allowNative: Bool = true) {
        guard !isMirroring else { return }
        errorMessage = nil
        lowLatencyErrorOutput = ""
        mirroringDeviceName = deviceName
        mirroringDeviceUDID = udid

        if allowNative, startNativeMirroring(deviceName: deviceName) {
            return
        }

        if startLowLatencyMirroring(udid: udid, deviceName: deviceName) {
            return
        }

        startFallbackMirroring(udid: udid, deviceName: deviceName)
    }

    func startFallbackMirroring(udid: String, deviceName: String) {
        if isMirroring {
            stopMirroring()
        }

        mirroringDeviceName = deviceName
        mirroringDeviceUDID = udid
        isLowLatencyMirroring = false
        isNativeMirroring = false
        lowLatencyErrorOutput = ""

        // Ensure tunneld is running (needed for iOS 17+)
        ensureTunneld()

        let grabber = IOSFrameGrabber(pythonPath: Self.pythonPath, scriptPath: Self.streamScriptPath, udid: udid)
        grabber.onFrame = { [weak self] image in
            Task { @MainActor [weak self] in
                guard let self = self, self.isMirroring else { return }
                self.currentFrame = image
                if self.deviceResolution == .zero {
                    self.deviceResolution = image.size
                }
            }
        }
        grabber.start()
        frameGrabber = grabber
        isMirroring = true
    }

    func waitForLowLatencyStartup() async -> Bool {
        guard isLowLatencyMirroring else { return false }

        try? await Task.sleep(nanoseconds: 900_000_000)
        guard isLowLatencyMirroring,
              lowLatencyStreamProcess?.isRunning == true,
              lowLatencyPlayerProcess?.isRunning == true else {
            if errorMessage == nil {
                errorMessage = "iPhone mirror closed before the player window opened."
            }
            return false
        }

        bringLowLatencyMirrorWindowToFront()
        return true
    }

    func waitForNativeStartup() async -> Bool {
        guard isNativeMirroring else { return false }

        for _ in 0..<20 {
            if currentFrame != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if errorMessage == nil {
            errorMessage = "Native iPhone mirror opened, but macOS did not deliver video frames."
        }
        return false
    }

    func makeNativePreviewLayer() -> AVCaptureVideoPreviewLayer? {
        guard isNativeMirroring else { return nil }
        return nativeFrameGrabber?.makePreviewLayer()
    }

    func stopMirroring() {
        stopLowLatencyMirroring()

        nativeFrameGrabber?.stop()
        nativeFrameGrabber = nil

        frameGrabber?.stop()
        frameGrabber = nil

        if isRecording {
            cancelRecording()
        }

        isMirroring = false
        isLowLatencyMirroring = false
        isNativeMirroring = false
        currentFrame = nil
        mirroringDeviceName = ""
        mirroringDeviceUDID = nil
        deviceResolution = .zero
    }

    func takeScreenshot() -> NSImage? {
        return currentFrame
    }

    func startRecording() {
        guard isMirroring, !isRecording else { return }
        errorMessage = nil

        guard let frame = currentFrame else {
            if isNativeMirroring {
                errorMessage = "Use Capture's Window or Area recording on the iPhone mirror window."
            } else {
                errorMessage = "Waiting for the first iPhone frame before recording."
            }
            return
        }

        let outputDir = MediaLibraryManager.recordingsDirectory
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let fileName = "iPhone Mirror \(Date().screenRecorderFileName).mp4"
            let outputURL = outputDir.appendingPathComponent(fileName)
            let frameSize = IOSMirrorVideoRecorder.evenFrameSize(for: frame)
            videoRecorder = try IOSMirrorVideoRecorder(outputURL: outputURL, frameSize: frameSize)
            isRecording = true
            recordingStartDate = Date()
            recordingDuration = 0
            videoRecorder?.append(frame, elapsed: 0)
            startDurationTimer()
            startRecordingFrameTimer()
        } catch {
            videoRecorder = nil
            errorMessage = "Failed to start iPhone recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() async -> URL? {
        guard isRecording else { return nil }
        appendRecordingFrame()
        isRecording = false
        stopRecordingFrameTimer()
        stopDurationTimer()

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
        stopRecordingFrameTimer()
        stopDurationTimer()
        videoRecorder?.cancel()
        videoRecorder = nil
    }

    // MARK: - Native AVFoundation Mirror

    private func startNativeMirroring(deviceName: String) -> Bool {
        let grabber = IOSNativeFrameGrabber()
        grabber.onFrame = { [weak self] image in
            Task { @MainActor [weak self] in
                guard let self, self.isMirroring, self.isNativeMirroring else { return }
                self.currentFrame = image
                if self.deviceResolution == .zero {
                    self.deviceResolution = image.size
                }
            }
        }
        grabber.onFailure = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.fallBackFromNativeMirroring(reason: message)
            }
        }

        do {
            let nativeDeviceName = try grabber.start(preferredDeviceName: deviceName)
            nativeFrameGrabber = grabber
            mirroringDeviceName = nativeDeviceName
            isNativeMirroring = true
            isLowLatencyMirroring = false
            isMirroring = true
            return true
        } catch {
            errorMessage = "Native iPhone mirror unavailable: \(error.localizedDescription)"
            nativeFrameGrabber = nil
            isNativeMirroring = false
            return false
        }
    }

    private func installNativeLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default

        let willSleep = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopNativeMirroringForSystemEvent("Stopped iPhone mirror before Mac sleep.")
            }
        }
        nativeLifecycleObserverRemovers.append { workspaceCenter.removeObserver(willSleep) }

        let didWake = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopNativeMirroringForSystemEvent("Stopped iPhone mirror after Mac wake. Reopen it to start a fresh stream.")
            }
        }
        nativeLifecycleObserverRemovers.append { workspaceCenter.removeObserver(didWake) }

        let willTerminate = defaultCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopMirroring()
            }
        }
        nativeLifecycleObserverRemovers.append { defaultCenter.removeObserver(willTerminate) }
    }

    private func fallBackFromNativeMirroring(reason: String) {
        guard isNativeMirroring else { return }

        let udid = mirroringDeviceUDID
        let deviceName = mirroringDeviceName.isEmpty ? "iPhone" : mirroringDeviceName
        stopMirroring()
        errorMessage = reason

        if let udid {
            startFallbackMirroring(udid: udid, deviceName: deviceName)
            errorMessage = reason
        }
    }

    private func stopNativeMirroringForSystemEvent(_ message: String) {
        guard isNativeMirroring else { return }
        stopMirroring()
        errorMessage = message
    }

    // MARK: - Low-Latency H.264 Player

    private func startLowLatencyMirroring(udid: String, deviceName: String) -> Bool {
        isNativeMirroring = false

        guard let ffplayPath = Self.ffplayPath else {
            errorMessage = "ffplay not found. Falling back to screenshot mirroring."
            return false
        }

        let pipe = Pipe()
        let streamErrorPipe = Pipe()
        let playerErrorPipe = Pipe()

        let streamProcess = Process()
        streamProcess.executableURL = URL(fileURLWithPath: Self.pythonPath)
        streamProcess.arguments = [Self.streamScriptPath, "--h264", udid]
        streamProcess.standardOutput = pipe
        streamProcess.standardError = streamErrorPipe

        let playerProcess = Process()
        playerProcess.executableURL = URL(fileURLWithPath: ffplayPath)
        playerProcess.arguments = [
            "-hide_banner",
            "-loglevel", "warning",
            "-fflags", "nobuffer",
            "-flags", "low_delay",
            "-avioflags", "direct",
            "-framedrop",
            "-probesize", "32",
            "-analyzeduration", "0",
            "-sync", "ext",
            "-f", "h264",
            "-i", "pipe:0",
            "-window_title", "Captr iOS - \(deviceName)",
            "-x", "390",
            "-y", "760"
        ]
        playerProcess.standardInput = pipe
        playerProcess.standardOutput = Pipe()
        playerProcess.standardError = playerErrorPipe

        streamProcess.terminationHandler = { [weak self, weak streamProcess] _ in
            let errorOutput = String(
                data: streamErrorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            Task { @MainActor [weak self, weak streamProcess] in
                guard let self else { return }
                if let streamProcess, self.lowLatencyStreamProcess === streamProcess {
                    self.rememberLowLatencyError(errorOutput)
                    if self.errorMessage == nil {
                        self.errorMessage = self.lowLatencyFailureMessage(fallback: "iPhone stream stopped before the mirror window opened.")
                    }
                    self.lowLatencyStreamProcess = nil
                    if self.lowLatencyPlayerProcess?.isRunning == true {
                        self.lowLatencyPlayerProcess?.terminate()
                    }
                    self.finishLowLatencyMirroringIfNeeded()
                }
            }
        }

        playerProcess.terminationHandler = { [weak self, weak playerProcess] _ in
            let errorOutput = String(
                data: playerErrorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            Task { @MainActor [weak self, weak playerProcess] in
                guard let self else { return }
                if let playerProcess, self.lowLatencyPlayerProcess === playerProcess {
                    self.rememberLowLatencyError(errorOutput)
                    if self.errorMessage == nil {
                        self.errorMessage = self.lowLatencyFailureMessage(fallback: "iPhone player closed before the mirror window opened.")
                    }
                    self.lowLatencyPlayerProcess = nil
                    if self.lowLatencyStreamProcess?.isRunning == true {
                        self.lowLatencyStreamProcess?.terminate()
                    }
                    self.finishLowLatencyMirroringIfNeeded()
                }
            }
        }

        do {
            try playerProcess.run()
            try streamProcess.run()
            lowLatencyPlayerProcess = playerProcess
            lowLatencyStreamProcess = streamProcess
            isLowLatencyMirroring = true
            isMirroring = true
            bringLowLatencyMirrorWindowToFront()
            return true
        } catch {
            if playerProcess.isRunning {
                playerProcess.terminate()
            }
            if streamProcess.isRunning {
                streamProcess.terminate()
            }
            errorMessage = "Failed to start low-latency iPhone mirror: \(error.localizedDescription)"
            isLowLatencyMirroring = false
            isMirroring = false
            return false
        }
    }

    private func rememberLowLatencyError(_ output: String) {
        let cleaned = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(4)
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return }
        lowLatencyErrorOutput = cleaned
    }

    private func lowLatencyFailureMessage(fallback: String) -> String {
        guard !lowLatencyErrorOutput.isEmpty else { return fallback }
        return "\(fallback) \(lowLatencyErrorOutput)"
    }

    private func stopLowLatencyMirroring() {
        let streamProcess = lowLatencyStreamProcess
        let playerProcess = lowLatencyPlayerProcess
        lowLatencyStreamProcess = nil
        lowLatencyPlayerProcess = nil

        if streamProcess?.isRunning == true {
            streamProcess?.terminate()
        }
        if playerProcess?.isRunning == true {
            playerProcess?.terminate()
        }
    }

    private func finishLowLatencyMirroringIfNeeded() {
        guard lowLatencyStreamProcess == nil || lowLatencyPlayerProcess == nil else { return }
        isLowLatencyMirroring = false
        isMirroring = false
        mirroringDeviceName = ""
        mirroringDeviceUDID = nil
    }

    func bringLowLatencyMirrorWindowToFront() {
        guard let lowLatencyPlayerProcess else { return }
        bringExternalMirrorWindowToFront(lowLatencyPlayerProcess)
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

    // MARK: - Tunneld Management

    private func ensureTunneld() {
        // Check if tunneld is already running
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        checkProcess.arguments = ["-f", "pymobiledevice3 remote tunneld"]
        let pipe = Pipe()
        checkProcess.standardOutput = pipe
        checkProcess.standardError = Pipe()
        try? checkProcess.run()
        checkProcess.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return // tunneld already running
        }

        // Start tunneld via osascript with admin privileges
        let script = "do shell script \"\(Self.pymobiledevicePath.replacingOccurrences(of: "\"", with: "\\\"")) remote tunneld -d\" with administrator privileges"
        let osaProcess = Process()
        osaProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osaProcess.arguments = ["-e", script]
        osaProcess.standardOutput = Pipe()
        osaProcess.standardError = Pipe()
        try? osaProcess.run()
        osaProcess.waitUntilExit()

        // Give tunneld a moment to start
        Thread.sleep(forTimeInterval: 2.0)
    }

    // MARK: - Device Discovery

    static func listDevices() -> [(udid: String, name: String)] {
        guard FileManager.default.fileExists(atPath: ideviceIdPath) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ideviceIdPath)
        process.arguments = ["-l"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var devices: [(udid: String, name: String)] = []

        for line in output.components(separatedBy: "\n") {
            let udid = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !udid.isEmpty else { continue }

            // Get device name
            let nameProcess = Process()
            nameProcess.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ideviceinfo")
            nameProcess.arguments = ["-u", udid, "-k", "DeviceName"]
            let namePipe = Pipe()
            nameProcess.standardOutput = namePipe
            nameProcess.standardError = Pipe()
            try? nameProcess.run()
            nameProcess.waitUntilExit()

            let name = String(data: namePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "iOS Device"

            devices.append((udid: udid, name: name.isEmpty ? "iOS Device" : name))
        }

        return devices
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

    private func startRecordingFrameTimer() {
        stopRecordingFrameTimer()
        recordingFrameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appendRecordingFrame()
            }
        }
    }

    private func stopRecordingFrameTimer() {
        recordingFrameTimer?.invalidate()
        recordingFrameTimer = nil
    }

    private func appendRecordingFrame() {
        guard isRecording,
              let frame = currentFrame,
              let start = recordingStartDate else {
            return
        }

        videoRecorder?.append(frame, elapsed: Date().timeIntervalSince(start))
    }
}
