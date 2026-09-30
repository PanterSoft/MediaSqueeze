import SqueezeCore
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings

    private var compression: CompressionSettings { settings.compression }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(CompressionPreset.allCases) { preset in
                        PresetRow(preset: preset, isSelected: compression.preset == preset) {
                            settings.presetBinding.wrappedValue = preset
                        }
                    }
                } header: {
                    Text("Preset")
                } footer: {
                    Text("Changing any option below switches to Custom automatically.")
                }

                Section {
                    Picker("Codec", selection: settings.encodingBinding(\.codec)) {
                        ForEach(VideoCodec.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Max resolution", selection: settings.encodingBinding(\.resolution)) {
                        ForEach(ResolutionLimit.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Frame rate", selection: settings.encodingBinding(\.frameRate)) {
                        ForEach(FrameRateLimit.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Quality", selection: settings.encodingBinding(\.quality)) {
                        ForEach(QualityLevel.allCases) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text("Video")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("**\(compression.encoding.quality.displayName):** \(compression.encoding.quality.impactDescription)")
                        Text("**\(compression.encoding.codec.displayName):** \(compression.encoding.codec.summary)")
                        Text("HDR videos are always encoded as 10-bit HEVC so their colors and brightness are preserved. Videos are never upscaled.")
                    }
                }

                Section {
                    Picker("Audio", selection: settings.encodingBinding(\.audio)) {
                        ForEach(AudioQuality.allCases) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Audio is re-encoded as stereo AAC. It's a small part of most files, so higher quality costs little space.")
                }

                Section {
                    EstimateRow(title: "1 min 4K 30 fps", source: .example4K, encoding: compression.encoding)
                    EstimateRow(title: "1 min 1080p 60 fps", source: .example1080p60, encoding: compression.encoding)
                    EstimateRow(title: "1 min 1080p 30 fps (H.264)", source: .example1080pH264, encoding: compression.encoding)
                } header: {
                    Text("What to expect")
                } footer: {
                    Text("Estimates based on typical iPhone recordings. The actual result depends on the content — calm scenes shrink more than busy ones.")
                }

                Section {
                    Toggle("Delete originals after compressing", isOn: settings.binding(\.deleteOriginals))
                    Stepper(value: settings.binding(\.minimumSavingsPercent), in: 0...80, step: 5) {
                        VStack(alignment: .leading) {
                            Text("Minimum savings")
                            Text("Keep the original if it would shrink less than \(compression.minimumSavingsPercent)%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Hide already compressed videos", isOn: settings.binding(\.skipPreviouslyCompressed))
                } header: {
                    Text("After compressing")
                } footer: {
                    Text("Compressed copies keep the original date, location, favorite status and albums. Deleted originals stay in Recently Deleted for 30 days — empty it in Photos to free the space right away.")
                }

                Section {
                    Button("Reset to defaults", role: .destructive) { settings.resetToDefaults() }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                    Text("All processing happens on this device. MediaSqueeze doesn't collect or upload any data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct PresetRow: View {
    let preset: CompressionPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: preset.symbolName)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(preset.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct EstimateRow: View {
    let title: String
    let source: SourceVideoInfo
    let encoding: EncodingParameters

    var body: some View {
        let plan = CompressionPlanner.plan(for: source, encoding: encoding)
        let original = source.fileSize ?? 0
        let savings = CompressionPlanner.savingsFraction(original: original, compressed: plan.estimatedFileSize)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(Formatting.bytes(original)) → \(Formatting.bytes(min(plan.estimatedFileSize, original)))")
                    .font(.subheadline.monospacedDigit())
            }
            HStack {
                Text("\(plan.width)×\(plan.height) · \(Int(plan.frameRate.rounded())) fps · \(plan.codec.displayName) · \(String(format: "%.1f", Double(plan.videoBitrate) / 1_000_000)) Mbps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("−" + Formatting.percent(savings))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }
}

private extension SourceVideoInfo {
    /// iPhone 4K30 HEVC: ~170 MB per minute.
    static let example4K = SourceVideoInfo(width: 3840, height: 2160, frameRate: 30, duration: 60,
                                           videoBitrate: 22_400_000, audioBitrate: 160_000, fileSize: 170_000_000)
    /// iPhone 1080p60 HEVC: ~90 MB per minute.
    static let example1080p60 = SourceVideoInfo(width: 1920, height: 1080, frameRate: 60, duration: 60,
                                                videoBitrate: 11_800_000, audioBitrate: 160_000, fileSize: 90_000_000)
    /// iPhone 1080p30 "Most Compatible" (H.264): ~130 MB per minute.
    static let example1080pH264 = SourceVideoInfo(width: 1920, height: 1080, frameRate: 30, duration: 60,
                                                  videoBitrate: 17_100_000, audioBitrate: 160_000, fileSize: 130_000_000)
}
