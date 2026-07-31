import Foundation
import AppKit

struct MediaItem: Identifiable, Hashable {
    /// The standardized file path is stable across library reloads, unlike a
    /// freshly generated UUID which made SwiftUI treat every item as new.
    let id: String
    let url: URL
    let type: MediaType
    let createdAt: Date
    let fileSize: Int64
    var duration: TimeInterval?
    var thumbnail: NSImage?

    enum MediaType: String, CaseIterable, Identifiable, Sendable {
        case recording = "Recording"
        case screenshot = "Screenshot"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .recording: return "video.fill"
            case .screenshot: return "photo.fill"
            }
        }
    }

    var fileName: String {
        url.lastPathComponent
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }

    var formattedDuration: String? {
        guard let duration = duration else { return nil }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id
    }
}
