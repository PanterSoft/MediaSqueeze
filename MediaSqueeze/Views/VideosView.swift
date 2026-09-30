import Photos
import SqueezeCore
import SwiftUI

struct VideosView: View {
    enum SortOrder: String, CaseIterable, Identifiable {
        case largest, savings, newest, oldest, longest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .largest: return "Largest first"
            case .savings: return "Most savings first"
            case .newest: return "Newest first"
            case .oldest: return "Oldest first"
            case .longest: return "Longest first"
            }
        }
    }

    @Environment(PhotoLibraryService.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(CompressionQueue.self) private var queue

    @State private var sortOrder: SortOrder = .largest
    @State private var selection: Set<String> = []
    @State private var showingQueue = false
    @State private var preview: PreviewTarget?

    private var encoding: EncodingParameters { settings.compression.encoding }

    private var visibleVideos: [VideoItem] {
        var items = library.videos
        if settings.compression.skipPreviouslyCompressed {
            items.removeAll { library.isCompressedByApp($0) }
        }
        switch sortOrder {
        case .largest: items.sort { $0.fileSize > $1.fileSize }
        case .savings: items.sort { estimatedSavings($0) > estimatedSavings($1) }
        case .newest: items.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .oldest: items.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        case .longest: items.sort { $0.duration > $1.duration }
        }
        return items
    }

    private var selectedItems: [VideoItem] {
        visibleVideos.filter { selection.contains($0.id) }
    }

    private func estimatedSavings(_ item: VideoItem) -> Int64 {
        CompressionPlanner.estimatedSavings(for: item.estimatedSource, encoding: encoding)
    }

    var body: some View {
        NavigationStack {
            let videos = visibleVideos
            List {
                Section {
                    SummaryCard(
                        videoCount: videos.count,
                        totalBytes: videos.reduce(0) { $0 + $1.fileSize },
                        potentialSavings: videos.reduce(0) { $0 + estimatedSavings($1) },
                        presetName: settings.compression.preset.displayName
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if videos.isEmpty && library.hasLoadedVideos {
                    ContentUnavailableView(
                        "No videos to compress",
                        systemImage: "film",
                        description: Text("Videos in your library will show up here.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(videos) { item in
                            VideoRow(
                                item: item,
                                estimatedBytes: CompressionPlanner.plan(for: item.estimatedSource, encoding: encoding).estimatedFileSize,
                                isSelected: selection.contains(item.id),
                                isCompressed: library.isCompressedByApp(item),
                                onToggle: { toggle(item) },
                                onPreview: { preview = PreviewTarget(asset: item.asset) }
                            )
                        }
                    } header: {
                        HStack {
                            Text("\(videos.count) videos")
                            Spacer()
                            Menu {
                                Button("Select all") { selection = Set(videos.map(\.id)) }
                                Button("Select larger than 100 MB") {
                                    selection = Set(videos.filter { $0.fileSize > 100_000_000 }.map(\.id))
                                }
                                Button("Select larger than 500 MB") {
                                    selection = Set(videos.filter { $0.fileSize > 500_000_000 }.map(\.id))
                                }
                                Button("Select older than 1 year") {
                                    let cutoff = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now
                                    selection = Set(videos.filter { ($0.creationDate ?? .now) < cutoff }.map(\.id))
                                }
                                if !selection.isEmpty {
                                    Button("Deselect all", role: .destructive) { selection = [] }
                                }
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                                    .font(.footnote.weight(.semibold))
                            }
                            .textCase(nil)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Compress Videos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(SortOrder.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                }
                if queue.isRunning || !queue.jobs.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingQueue = true
                        } label: {
                            if queue.isRunning {
                                ProgressView(value: queue.overallProgress)
                                    .progressViewStyle(.circular)
                            } else {
                                Image(systemName: "list.bullet.clipboard")
                            }
                        }
                    }
                }
            }
            .overlay {
                if library.isLoadingVideos && !library.hasLoadedVideos {
                    ProgressView("Reading your library…")
                }
            }
            .refreshable { await library.reloadVideos() }
            .safeAreaInset(edge: .bottom) {
                if !selection.isEmpty {
                    CompressBar(
                        count: selectedItems.count,
                        savings: selectedItems.reduce(0) { $0 + estimatedSavings($1) },
                        isBusy: queue.isRunning,
                        action: startCompression
                    )
                }
            }
            .sheet(isPresented: $showingQueue) {
                CompressionProgressView()
            }
            .sheet(item: $preview) { target in
                AssetPreview(asset: target.asset)
            }
            .onChange(of: library.videos) { _, videos in
                let ids = Set(videos.map(\.id))
                selection.formIntersection(ids)
            }
        }
    }

    private func toggle(_ item: VideoItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    private func startCompression() {
        let items = selectedItems
        guard !items.isEmpty, !queue.isRunning else { return }
        queue.start(items: items, settings: settings.compression, library: library)
        selection = []
        showingQueue = true
    }
}

private struct SummaryCard: View {
    let videoCount: Int
    let totalBytes: Int64
    let potentialSavings: Int64
    let presetName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Videos use")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(Formatting.bytes(totalBytes))
                        .font(.system(.largeTitle, design: .rounded).bold())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("You could save")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("~" + Formatting.bytes(potentialSavings))
                        .font(.system(.title, design: .rounded).bold())
                        .foregroundStyle(.green)
                }
            }
            if totalBytes > 0 {
                GeometryReader { proxy in
                    let fraction = min(1, Double(potentialSavings) / Double(totalBytes))
                    ZStack(alignment: .leading) {
                        Capsule().fill(.fill.tertiary)
                        Capsule().fill(.green.gradient)
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 10)
            }
            Text("\(videoCount) videos · estimate with the \(presetName) preset")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct VideoRow: View {
    let item: VideoItem
    let estimatedBytes: Int64
    let isSelected: Bool
    let isCompressed: Bool
    let onToggle: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Deselect" : "Select")

            Button(action: onPreview) {
                AssetThumbnail(asset: item.asset)
                    .frame(width: 64, height: 64)
                    .overlay(alignment: .bottomTrailing) {
                        Text(Formatting.duration(item.duration))
                            .font(.caption2.monospacedDigit().bold())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(3)
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Formatting.date(item.creationDate))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if isCompressed {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                            .accessibilityLabel("Compressed")
                    }
                }
                Text(Formatting.resolution(width: item.pixelWidth, height: item.pixelHeight))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(Formatting.bytes(item.fileSize))
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                    Text("~" + Formatting.bytes(min(estimatedBytes, item.fileSize)))
                        .foregroundStyle(.green)
                }
                .font(.caption.monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}

private struct CompressBar: View {
    let count: Int
    let savings: Int64
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(isBusy ? "Compression in progress…" : "Compress \(count) video\(count == 1 ? "" : "s")")
                    .font(.headline)
                if !isBusy {
                    Text("Save about \(Formatting.bytes(savings))")
                        .font(.caption)
                        .opacity(0.85)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isBusy)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.bar)
    }
}
