import AVFoundation
import AppKit
import CoreMediaIO
import Foundation

/// Captures the wired iPhone screen through macOS's own iOS screen-capture
/// device (the same CoreMediaIO path QuickTime uses). Delivers raw
/// CMSampleBuffers — with the device's real presentation timestamps — on a
/// background queue, so display and recording can both stay frame-accurate.
final class IOSNativeScreenFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.captr.ios-native-feed.session", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "com.captr.ios-native-feed.sample", qos: .userInteractive)
    private let stateLock = NSLock()
    private var output: AVCaptureVideoDataOutput?
    private var input: AVCaptureDeviceInput?
    private var notificationTokens: [NSObjectProtocol] = []
    private var _isRunning = false

    /// Called on the sample queue for every captured frame.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// Called on the main queue when the session dies mid-stream.
    var onFailure: ((String) -> Void)?

    private var isRunning: Bool {
        get { stateLock.withLock { _isRunning } }
        set { stateLock.withLock { _isRunning = newValue } }
    }

    deinit {
        stopSync()
    }

    /// Makes wired iOS screens visible to AVFoundation (off by default).
    static func enableScreenCaptureDevices() -> Bool {
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

    /// Starts capturing, returning the capture device's name. Blocks only a
    /// background queue while macOS publishes the screen device (it can take
    /// a couple of seconds to appear after enabling).
    func start(preferredDeviceName: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    let name = try self.configureSession(preferredDeviceName: preferredDeviceName)
                    self.isRunning = true
                    self.session.startRunning()
                    continuation.resume(returning: name)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        isRunning = false
        sessionQueue.async {
            self.teardownSession()
        }
    }

    private func stopSync() {
        isRunning = false
        sessionQueue.sync {
            self.teardownSession()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRunning else { return }
        onSampleBuffer?(sampleBuffer)
    }

    private func configureSession(preferredDeviceName: String) throws -> String {
        teardownSession()

        guard Self.enableScreenCaptureDevices() else {
            throw NSError(
                domain: "IOSNativeScreenFeed",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not enable macOS iOS screen-capture devices."]
            )
        }

        guard let device = Self.findScreenDevice(preferredDeviceName: preferredDeviceName) else {
            throw NSError(
                domain: "IOSNativeScreenFeed",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No wired iPhone screen-capture device appeared."]
            )
        }

        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        session.sessionPreset = .high

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(
                domain: "IOSNativeScreenFeed",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not attach the iPhone screen input."]
            )
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(
                domain: "IOSNativeScreenFeed",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Could not attach the iPhone screen output."]
            )
        }
        session.addOutput(output)
        session.commitConfiguration()

        self.input = input
        self.output = output
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
                self?.handleSessionFailure(error?.localizedDescription ?? "The iPhone mirror session stopped.")
            }
        )

        notificationTokens.append(
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                self?.handleSessionFailure("The iPhone disconnected.")
            }
        )
    }

    private func handleSessionFailure(_ message: String) {
        guard isRunning else { return }
        isRunning = false

        sessionQueue.async {
            self.teardownSession()
            DispatchQueue.main.async { [weak self] in
                self?.onFailure?(message)
            }
        }
    }

    /// The screen device registers asynchronously after enabling, so poll
    /// briefly. Prefers a name match, then any muxed (screen) device.
    private static func findScreenDevice(preferredDeviceName: String) -> AVCaptureDevice? {
        for _ in 0..<25 {
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
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }
}

/// Fans captured frames out to the display layer, the screenshot cache, and
/// (while recording) the video recorder — all on the capture queue, so the
/// main thread never sits between the device and the screen.
final class IOSMirrorFrameRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var renderer: AVSampleBufferVideoRenderer?
    private var latestPixelBuffer: CVPixelBuffer?
    private var recorder: IOSMirrorVideoRecorder?
    private var recordingBasePTS: Double?
    private var _frameDimensions: CGSize = .zero
    private var firstFrameCallback: ((CGSize) -> Void)?
    private let ciContext = CIContext()

    var hasReceivedFrame: Bool {
        lock.withLock { _frameDimensions != .zero }
    }

    var frameDimensions: CGSize {
        lock.withLock { _frameDimensions }
    }

    /// `onFirstFrame` fires once, on an arbitrary queue.
    func prepare(renderer: AVSampleBufferVideoRenderer, onFirstFrame: @escaping (CGSize) -> Void) {
        lock.withLock {
            self.renderer = renderer
            self.latestPixelBuffer = nil
            self.recorder = nil
            self.recordingBasePTS = nil
            self._frameDimensions = .zero
            self.firstFrameCallback = onFirstFrame
        }
    }

    func reset() {
        let recorder: IOSMirrorVideoRecorder? = lock.withLock {
            let r = self.recorder
            self.renderer = nil
            self.latestPixelBuffer = nil
            self.recorder = nil
            self.recordingBasePTS = nil
            self._frameDimensions = .zero
            self.firstFrameCallback = nil
            return r
        }
        recorder?.cancel()
    }

    func beginRecording(_ recorder: IOSMirrorVideoRecorder) {
        lock.withLock {
            self.recorder = recorder
            self.recordingBasePTS = nil
        }
    }

    func endRecording() -> IOSMirrorVideoRecorder? {
        lock.withLock {
            let r = recorder
            recorder = nil
            recordingBasePTS = nil
            return r
        }
    }

    func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var firstFrame: ((CGSize) -> Void)?
        var dimensions: CGSize = .zero
        let (renderer, recorder, basePTS): (AVSampleBufferVideoRenderer?, IOSMirrorVideoRecorder?, Double?) = lock.withLock {
            latestPixelBuffer = pixelBuffer
            if _frameDimensions == .zero {
                _frameDimensions = CGSize(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                )
                dimensions = _frameDimensions
                firstFrame = firstFrameCallback
                firstFrameCallback = nil
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if self.recorder != nil && recordingBasePTS == nil {
                recordingBasePTS = pts
            }
            return (self.renderer, self.recorder, recordingBasePTS)
        }

        firstFrame?(dimensions)

        if let renderer {
            // Present each frame as soon as it arrives: the capture service
            // already paces frames at the device's real cadence, and skipping
            // a playback clock keeps latency at one frame.
            Self.markDisplayImmediately(sampleBuffer)
            if renderer.status == .failed {
                renderer.flush()
            }
            if renderer.isReadyForMoreMediaData {
                renderer.enqueue(sampleBuffer)
            }
        }

        if let recorder, let basePTS {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            recorder.append(pixelBuffer, elapsed: max(0, pts - basePTS))
        }
    }

    func snapshotImage() -> NSImage? {
        let buffer: CVPixelBuffer? = lock.withLock { latestPixelBuffer }
        guard let buffer else { return nil }

        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else {
            return
        }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}
