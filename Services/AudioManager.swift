import Foundation
import AVFoundation
import CoreMedia

/// All mutable capture state and delegate delivery are serialized on
/// `sessionQueue`; the unchecked conformance documents that invariant for
/// AVFoundation's pre-concurrency delegate APIs.
final class AudioManager: NSObject, @unchecked Sendable {
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var bufferHandler: (@Sendable (CMSampleBuffer) -> Void)?
    private let sessionQueue = DispatchQueue(label: "com.screenrecorder.audio")

    /// Called on the session queue when microphone capture cannot start, so
    /// the recording UI can tell the user instead of failing silently.
    var onError: (@Sendable (String) -> Void)?

    func startMicrophoneCapture(handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        bufferHandler = handler

        sessionQueue.async { [weak self] in
            self?.setupCaptureSession()
        }
    }

    func stopMicrophoneCapture() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            self?.captureSession = nil
            self?.audioOutput = nil
            self?.bufferHandler = nil
        }
    }

    private func setupCaptureSession() {
        let session = AVCaptureSession()
        session.beginConfiguration()

        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            onError?("no microphone available")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: microphone)
            guard session.canAddInput(input) else {
                onError?("the microphone is unavailable")
                return
            }
            session.addInput(input)
        } catch {
            onError?(error.localizedDescription)
            return
        }

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sessionQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()
        session.startRunning()

        captureSession = session
        audioOutput = output
    }

    static func availableMicrophones() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discoverySession.devices
    }
}

extension AudioManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        bufferHandler?(sampleBuffer)
    }
}
