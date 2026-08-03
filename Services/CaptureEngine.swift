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
    private var recordingGeneration: UUID?
    private let videoQueue = DispatchQueue(label: "com.captr.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.captr.capture.system-audio", qos: .userInitiated)

    var configuration = CaptureConfiguration()

    /// Refreshes the cached capture targets and returns the exact
    /// ScreenCaptureKit snapshot they came from. Area screenshots use the
    /// returned snapshot to prepare their filter before the selection overlay
    /// appears, avoiding another content enumeration after mouse-up.
    @discardableResult
    func refreshAvailableContent(onScreenWindowsOnly: Bool = true) async -> SCShareableContent? {
        errorMessage = nil

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: onScreenWindowsOnly
            )
            availableDisplays = content.displays
            availableWindows = content.windows.filter { $0.isOnScreen && $0.title?.isEmpty == false }
            refreshSelectedCaptureTargets()
            return content
        } catch {
            availableDisplays = []
            availableWindows = []
            configuration.selectedDisplay = nil
            configuration.selectedWindow = nil
            errorMessage = "Failed to get screen content: \(error.localizedDescription)"
            return nil
        }
    }

    func startRecording() async {
        guard state == .idle else { return }
        let generation = UUID()
        recordingGeneration = generation
        state = .preparing
        errorMessage = nil

        do {
            await refreshAvailableContent()
            guard recordingGeneration == generation, state == .preparing else { return }

            let filter = try createContentFilter()
            let streamConfig = createStreamConfiguration()

            let outputDir = MediaLibraryManager.recordingsDirectory
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let url = CaptureFileURL.unique(in: outputDir, prefix: "Screen Recording", pathExtension: "mp4")
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
            guard writer.canAdd(vInput) else {
                throw CaptureError.writingFailed("The video encoder could not be added")
            }
            writer.add(vInput)

            func makeAudioInput() throws -> AVAssetWriterInput {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192000
                ]
                let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioWriterInput.expectsMediaDataInRealTime = true
                guard writer.canAdd(audioWriterInput) else {
                    throw CaptureError.writingFailed("An audio encoder could not be added")
                }
                writer.add(audioWriterInput)
                return audioWriterInput
            }

            let systemAudioInput = configuration.captureSystemAudio ? try makeAudioInput() : nil
            let microphoneInput = configuration.captureMicrophone ? try makeAudioInput() : nil
            let bufferWriter = BufferWriter(
                assetWriter: writer,
                videoInput: vInput,
                systemAudioInput: systemAudioInput,
                microphoneInput: microphoneInput
            )
            let output = CaptureStreamOutput(bufferWriter: bufferWriter)
            output.onStreamError = { [weak self] message in
                Task { @MainActor [weak self] in
                    await self?.handleUnexpectedStreamStop(message: message, generation: generation)
                }
            }

            let captureStream = SCStream(filter: filter, configuration: streamConfig, delegate: output)
            try captureStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoQueue)

            if configuration.captureSystemAudio {
                try captureStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
            }

            // Store the session before awaiting startup so cancellation can
            // tear it down during actor reentrancy.
            stream = captureStream
            streamOutput = output
            try await captureStream.startCapture()
            guard recordingGeneration == generation, state == .preparing else {
                try? await captureStream.stopCapture()
                bufferWriter.cancelWriting()
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                return
            }

            if configuration.captureMicrophone {
                audioManager.onError = { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.onWarning?("Recording continues without microphone: \(message)")
                    }
                }
                audioManager.startMicrophoneCapture { [weak bufferWriter] sampleBuffer in
                    bufferWriter?.appendMicrophone(sampleBuffer)
                }
            }

            state = .recording
            recordingStartDate = .now
            startDurationTimer()

        } catch {
            guard recordingGeneration == generation else { return }
            if let stream {
                try? await stream.stopCapture()
            }
            stream = nil
            streamOutput?.bufferWriter.cancelWriting()
            streamOutput = nil
            if let outputURL, FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            cleanup()
        }
    }

    func stopRecording() async -> URL? {
        guard state.isCapturing else { return nil }
        recordingGeneration = nil
        state = .stopping
        errorMessage = nil

        stopDurationTimer()
        audioManager.stopMicrophoneCapture()

        var stopCaptureWarning: String?
        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                stopCaptureWarning = "The screen stream reported an error while stopping: \(error.localizedDescription)"
            }
        }
        stream = nil

        var writerError: Error?
        var receivedFrames = true
        var writerStatus: AVAssetWriter.Status = .unknown
        if let output = streamOutput {
            await output.bufferWriter.finishWriting()
            writerError = output.bufferWriter.writerError
            receivedFrames = output.bufferWriter.didReceiveFrames
            writerStatus = output.bufferWriter.writerStatus
        }
        streamOutput = nil

        let url = outputURL
        cleanup()

        if let url = url {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            let writerCompleted = writerStatus == .completed && writerError == nil && receivedFrames && size > 0
            if !writerCompleted {
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

        if let stopCaptureWarning {
            onWarning?(stopCaptureWarning)
        }
        return url
    }

    func cancelRecording() async {
        recordingGeneration = nil
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

    private func handleUnexpectedStreamStop(message: String, generation: UUID) async {
        guard recordingGeneration == generation, state.isActive else { return }
        recordingGeneration = nil
        state = .stopping
        stopDurationTimer()
        audioManager.stopMicrophoneCapture()

        stream = nil
        streamOutput?.bufferWriter.cancelWriting()
        streamOutput = nil
        if let outputURL, FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let reportedError = "Recording stopped: \(message)"
        cleanup()
        errorMessage = reportedError
        onStreamError?(reportedError)
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
        recordingGeneration = nil
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
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
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
    var writerStatus: AVAssetWriter.Status { assetWriter.status }

    init(
        assetWriter: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        systemAudioInput: AVAssetWriterInput?,
        microphoneInput: AVAssetWriterInput?
    ) {
        self.assetWriter = assetWriter
        self.videoInput = videoInput
        self.systemAudioInput = systemAudioInput
        self.microphoneInput = microphoneInput
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

        guard let pixelBufferPool else { return }
        var dstPixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &dstPixelBuffer) == kCVReturnSuccess,
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
            guard assetWriter.startWriting() else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(newSampleBuffer)
            assetWriter.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        guard videoInput.isReadyForMoreMediaData else { return }
        if !videoInput.append(newSampleBuffer) {
            isFinished = true
        }
    }

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        appendAudio(sampleBuffer, to: systemAudioInput)
    }

    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        appendAudio(sampleBuffer, to: microphoneInput)
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished, sessionStarted, assetWriter.status != .failed else { return }
        guard let input, input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer) {
            isFinished = true
        }
    }

    func finishWriting() async {
        guard markFinishedIfReady() else {
            cancelWriting()
            return
        }

        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()

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
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            bufferWriter.appendVideo(sampleBuffer)
        case .audio:
            bufferWriter.appendSystemAudio(sampleBuffer)
        case .microphone:
            bufferWriter.appendMicrophone(sampleBuffer)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        onStreamError?(message)
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let rawStatus = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: rawStatus) else {
            return false
        }
        return status == .complete
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
