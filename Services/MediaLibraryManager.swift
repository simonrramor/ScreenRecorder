import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct MediaLibraryDirectories: Sendable {
    let recordings: URL
    let screenshots: URL

    static var live: MediaLibraryDirectories {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let movies = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Movies", isDirectory: true)
        let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Downloads", isDirectory: true)
        return MediaLibraryDirectories(
            recordings: downloads,
            screenshots: movies.appendingPathComponent("Captr/Screenshots", isDirectory: true)
        )
    }
}

private struct MediaDescriptor: Sendable {
    let url: URL
    let type: MediaItem.MediaType
    let createdAt: Date
    let fileSize: Int64
    let duration: TimeInterval?
    let thumbnailData: Data?
}

private struct MediaLibrarySnapshot: Sendable {
    let recordings: [MediaDescriptor]
    let screenshots: [MediaDescriptor]
}

@MainActor
final class MediaLibraryManager: ObservableObject {
    @Published var recordings: [MediaItem] = []
    @Published var screenshots: [MediaItem] = []
    @Published var allItems: [MediaItem] = []
    @Published var errorMessage: String?

    private let directories: MediaLibraryDirectories
    private let trashHandler: (URL) throws -> Void

    static var baseDirectory: URL {
        screenshotsDirectory.deletingLastPathComponent()
    }

    /// Recordings land in Downloads where they're easy to find. The library
    /// only indexes files matching Captr's own naming.
    static var recordingsDirectory: URL { MediaLibraryDirectories.live.recordings }
    static var screenshotsDirectory: URL { MediaLibraryDirectories.live.screenshots }

    private nonisolated static let recordingFileNamePrefixes = [
        "Screen Recording ",
        "iPhone Mirror ",
        "Android Device "
    ]

    init(
        directories: MediaLibraryDirectories = .live,
        trashHandler: @escaping (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.directories = directories
        self.trashHandler = trashHandler
    }

    /// Whether a Downloads file is one Captr produced. This prevents scans or
    /// deletion controls from ever including unrelated user videos.
    nonisolated static func isRecognizedRecording(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { return false }
        return recordingFileNamePrefixes.contains { fileName.hasPrefix($0) }
    }

    func loadLibrary() async {
        errorMessage = nil
        do {
            let snapshot = try await Self.loadSnapshot(from: directories)
            recordings = snapshot.recordings.map(Self.makeItem)
            screenshots = snapshot.screenshots.map(Self.makeItem)
            allItems = (recordings + screenshots).sorted { $0.createdAt > $1.createdAt }
        } catch {
            errorMessage = "Could not load the media library: \(error.localizedDescription)"
        }
    }

    @concurrent
    private nonisolated static func loadSnapshot(
        from directories: MediaLibraryDirectories
    ) async throws -> MediaLibrarySnapshot {
        let fm = FileManager.default
        try fm.createDirectory(at: directories.recordings, withIntermediateDirectories: true)
        try fm.createDirectory(at: directories.screenshots, withIntermediateDirectories: true)

        let recordings = await loadDescriptors(from: directories.recordings, type: .recording)
        let screenshots = await loadDescriptors(from: directories.screenshots, type: .screenshot)
        return MediaLibrarySnapshot(recordings: recordings, screenshots: screenshots)
    }

    private nonisolated static func loadDescriptors(
        from directory: URL,
        type: MediaItem.MediaType
    ) async -> [MediaDescriptor] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var descriptors: [MediaDescriptor] = []
        descriptors.reserveCapacity(files.count)
        for file in files {
            guard let descriptor = await makeDescriptor(for: file, type: type) else { continue }
            descriptors.append(descriptor)
        }
        return descriptors.sorted { $0.createdAt > $1.createdAt }
    }

    private nonisolated static func makeDescriptor(
        for file: URL,
        type: MediaItem.MediaType
    ) async -> MediaDescriptor? {
        let ext = file.pathExtension.lowercased()
        switch type {
        case .recording:
            guard isRecognizedRecording(fileName: file.lastPathComponent) else { return nil }
        case .screenshot:
            guard ["png", "jpg", "jpeg", "tiff"].contains(ext) else { return nil }
        }

        let values = try? file.resourceValues(forKeys: [
            .fileSizeKey, .creationDateKey, .contentModificationDateKey, .isRegularFileKey
        ])
        guard values?.isRegularFile != false else { return nil }

        var duration: TimeInterval?
        var thumbnailData: Data?
        if type == .recording {
            let asset = AVURLAsset(url: file)
            duration = try? await asset.load(.duration).seconds
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            if let (image, _) = try? await generator.image(at: .zero) {
                thumbnailData = pngData(from: image)
            }
        } else {
            thumbnailData = imageThumbnailData(for: file)
        }

        return MediaDescriptor(
            url: file,
            type: type,
            createdAt: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
            fileSize: Int64(values?.fileSize ?? 0),
            duration: duration,
            thumbnailData: thumbnailData
        )
    }

    private nonisolated static func imageThumbnailData(for url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 400
              ] as CFDictionary) else { return nil }
        return pngData(from: image)
    }

    private nonisolated static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func makeItem(_ descriptor: MediaDescriptor) -> MediaItem {
        MediaItem(
            id: descriptor.url.standardizedFileURL.path,
            url: descriptor.url,
            type: descriptor.type,
            createdAt: descriptor.createdAt,
            fileSize: descriptor.fileSize,
            duration: descriptor.duration,
            thumbnail: descriptor.thumbnailData.flatMap(NSImage.init(data:))
        )
    }

    func deleteItem(_ item: MediaItem) {
        errorMessage = nil
        do {
            try trashHandler(item.url)
            recordings.removeAll { $0.id == item.id }
            screenshots.removeAll { $0.id == item.id }
            allItems.removeAll { $0.id == item.id }
        } catch {
            errorMessage = "Could not move \(item.fileName) to the Trash: \(error.localizedDescription)"
        }
    }

    func revealInFinder(_ item: MediaItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openInDefaultApp(_ item: MediaItem) {
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            errorMessage = "\(item.fileName) no longer exists."
            return
        }
        NSWorkspace.shared.open(item.url)
    }

    func addRecording(at url: URL) async {
        guard let descriptor = await Self.makeDescriptor(for: url, type: .recording) else { return }
        insert(Self.makeItem(descriptor), into: &recordings)
    }

    func addScreenshot(at url: URL) async {
        guard let descriptor = await Self.makeDescriptor(for: url, type: .screenshot) else { return }
        insert(Self.makeItem(descriptor), into: &screenshots)
    }

    private func insert(_ item: MediaItem, into typedItems: inout [MediaItem]) {
        typedItems.removeAll { $0.id == item.id }
        typedItems.insert(item, at: 0)
        allItems.removeAll { $0.id == item.id }
        allItems.insert(item, at: 0)
    }
}
