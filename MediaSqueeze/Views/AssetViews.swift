import AVKit
import Photos
import SwiftUI

/// Square thumbnail of a library asset, loaded lazily.
struct AssetThumbnail: View {
    let asset: PHAsset
    var cornerRadius: CGFloat = 8

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.fill.tertiary)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
            .task(id: asset.localIdentifier) {
                let side = max(proxy.size.width, proxy.size.height) * displayScale
                image = await PhotoKitBridge.image(for: asset, targetSize: CGSize(width: side, height: side))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// Full-screen preview of a photo or video.
struct AssetPreview: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if asset.mediaType == .video {
                    if let player {
                        VideoPlayer(player: player)
                            .onAppear { player.play() }
                    } else {
                        ProgressView().tint(.white)
                    }
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(Formatting.date(asset.creationDate)).font(.subheadline.bold())
                        Text("\(asset.pixelWidth) × \(asset.pixelHeight) · \(Formatting.bytes(PhotoKitBridge.fileSize(of: asset)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task {
            if asset.mediaType == .video {
                if let item = await PhotoKitBridge.playerItem(for: asset) {
                    player = AVPlayer(playerItem: item)
                }
            } else {
                image = await PhotoKitBridge.image(for: asset, targetSize: CGSize(width: 2048, height: 2048), contentMode: .aspectFit)
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// Makes `PHAsset` usable with `.sheet(item:)`.
struct PreviewTarget: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}
