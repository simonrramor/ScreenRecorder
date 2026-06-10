import Foundation
import AppKit
import AVFoundation

@MainActor
class MediaLibraryManager: ObservableObject {
    @Published var recordings: [MediaItem] = []
    @Published var screenshots: [MediaItem] = []
    @Published var allItems: [MediaItem] = []

    static var baseDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Captr")
    }

    /// Recordings land in Downloads where they're easy to find. The library
    /// only indexes files matching Captr's own naming so it never has to
    /// scan (or thumbnail) unrelated videos living there.
    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    private static let recordingFileNamePrefixes = [
        "Screen Recording ",
        "iPhone Mirror ",
        "Android Device "
    ]

    /// Whether a Downloads file is one Captr produced — gates which videos the
    /// library indexes (and may delete) so it never touches unrelated files.
    nonisolated static func isRecognizedRecording(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { return false }
        return recordingFileNamePrefixes.contains { fileName.hasPrefix($0) }
    }

    static var screenshotsDirectory: URL {
        baseDirectory.appendingPathComponent("Screenshots")
    }

    func loadLibrary() async {
        let fm = FileManager.default

        try? fm.createDirectory(at: Self.recordingsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.screenshotsDirectory, withIntermediateDirectories: true)

        recordings = await loadItems(from: Self.recordingsDirectory, type: .recording)
        screenshots = await loadItems(from: Self.screenshotsDirectory, type: .screenshot)
        allItems = (recordings + screenshots).sorted { $0.createdAt > $1.createdAt }
    }

    private func loadItems(from directory: URL, type: MediaItem.MediaType) async -> [MediaItem] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [
            .fileSizeKey, .creationDateKey
        ]) else {
            return []
        }

        var items: [MediaItem] = []
        for file in files {
            if let item = await makeItem(for: file, type: type) {
                items.append(item)
            }
        }

        return items.sorted { $0.createdAt > $1.createdAt }
    }

    private func makeItem(for file: URL, type: MediaItem.MediaType) async -> MediaItem? {
        let fm = FileManager.default
        let ext = file.pathExtension.lowercased()
        let isValidType: Bool
        switch type {
        case .recording:
            isValidType = Self.isRecognizedRecording(fileName: file.lastPathComponent)
        case .screenshot:
            isValidType = ["png", "jpg", "jpeg", "tiff"].contains(ext)
        }

        guard isValidType else { return nil }

        let attributes = try? fm.attributesOfItem(atPath: file.path)
        let fileSize = (attributes?[.size] as? Int64) ?? 0
        let createdAt = (attributes?[.creationDate] as? Date) ?? Date()

        var duration: TimeInterval?
        var thumbnail: NSImage?

        if type == .recording {
            let asset = AVURLAsset(url: file)
            duration = try? await asset.load(.duration).seconds
            thumbnail = await generateVideoThumbnail(for: file)
        } else {
            thumbnail = NSImage(contentsOf: file)
            if let thumb = thumbnail {
                let maxSize: CGFloat = 200
                let ratio = min(maxSize / thumb.size.width, maxSize / thumb.size.height, 1.0)
                let newSize = NSSize(width: thumb.size.width * ratio, height: thumb.size.height * ratio)
                let resized = NSImage(size: newSize)
                resized.lockFocus()
                thumb.draw(in: NSRect(origin: .zero, size: newSize))
                resized.unlockFocus()
                thumbnail = resized
            }
        }

        return MediaItem(
            id: UUID(),
            url: file,
            type: type,
            createdAt: createdAt,
            fileSize: fileSize,
            duration: duration,
            thumbnail: thumbnail
        )
    }

    private func generateVideoThumbnail(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)

        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }

    func deleteItem(_ item: MediaItem) {
        // Trash rather than unlink so an accidental delete is recoverable.
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        recordings.removeAll { $0.id == item.id }
        screenshots.removeAll { $0.id == item.id }
        allItems.removeAll { $0.id == item.id }
    }

    func revealInFinder(_ item: MediaItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openInDefaultApp(_ item: MediaItem) {
        NSWorkspace.shared.open(item.url)
    }

    /// Appends a single freshly saved file instead of rescanning the whole
    /// library (which regenerates every thumbnail) after each capture.
    func addRecording(at url: URL) async {
        guard let item = await makeItem(for: url, type: .recording) else { return }
        recordings.insert(item, at: 0)
        allItems.insert(item, at: 0)
    }

    func addScreenshot(at url: URL) async {
        guard let item = await makeItem(for: url, type: .screenshot) else { return }
        screenshots.insert(item, at: 0)
        allItems.insert(item, at: 0)
    }
}
