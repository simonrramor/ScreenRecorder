import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit
import CoreGraphics

@MainActor
class PermissionsManager: ObservableObject {
    @Published var hasScreenRecordingPermission: Bool = false
    @Published var hasMicrophonePermission: Bool = false
    @Published var hasCameraPermission: Bool = false

    func checkAllPermissions() async {
        checkScreenRecordingPermission()
        await checkCameraPermission()
        await checkMicrophonePermission()
    }

    func checkScreenRecordingPermission() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            hasScreenRecordingPermission = true
            return true
        } else {
            // This prompts the user once via the system dialog
            let granted = CGRequestScreenCaptureAccess()
            hasScreenRecordingPermission = granted
            if !granted {
                openScreenRecordingSettings()
            }
            return granted
        }
    }

    func checkMicrophonePermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasMicrophonePermission = true
        case .notDetermined:
            hasMicrophonePermission = false
        default:
            hasMicrophonePermission = false
        }
    }

    func checkCameraPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            hasCameraPermission = true
        case .notDetermined:
            hasCameraPermission = false
        default:
            hasCameraPermission = false
        }
    }

    func requestCameraPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            hasCameraPermission = true
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            hasCameraPermission = granted
            if !granted {
                openCameraSettings()
            }
            return granted
        default:
            hasCameraPermission = false
            openCameraSettings()
            return false
        }
    }

    @discardableResult
    func requestMicrophonePermission() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        hasMicrophonePermission = granted
        if !granted {
            openMicrophoneSettings()
        }
        return granted
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
