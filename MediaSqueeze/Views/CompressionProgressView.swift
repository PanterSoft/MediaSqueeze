import SwiftUI

struct CompressionProgressView: View {
    @Environment(CompressionQueue.self) private var queue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(queue.isRunning ? "Compressing…" : "Finished")
                                .font(.headline)
                            Spacer()
                            Text("\(queue.completedCount) of \(queue.jobs.count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: queue.overallProgress)
                        HStack {
                            Label("Saved \(Formatting.bytes(queue.totalSavedBytes))", systemImage: "externaldrive.badge.checkmark")
                                .foregroundStyle(.green)
                            Spacer()
                        }
                        .font(.subheadline.weight(.semibold))
                        if queue.isRunning {
                            Text("Keep the app open. Your screen stays on while compressing.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let message = originalsMessage {
                    Section {
                        Label(message.text, systemImage: message.symbol)
                            .font(.subheadline)
                    }
                }

                Section("Videos") {
                    ForEach(queue.jobs) { job in
                        JobRow(job: job)
                    }
                }
            }
            .navigationTitle("Compression")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if queue.isRunning {
                        Button("Stop", role: .destructive) { queue.cancel() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(queue.isRunning ? "Hide" : "Done") {
                        if !queue.isRunning { queue.reset() }
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(false)
    }

    private var originalsMessage: (text: String, symbol: String)? {
        switch queue.originalsOutcome {
        case .none: return nil
        case .deleting: return ("Waiting for you to confirm deleting the originals…", "hourglass")
        case .deleted(let count):
            return ("\(count) original\(count == 1 ? "" : "s") moved to Recently Deleted. Empty it in Photos to free the space immediately.", "trash")
        case .kept(let reason): return (reason, "exclamationmark.triangle")
        }
    }
}

private struct JobRow: View {
    let job: CompressionQueue.Job

    var body: some View {
        HStack(spacing: 12) {
            AssetThumbnail(asset: job.item.asset, cornerRadius: 6)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(Formatting.date(job.item.creationDate))
                    .font(.subheadline.weight(.medium))
                status
            }
            Spacer(minLength: 0)
            trailingIcon
        }
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .pending:
            Text("Waiting · \(Formatting.bytes(job.item.fileSize))")
                .font(.caption).foregroundStyle(.secondary)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloading from iCloud…").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: progress)
            }
        case .compressing(let progress):
            VStack(alignment: .leading, spacing: 2) {
                Text("Compressing · \(Formatting.percent(progress))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                ProgressView(value: progress)
            }
        case .saving:
            Text("Saving to Photos…").font(.caption).foregroundStyle(.secondary)
        case .done(let saved):
            Text("\(Formatting.bytes(job.item.fileSize)) → \(Formatting.bytes(job.outputBytes ?? 0)) · saved \(Formatting.bytes(saved))")
                .font(.caption.monospacedDigit()).foregroundStyle(.green)
        case .skipped(let reason):
            Text(reason).font(.caption).foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.red)
        case .cancelled:
            Text("Stopped").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailingIcon: some View {
        switch job.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped:
            Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}
