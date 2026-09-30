import AVFoundation
import Photos
import UIKit

/// async/await wrappers around the callback-based PhotoKit APIs.
enum PhotoKitBridge {
    static let imageManager = PHCachingImageManager()

    /// Requests a single image. Uses `.highQualityFormat` so the handler fires exactly once.
    static func image(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        allowNetwork: Bool = true
    ) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Loads the playable asset for a video, downloading it from iCloud if needed.
    static func avAsset(for asset: PHAsset, downloadProgress: (@Sendable (Double) -> Void)? = nil) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        if let downloadProgress {
            options.progressHandler = { progress, _, _, _ in downloadProgress(progress) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: CancellationError())
                } else {
                    let underlying = info?[PHImageErrorKey] as? Error
                    continuation.resume(throwing: CompressionError.assetUnavailable(underlying?.localizedDescription))
                }
            }
        }
    }

    static func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    /// Size of the asset's primary resource on disk (or in iCloud), in bytes.
    static func fileSize(of asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferredTypes: [PHAssetResourceType] = asset.mediaType == .video
            ? [.fullSizeVideo, .video]
            : [.fullSizePhoto, .photo]
        let resource = preferredTypes.lazy.compactMap { type in resources.first { $0.type == type } }.first
            ?? resources.first
        // `fileSize` is not public API on PHAssetResource but is KVC-accessible and widely relied upon.
        return (resource?.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }
}
