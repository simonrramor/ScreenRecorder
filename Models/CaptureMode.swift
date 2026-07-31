import Foundation
import ScreenCaptureKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case fullScreen = "Full Screen"
    case window = "Window"
    case area = "Area"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .fullScreen: return "rectangle.inset.filled"
        case .window: return "macwindow"
        case .area: return "rectangle.dashed"
        }
    }
}

enum CaptureType: String, CaseIterable, Identifiable {
    case recording = "Recording"
    case screenshot = "Screenshot"
    case textCapture = "Text Capture"
    case translateCapture = "Translate Capture"

    var id: String { rawValue }
}

enum RecordingState: Equatable {
    case idle
    case preparing
    case countdown(Int)
    case recording
    case paused
    case stopping

    var isActive: Bool {
        switch self {
        case .preparing, .countdown, .recording, .paused, .stopping:
            return true
        case .idle:
            return false
        }
    }

    var isCapturing: Bool {
        self == .recording || self == .paused
    }
}

struct CaptureConfiguration {
    var mode: CaptureMode = .fullScreen
    var captureSystemAudio: Bool = true
    var captureMicrophone: Bool = false
    var showCursor: Bool = true
    var frameRate: Int = 60
    var resolution: CaptureResolution = .native
    var selectedDisplay: SCDisplay?
    var selectedWindow: SCWindow?
    var selectedArea: CGRect?
}

enum CaptureResolution: String, CaseIterable, Identifiable {
    case native = "Native"
    case hd1080 = "1080p"
    case hd720 = "720p"

    var id: String { rawValue }
}
