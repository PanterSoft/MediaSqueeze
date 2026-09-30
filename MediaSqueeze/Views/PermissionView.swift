import Photos
import SwiftUI

struct PermissionView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(\.openURL) private var openURL

    private var isDenied: Bool {
        library.authorizationStatus == .denied || library.authorizationStatus == .restricted
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            VStack(spacing: 12) {
                Text("Free up space in Photos")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("MediaSqueeze re-encodes your videos into much smaller files and finds duplicate and similar photos you can remove. Everything happens on your device; nothing is uploaded.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(symbol: "film.stack", text: "Compress videos with the quality you choose")
                FeatureRow(symbol: "square.on.square", text: "Find duplicates and near-identical shots")
                FeatureRow(symbol: "trash.slash", text: "Deleted items stay in Recently Deleted for 30 days")
            }
            .padding()
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
            Spacer()
            if isDenied {
                Text("Access to Photos is turned off. Allow full access in Settings to continue.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Text("Open Settings").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    Task { await library.requestAccess() }
                } label: {
                    Text("Allow Access to Photos").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}
