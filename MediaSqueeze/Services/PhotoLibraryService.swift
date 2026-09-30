import Observation
import Photos
import SqueezeCore
import UIKit

/// A video in the user's library together with its size on disk.
struct VideoItem: Identifiable, Hashable {
    let id: String
    let asset: PHAsset
    let fileSize: Int64

    var duration: TimeInterval { asset.duration }
    var pixelWidth: Int { asset.pixelWidth }
    var pixelHeight: Int { asset.pixelHeight }
    var creationDate: Date? { asset.creationDate }

    /// Metadata-only description used for size estimates before the video is loaded.
    var estimatedSource: SourceVideoInfo {
        SourceVideoInfo(width: pixelWidth, height: pixelHeight, duration: duration, fileSize: fileSize)
    }

    static func == (lhs: VideoItem, rhs: VideoItem) -> Bool { lhs.id == rhs.id && lhs.fileSize == rhs.fileSize }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
@Observable
final class PhotoLibraryService {
    private(set) var authorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var videos: [VideoItem] = []
    private(set) var isLoadingVideos = false
    private(set) var hasLoadedVideos = false
    /// Local identifiers of videos this app created, so they can be skipped next time.
    private(set) var compressedIdentifiers: Set<String>

    private let defaults: UserDefaults
    private var changeObserver: LibraryChangeObserver?
    private var reloadTask: Task<Void, Never>?
    private static let compressedKey = "compressedAssetIdentifiers"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        compressedIdentifiers = Set(defaults.stringArray(forKey: Self.compressedKey) ?? [])
    }

    var hasAccess: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var totalVideoBytes: Int64 {
        videos.reduce(0) { $0 + $1.fileSize }
    }

    func isCompressedByApp(_ item: VideoItem) -> Bool {
        compressedIdentifiers.contains(item.id)
    }

    // MARK: - Authorization

    func requestAccess() async {
        authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if hasAccess {
            startObservingChanges()
            await reloadVideos()
        }
    }

    func refreshAuthorization() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if hasAccess { startObservingChanges() }
    }

    private func startObservingChanges() {
        guard changeObserver == nil else { return }
        let observer = LibraryChangeObserver { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        PHPhotoLibrary.shared().register(observer)
        changeObserver = observer
    }

    /// Coalesces bursts of library change notifications into one reload.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await reloadVideos()
        }
    }

    // MARK: - Videos

    func reloadVideos() async {
        guard hasAccess else { return }
        isLoadingVideos = true
        let items = await Task.detached(priority: .userInitiated) {
            Self.fetchVideoItems()
        }.value
        videos = items
        isLoadingVideos = false
        hasLoadedVideos = true
    }

    nonisolated private static func fetchVideoItems() -> [VideoItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .video, options: options)
        var items: [VideoItem] = []
        items.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            items.append(VideoItem(id: asset.localIdentifier, asset: asset, fileSize: PhotoKitBridge.fileSize(of: asset)))
        }
        return items
    }

    // MARK: - Writing

    /// Adds a compressed video to the library, copying date, location, favourite state and
    /// album membership from the original. Returns the new asset's local identifier.
    func saveCompressedVideo(at url: URL, replacing original: PHAsset) async throws -> String {
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil)
        let placeholder = PlaceholderBox()

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(with: .video, fileURL: url, options: options)
            request.creationDate = original.creationDate
            request.location = original.location
            request.isFavorite = original.isFavorite
            request.isHidden = original.isHidden

            guard let created = request.placeholderForCreatedAsset else { return }
            placeholder.identifier = created.localIdentifier
            albums.enumerateObjects { album, _, _ in
                guard album.canPerform(.addContent),
                      let albumRequest = PHAssetCollectionChangeRequest(for: album) else { return }
                albumRequest.addAssets([created] as NSArray)
            }
        }

        guard let identifier = placeholder.identifier else {
            throw CompressionError.saveFailed
        }
        compressedIdentifiers.insert(identifier)
        defaults.set(Array(compressedIdentifiers), forKey: Self.compressedKey)
        return identifier
    }

    /// Moves assets to "Recently Deleted". iOS shows its own confirmation dialog.
    func deleteAssets(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    func deleteAssets(withIdentifiers identifiers: [String]) async throws {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        try await deleteAssets(assets)
    }
}

private final class PlaceholderBox: @unchecked Sendable {
    var identifier: String?
}

private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
