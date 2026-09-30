import Photos
import SqueezeCore
import SwiftUI

struct DuplicatesView: View {
    @Environment(DuplicateScanner.self) private var scanner
    @Environment(PhotoLibraryService.self) private var library

    @State private var confirmingDelete = false
    @State private var errorMessage: String?
    @State private var preview: PreviewTarget?

    var body: some View {
        @Bindable var scanner = scanner

        NavigationStack {
            List {
                Section {
                    Picker("Find", selection: $scanner.mode) {
                        ForEach(DuplicateScanner.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)

                    Text(scanner.mode.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Picker("Look in", selection: $scanner.scope) {
                        ForEach(DuplicateScanner.Scope.allCases) { Text($0.title).tag($0) }
                    }

                    if scanner.mode == .similar {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Sensitivity")
                                Spacer()
                                Text(sensitivityLabel)
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $scanner.sensitivity, in: 0...1) {
                                Text("Sensitivity")
                            } minimumValueLabel: {
                                Image(systemName: "equal.circle")
                            } maximumValueLabel: {
                                Image(systemName: "approximately.equal.circle")
                            }
                        }
                        Toggle("Only compare shots taken close together", isOn: $scanner.onlyNearbyInTime)
                    }

                    Button {
                        if scanner.isScanning { scanner.cancelScan() } else { scanner.scan() }
                    } label: {
                        HStack {
                            Spacer()
                            Text(scanner.isScanning ? "Stop Scan" : "Scan Library").bold()
                            Spacer()
                        }
                    }
                } footer: {
                    Text("Analysis runs on your device using small thumbnails. Results are cached, so later scans are much faster.")
                }

                phaseSection

                ForEach(scanner.groups) { group in
                    Section {
                        GroupGrid(group: group, assets: scanner.assets, selection: scanner.selection,
                                  onToggle: { scanner.toggle($0) },
                                  onPreview: { asset in preview = PreviewTarget(asset: asset) })
                        if scanner.isFullySelected(group) {
                            Label("All copies selected — nothing in this group would be kept.", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        HStack {
                            Text("\(group.members.count) items")
                            Spacer()
                            Text("\(Formatting.bytes(group.reclaimableBytes)) reclaimable")
                        }
                    }
                }
            }
            .navigationTitle("Clean Up")
            .toolbar {
                if !scanner.groups.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Select all but the best") { scanner.selectAllButKeepers() }
                            Button("Deselect all") { scanner.deselectAll() }
                        } label: {
                            Image(systemName: "checklist")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !scanner.selection.isEmpty {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        VStack(spacing: 2) {
                            Text("Delete \(scanner.selection.count) item\(scanner.selection.count == 1 ? "" : "s")")
                                .font(.headline)
                            Text("Frees \(Formatting.bytes(scanner.selectedBytes))")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .background(.bar)
                }
            }
            .confirmationDialog(
                "Delete \(scanner.selection.count) items?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await scanner.deleteSelected(using: library)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            } message: {
                Text("They'll be moved to Recently Deleted in Photos, where you can restore them for 30 days.")
            }
            .alert("Couldn't delete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $preview) { target in
                AssetPreview(asset: target.asset)
            }
        }
    }

    private var sensitivityLabel: String {
        switch scanner.sensitivity {
        case ..<0.34: return "Strict"
        case ..<0.67: return "Normal"
        default: return "Loose"
        }
    }

    @ViewBuilder
    private var phaseSection: some View {
        switch scanner.phase {
        case .idle:
            EmptyView()
        case .analyzing(let done, let total):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Analyzing \(done) of \(total)…")
                        .font(.subheadline.monospacedDigit())
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                }
            }
        case .grouping:
            Section {
                HStack {
                    ProgressView()
                    Text("Comparing…").padding(.leading, 8)
                }
            }
        case .finished:
            Section {
                if scanner.groups.isEmpty {
                    ContentUnavailableView(
                        "Nothing found",
                        systemImage: "checkmark.seal",
                        description: Text(scanner.mode == .duplicates
                                          ? "No duplicates in your library."
                                          : "No similar items found. Try a looser sensitivity.")
                    )
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(scanner.groups.count) groups found")
                            .font(.headline)
                        Text("Up to \(Formatting.bytes(scanner.totalReclaimableBytes)) can be freed. The best copy in each group (★) is kept by default — tap items to change what gets deleted.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
            }
        }
    }
}

private struct GroupGrid: View {
    let group: MediaGroup
    let assets: [String: PHAsset]
    let selection: Set<String>
    let onToggle: (String) -> Void
    let onPreview: (PHAsset) -> Void

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(group.members) { member in
                if let asset = assets[member.id] {
                    MemberCell(
                        member: member,
                        asset: asset,
                        isKeeper: member.id == group.keeperID,
                        isSelected: selection.contains(member.id)
                    )
                    .onTapGesture { onToggle(member.id) }
                    .contextMenu {
                        Button("Preview", systemImage: "eye") { onPreview(asset) }
                        Button(selection.contains(member.id) ? "Keep" : "Mark for deletion",
                               systemImage: selection.contains(member.id) ? "arrow.uturn.backward" : "trash") {
                            onToggle(member.id)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MemberCell: View {
    let member: HashedMedia
    let asset: PHAsset
    let isKeeper: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AssetThumbnail(asset: asset)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.black.opacity(0.35))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "trash.circle.fill" : "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, isSelected ? Color.red : Color.green)
                        .padding(4)
                }
                .overlay(alignment: .topLeading) {
                    if isKeeper {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(5)
                            .background(.black.opacity(0.5), in: Circle())
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if member.kind == .video {
                        Text(Formatting.duration(member.duration))
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(4)
                    }
                }
            Text(Formatting.bytes(member.fileSize))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(member.pixelWidth)×\(member.pixelHeight)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isKeeper ? "Best copy, " : "")\(isSelected ? "marked for deletion" : "kept"), \(Formatting.bytes(member.fileSize))")
    }
}
