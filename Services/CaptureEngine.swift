import Foundation
import ScreenCaptureKit
import AVFoundation
import Combine
import AppKit

@MainActor
class CaptureEngine: NSObject, ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var recordingDuration: TimeInterval = 0
    @Published var availableDisplays: [SCDisplay] = []
    @Published var availableWindows: [SCWindow] = []
    @Published var errorMessage: String?

    /// Called on the main actor when the stream stops unexpectedly.
    var onStreamError: ((String) -> Void)?

    /// Called on the main actor for non-fatal problems (e.g. the microphone
    /// failed to start) while the recording itself keeps running.
    var onWarning: ((String) -> Void)?

    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var durationTimer: Timer?
    private var recordingStartDate: Date?
    private let audioManager = AudioManager()
    private var outputURL: URL?

    var configuration = CaptureConfiguration()

    func refreshAvailableContent() async {
        errorMessage = nil

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            availableDisplays = content.displays
            availableWindows = content.windows.filter { $0.isOnScreen && $0.title?.isEmpty == false }
            refreshSelectedCaptureTargets()
        } catch {
            availableDisplays = []
            availableWindows = []
            configuration.selectedDisplay = nil
            configuration.selectedWindow = nil
            errorMessage = "Failed to get screen content: \(error.localizedDescription)"
        }
    }

    func startRecording() async {
        guard state == .idle else { return }
        state = .preparing
        errorMessage = nil

        do {
            await refreshAvailableContent()

            let filter = try createContentFilter()
            let streamConfig = createStreamConfiguration()

            let outputDir = MediaLibraryManager.recordingsDirectory
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let fileName = "Screen Recording \(Date().screenRecorderFileName).mp4"
            let url = outputDir.appendingPathComponent(fileName)
            outputURL = url

            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: streamConfig.width,
                AVVideoHeightKey: streamConfig.height,
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

            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true
            writer.add(vInput)

            var aInput: AVAssetWriterInput?
            if configuration.captureSystemAudio || configuration.captureMicrophone {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192000
                ]
                let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioWriterInput.expectsMediaDataInRealTime = true
                writer.add(audioWriterInput)
                aInput = audioWriterInput
            }

            let bufferWriter = BufferWriter(assetWriter: writer, videoInput: vInput, audioInput: aInput)
            let output = CaptureStreamOutput(bufferWriter: bufferWriter)
            output.onStreamError = { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self = self, self.state.isActive else { return }
                    self.stopDurationTimer()
                    self.audioManager.stopMicrophoneCapture()
                    self.stream = nil
                    self.streamOutput = nil
                    self.cleanup()
                    self.errorMessage = "Recording stopped: \(message)"
                    self.onStreamError?(self.errorMessage!)
                }
            }

            let captureStream = SCStream(filter: filter, configuration: streamConfig, delegate: output)
            try captureStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

            if configuration.captureSystemAudio {
                try captureStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
            }

            try await captureStream.startCapture()
            stream = captureStream
            streamOutput = output

            if configuration.captureMicrophone {
                audioManager.onError = { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.onWarning?("Recording continues without microphone: \(message)")
                    }
                }
                audioManager.startMicrophoneCapture { [weak bufferWriter] sampleBuffer in
                    bufferWriter?.appendAudio(sampleBuffer)
                }
            }

            state = .recording
            recordingStartDate = Date()
            startDurationTimer()

        } catch {
            state = .idle
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() async -> URL? {
        guard state.isActive else { return nil }
        state = .stopping
        errorMessage = nil

        stopDurationTimer()
        audioManager.stopMicrophoneCapture()

        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                print("Error stopping stream: \(error)")
            }
        }
        stream = nil

        var writerError: Error?
        var receivedFrames = true
        if let output = streamOutput {
            await output.bufferWriter.finishWriting()
            writerError = output.bufferWriter.writerError
            receivedFrames = output.bufferWriter.didReceiveFrames
        }
        streamOutput = nil

        let url = outputURL
        cleanup()

        if let url = url {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            if size == 0 {
                try? FileManager.default.removeItem(at: url)
                if let writerError {
                    errorMessage = "Recording failed: \(writerError.localizedDescription)"
                } else if !receivedFrames {
                    errorMessage = "Recording produced no frames. Check Screen Recording permission in System Settings → Privacy & Security."
                } else {
                    errorMessage = "Recording produced an empty file"
                }
                return nil
            }
        }

        return url
    }

    func cancelRecording() async {
        stopDurationTimer()
        audioManager.stopMicrophoneCapture()

        if let stream = stream {
            try? await stream.stopCapture()
        }
        stream = nil

        streamOutput?.bufferWriter.cancelWriting()
        streamOutput = nil

        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }

        cleanup()
    }

    // MARK: - Private Helpers

    private func refreshSelectedCaptureTargets() {
        if let selectedDisplayID = configuration.selectedDisplay?.displayID {
            configuration.selectedDisplay = availableDisplays.first { $0.displayID == selectedDisplayID }
                ?? availableDisplays.first
        } else {
            configuration.selectedDisplay = availableDisplays.first
        }

        if let selectedWindowID = configuration.selectedWindow?.windowID {
            configuration.selectedWindow = availableWindows.first { $0.windowID == selectedWindowID }
        }
    }

    private func createContentFilter() throws -> SCContentFilter {
        switch configuration.mode {
        case .fullScreen:
            guard let display = displayForFullScreenCapture() else {
                throw CaptureError.noDisplay
            }
            return SCContentFilter(display: display, excludingWindows: [])

        case .window:
            guard let window = configuration.selectedWindow else {
                throw CaptureError.noWindow
            }
            return SCContentFilter(desktopIndependentWindow: window)

        case .area:
            guard let area = configuration.selectedArea else {
                throw CaptureError.noArea
            }
            guard let display = displayContaining(area) ?? configuration.selectedDisplay ?? availableDisplays.first else {
                throw CaptureError.noDisplay
            }
            return SCContentFilter(display: display, excludingWindows: [])
        }
    }

    /// Finds the display whose CG bounds contain (or intersect) the given
    /// global-coordinate rect. Area selection delivers rects in global CG
    /// space, so we have to look up the right display before building the
    /// stream's content filter and source rect.
    func displayContaining(_ area: CGRect) -> SCDisplay? {
        ScreenGeometry.bestDisplay(for: area, in: availableDisplays)
    }

    func displayForFullScreenCapture() -> SCDisplay? {
        displayContainingMouse() ?? configuration.selectedDisplay ?? availableDisplays.first
    }

    private func displayContainingMouse() -> SCDisplay? {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return availableDisplays.first { $0.displayID == displayID }
    }

    private func createStreamConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()

        switch configuration.mode {
        case .window:
            if let window = configuration.selectedWindow {
                let scale = ScreenGeometry.backingScale(forCGRect: window.frame) ?? 2.0
                setEvenPixelSize(on: config, width: window.frame.width * scale, height: window.frame.height * scale)
            }
        case .area:
            if let area = configuration.selectedArea,
               let display = displayContaining(area) ?? configuration.selectedDisplay ?? availableDisplays.first {
                let localRect = ScreenGeometry.integralDisplayLocalRect(for: area, displayID: display.displayID) ?? .zero
                config.sourceRect = localRect
                let scale = ScreenGeometry.backingScale(for: display.displayID) ?? 2.0
                setEvenPixelSize(on: config, width: localRect.width * scale, height: localRect.height * scale)
            } else if let display = configuration.selectedDisplay ?? availableDisplays.first {
                let scale = ScreenGeometry.backingScale(for: display.displayID) ?? 2.0
                setEvenPixelSize(on: config, width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)
            }
        case .fullScreen:
            if let display = displayForFullScreenCapture() {
                switch configuration.resolution {
                case .native:
                    let scale = ScreenGeometry.backingScale(for: display.displayID) ?? 2.0
                    setEvenPixelSize(on: config, width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)
                case .hd1080:
                    config.width = 1920
                    config.height = 1080
                case .hd720:
                    config.width = 1280
                    config.height = 720
                }
            }
        }

        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
        config.showsCursor = configuration.showCursor
        config.capturesAudio = configuration.captureSystemAudio
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // Pin the source buffers to Rec.709 / sRGB so they match the
        // writer's declared color properties on extended-gamut displays.
        config.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 14.0, *) {
            config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        }

        return config
    }

    /// H.264 requires even dimensions; odd sizes make the encoder fail.
    private func setEvenPixelSize(on config: SCStreamConfiguration, width: CGFloat, height: CGFloat) {
        let pixW = Int(width)
        let pixH = Int(height)
        config.width = max(2, pixW - (pixW % 2))
        config.height = max(2, pixH - (pixH % 2))
    }

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.recordingStartDate else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func cleanup() {
        state = .idle
        recordingDuration = 0
        recordingStartDate = nil
        outputURL = nil
    }
}

// MARK: - Buffer Writer (thread-safe, works on capture queue)

class BufferWriter: @unchecked Sendable {
    private let assetWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let lock = NSLock()
    private var sessionStarted = false
    private var isFinished = false

    // ScreenCaptureKit on macOS 26 attaches a stereoscopic-disparity tag
    // to every frame's IOSurface, which AVAssetWriter rejects with
    // err -16122 ("operation could not be completed") when encoding
    // plain H.264. The attachment lives on the IOSurface itself and is
    // not removable via CVBuffer*Attachment / IOSurfaceRemoveValue.
    // Workaround: maintain a pool of clean pixel buffers, memcpy each
    // frame into one, and append that instead.
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    var didReceiveFrames: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionStarted
    }

    var writerError: Error? { assetWriter.error }

    init(assetWriter: AVAssetWriter, videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput?) {
        self.assetWriter = assetWriter
        self.videoInput = videoInput
        self.audioInput = audioInput
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished, assetWriter.status != .failed else { return }
        guard let srcPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let width = CVPixelBufferGetWidth(srcPixelBuffer)
        let height = CVPixelBufferGetHeight(srcPixelBuffer)
        guard width > 0, height > 0 else { return }

        if pixelBufferPool == nil || poolWidth != width || poolHeight != height {
            let pixelAttrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
            ]
            let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, pixelAttrs as CFDictionary, &pool) == kCVReturnSuccess, let pool else { return }
            pixelBufferPool = pool
            poolWidth = width
            poolHeight = height
        }

        var dstPixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool!, &dstPixelBuffer) == kCVReturnSuccess,
              let dstPixelBuffer else { return }

        if let cs = CGColorSpace(name: CGColorSpace.sRGB) {
            CVBufferSetAttachment(dstPixelBuffer, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
        }

        CVPixelBufferLockBaseAddress(srcPixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(dstPixelBuffer, [])
        if let srcBase = CVPixelBufferGetBaseAddress(srcPixelBuffer),
           let dstBase = CVPixelBufferGetBaseAddress(dstPixelBuffer) {
            let srcStride = CVPixelBufferGetBytesPerRow(srcPixelBuffer)
            let dstStride = CVPixelBufferGetBytesPerRow(dstPixelBuffer)
            if srcStride == dstStride {
                memcpy(dstBase, srcBase, srcStride * height)
            } else {
                let copy = min(srcStride, dstStride)
                for y in 0..<height {
                    memcpy(dstBase.advanced(by: y * dstStride),
                           srcBase.advanced(by: y * srcStride),
                           copy)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(dstPixelBuffer, [])
        CVPixelBufferUnlockBaseAddress(srcPixelBuffer, .readOnly)

        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: dstPixelBuffer, formatDescriptionOut: &formatDesc) == noErr,
              let formatDesc else { return }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        )

        var newSampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: dstPixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &newSampleBuffer
        ) == noErr, let newSampleBuffer else { return }

        if !sessionStarted {
            assetWriter.startWriting()
            let pts = CMSampleBufferGetPresentationTimeStamp(newSampleBuffer)
            assetWriter.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        guard videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(newSampleBuffer)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished, sessionStarted, assetWriter.status != .failed else { return }
        guard let audioInput = audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    func finishWriting() async {
        guard markFinishedIfReady() else { return }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        if assetWriter.status == .writing {
            await assetWriter.finishWriting()
        }
    }

    private func markFinishedIfReady() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished, sessionStarted else { return false }
        isFinished = true
        return true
    }

    func cancelWriting() {
        lock.lock()
        isFinished = true
        lock.unlock()
        assetWriter.cancelWriting()
    }
}

// MARK: - Stream Output Delegate

class CaptureStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let bufferWriter: BufferWriter
    var onStreamError: (@Sendable (String) -> Void)?

    init(bufferWriter: BufferWriter) {
        self.bufferWriter = bufferWriter
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            bufferWriter.appendVideo(sampleBuffer)
        case .audio:
            bufferWriter.appendAudio(sampleBuffer)
        case .microphone:
            bufferWriter.appendAudio(sampleBuffer)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        onStreamError?(message)
    }
}

// MARK: - Errors

enum CaptureError: LocalizedError {
    case noDisplay
    case noWindow
    case noArea
    case writingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display selected for capture."
        case .noWindow: return "No window selected for capture."
        case .noArea: return "No area selected for capture."
        case .writingFailed(let msg): return "Writing failed: \(msg)"
        }
    }
}
