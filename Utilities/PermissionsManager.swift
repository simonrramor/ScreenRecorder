import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit
import CoreGraphics

@MainActor
class PermissionsManager: ObservableObject {
    @Published var hasScreenRecordingPermission: Bool = false
    @Published var hasMicrophonePermission: Bool = false

    func checkAllPermissions() async {
        checkScreenRecordingPermission()
        await checkMicrophonePermission()
    }

    func checkScreenRecordingPermission() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingPermission() {
        if CGPreflightScreenCaptureAccess() {
            hasScreenRecordingPermission = true
        } else {
            // This prompts the user once via the system dialog
            let granted = CGRequestScreenCaptureAccess()
            hasScreenRecordingPermission = granted
            if !granted {
                openScreenRecordingSettings()
            }
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

    func requestMicrophonePermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        hasMicrophonePermission = granted
        if !granted {
            openMicrophoneSettings()
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
