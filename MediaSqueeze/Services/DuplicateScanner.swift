import CoreGraphics
import Observation
import Photos
import SqueezeCore
import UIKit

/// Finds duplicate and similar photos/videos by comparing perceptual hashes of their thumbnails.
@MainActor
@Observable
final class DuplicateScanner {
    enum Mode: String, CaseIterable, Identifiable {
        case duplicates
        case similar

        var id: String { rawValue }
        var title: String { self == .duplicates ? "Duplicates" : "Similar" }
        var explanation: String {
            switch self {
            case .duplicates:
                return "Identical copies, including resized or re-saved versions (e.g. from messaging apps or imports)."
            case .similar:
                return "Near-identical shots such as bursts and retakes. Review each group before deleting."
            }
        }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case photos
        case videos
        case all

        var id: String { rawValue }
        var title: String {
            switch self {
            case .photos: return "Photos"
            case .videos: return "Videos"
            case .all: return "Both"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case analyzing(done: Int, total: Int)
        case grouping
        case finished
        case failed(String)
    }

    var mode: Mode = .duplicates
    var scope: Scope = .photos
    /// 0...1, only used in `.similar` mode.
    var sensitivity: Double = 0.4
    /// Only compare shots taken within 10 minutes of each other (similar mode).
    var onlyNearbyInTime = true

    private(set) var phase: Phase = .idle
    private(set) var groups: [MediaGroup] = []
    private(set) var assets: [String: PHAsset] = [:]
    /// IDs marked for deletion.
    var selection: Set<String> = []

    private let cache = HashCache()
    private var scanTask: Task<Void, Never>?

    var isScanning: Bool {
        switch phase {
        case .analyzing, .grouping: return true
        default: return false
        }
    }

    var selectedBytes: Int64 {
        groups.flatMap(\.members).filter { selection.contains($0.id) }.reduce(0) { $0 + $1.fileSize }
    }

    var totalReclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    var options: SimilarityOptions {
        switch mode {
        case .duplicates: return .duplicates
        case .similar: return .similar(sensitivity: sensitivity, withinSeconds: onlyNearbyInTime ? 10 * 60 : nil)
        }
    }

    // MARK: - Scanning

    func scan() {
        scanTask?.cancel()
        scanTask = Task { await runScan() }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func runScan() async {
        groups = []
        selection = []
        let fetched = Self.fetchAssets(scope: scope)
        assets = Dictionary(fetched.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        phase = .analyzing(done: 0, total: fetched.count)

        var hashed: [HashedMedia] = []
        hashed.reserveCapacity(fetched.count)
        let cache = self.cache
        let maxConcurrent = 8
        var nextIndex = 0
        var done = 0

        await withTaskGroup(of: HashedMedia?.self) { group in
            func enqueueNext() {
                guard nextIndex < fetched.count else { return }
                let asset = fetched[nextIndex]
                nextIndex += 1
                group.addTask { await Self.hashedMedia(for: asset, cache: cache) }
            }
            for _ in 0..<maxConcurrent { enqueueNext() }

            while let result = await group.next() {
                if let result { hashed.append(result) }
                done += 1
                if done % 20 == 0 || done == fetched.count {
                    phase = .analyzing(done: done, total: fetched.count)
                }
                if Task.isCancelled {
                    group.cancelAll()
                } else {
                    enqueueNext()
                }
            }
        }
        await cache.save()

        guard !Task.isCancelled else {
            phase = .idle
            return
        }

        phase = .grouping
        let options = self.options
        let items = hashed
        let result = await Task.detached(priority: .userInitiated) {
            SimilarityGrouper.groups(from: items, options: options)
        }.value

        groups = result
        selection = Set(result.flatMap { group in group.members.map(\.id).filter { $0 != group.keeperID } })
        phase = .finished
    }

    nonisolated private static func fetchAssets(scope: Scope) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        switch scope {
        case .photos:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .videos:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .all:
            options.predicate = NSPredicate(
                format: "mediaType == %d || mediaType == %d",
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            )
        }
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    nonisolated private static func hashedMedia(for asset: PHAsset, cache: HashCache) async -> HashedMedia? {
        let identifier = asset.localIdentifier
        let modified = asset.modificationDate ?? asset.creationDate
        let hash: UInt64
        if let cached = await cache.hash(for: identifier, modified: modified) {
            hash = cached
        } else {
            // Photos keeps small thumbnails on device even for iCloud-optimised libraries.
            guard let image = await PhotoKitBridge.image(
                for: asset, targetSize: CGSize(width: 64, height: 64), contentMode: .aspectFit, allowNetwork: false
            ), let computed = Self.hash(of: image) else {
                return nil
            }
            hash = computed
            await cache.store(computed, for: identifier, modified: modified)
        }
        return HashedMedia(
            id: identifier,
            hash: hash,
            kind: asset.mediaType == .video ? .video : .photo,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            creationDate: asset.creationDate,
            duration: asset.duration,
            fileSize: PhotoKitBridge.fileSize(of: asset),
            isFavorite: asset.isFavorite
        )
    }

    /// Renders the image into a 32×32 grayscale buffer and computes its dHash.
    nonisolated static func hash(of image: UIImage) -> UInt64? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        return PerceptualHash.differenceHash(grayscale: pixels, width: side, height: side)
    }

    // MARK: - Selection & deletion

    func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    func selectAllButKeepers() {
        selection = Set(groups.flatMap { group in group.members.map(\.id).filter { $0 != group.keeperID } })
    }

    func deselectAll() {
        selection = []
    }

    /// Whether every member of a group is selected (which would delete all copies).
    func isFullySelected(_ group: MediaGroup) -> Bool {
        group.members.allSatisfy { selection.contains($0.id) }
    }

    func deleteSelected(using library: PhotoLibraryService) async throws {
        let ids = Array(selection)
        let toDelete = ids.compactMap { assets[$0] }
        try await library.deleteAssets(toDelete)

        let deleted = Set(ids)
        groups = groups.compactMap { group in
            let remaining = group.members.filter { !deleted.contains($0.id) }
            guard remaining.count > 1 else { return nil }
            let keeper = remaining.contains { $0.id == group.keeperID } ? group.keeperID : KeeperRanking.best(of: remaining).id
            return MediaGroup(members: remaining, keeperID: keeper)
        }
        selection.subtract(deleted)
        for id in deleted { assets[id] = nil }
    }
}

/// Persists hashes between scans so re-scanning a large library is fast.
actor HashCache {
    private struct Entry: Codable {
        var hash: UInt64
        var modified: TimeInterval
    }

    private struct Store: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    private static let version = 1
    private var entries: [String: Entry] = [:]
    private var isDirty = false
    private var isLoaded = false
    private let url: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        url = caches.appendingPathComponent("perceptual-hashes.json")
    }

    func hash(for id: String, modified: Date?) -> UInt64? {
        loadIfNeeded()
        guard let entry = entries[id], entry.modified == (modified?.timeIntervalSince1970 ?? 0) else { return nil }
        return entry.hash
    }

    func store(_ hash: UInt64, for id: String, modified: Date?) {
        loadIfNeeded()
        entries[id] = Entry(hash: hash, modified: modified?.timeIntervalSince1970 ?? 0)
        isDirty = true
    }

    func save() {
        guard isDirty else { return }
        if let data = try? JSONEncoder().encode(Store(version: Self.version, entries: entries)) {
            try? data.write(to: url, options: .atomic)
            isDirty = false
        }
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.version == Self.version else { return }
        entries = store.entries
    }
}
