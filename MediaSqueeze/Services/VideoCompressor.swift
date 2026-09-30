import AVFoundation
import CoreMedia
import SqueezeCore
import VideoToolbox

enum CompressionError: LocalizedError {
    case assetUnavailable(String?)
    case noVideoTrack
    case notWorthIt(savingsPercent: Int)
    case readerFailed(String?)
    case writerFailed(String?)
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .assetUnavailable(let reason):
            return "Couldn't load the video" + (reason.map { ": \($0)" } ?? ".")
        case .noVideoTrack:
            return "The file contains no video track."
        case .notWorthIt(let percent):
            return percent <= 0
                ? "Already well compressed — the original was kept."
                : "Would only save \(percent)% — the original was kept."
        case .readerFailed(let reason):
            return "Decoding failed" + (reason.map { ": \($0)" } ?? ".")
        case .writerFailed(let reason):
            return "Encoding failed" + (reason.map { ": \($0)" } ?? ".")
        case .saveFailed:
            return "Couldn't save the compressed video to Photos."
        }
    }

    /// Skips are expected outcomes, not failures.
    var isSkip: Bool {
        if case .notWorthIt = self { return true }
        return false
    }
}

struct CompressionOutput {
    let url: URL
    let plan: CompressionPlan
    let originalBytes: Int64
    let outputBytes: Int64
}

/// Re-encodes a video with AVAssetReader/AVAssetWriter so bitrate, resolution, frame rate,
/// codec and bit depth can all be controlled (AVAssetExportSession only offers fixed presets).
final class VideoCompressor: Sendable {
    func compress(
        _ asset: AVAsset,
        originalBytes: Int64,
        settings: CompressionSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CompressionOutput {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompressionError.noVideoTrack
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration)
        let (naturalSize, transform, nominalFrameRate, videoDataRate, formatDescriptions) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions
        )
        let audioDataRate = try await audioTrack?.load(.estimatedDataRate)
        let colorProperties = Self.colorProperties(of: formatDescriptions.first)

        let source = SourceVideoInfo(
            width: Int(naturalSize.width.rounded()),
            height: Int(naturalSize.height.rounded()),
            frameRate: nominalFrameRate > 0 ? Double(nominalFrameRate) : nil,
            duration: duration.seconds,
            videoBitrate: videoDataRate > 0 ? Double(videoDataRate) : nil,
            audioBitrate: audioDataRate.flatMap { $0 > 0 ? Double($0) : nil },
            hasAudio: audioTrack != nil,
            fileSize: originalBytes > 0 ? originalBytes : nil,
            isHDR: colorProperties.isHDR
        )
        let plan = CompressionPlanner.plan(for: source, settings: settings)

        if originalBytes > 0,
           !CompressionPlanner.isWorthKeeping(original: originalBytes, compressed: plan.estimatedFileSize,
                                              minimumSavingsPercent: settings.minimumSavingsPercent) {
            let percent = CompressionPlanner.savingsFraction(original: originalBytes, compressed: plan.estimatedFileSize)
            throw CompressionError.notWorthIt(savingsPercent: Int(percent * 100))
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("squeeze-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        do {
            try await transcode(
                asset: asset, videoTrack: videoTrack, audioTrack: audioTrack, transform: transform,
                colorProperties: colorProperties, plan: plan, sourceFrameRate: source.frameRate,
                duration: duration, outputURL: outputURL, progress: progress
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let outputBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if originalBytes > 0,
           !CompressionPlanner.isWorthKeeping(original: originalBytes, compressed: outputBytes,
                                              minimumSavingsPercent: settings.minimumSavingsPercent) {
            try? FileManager.default.removeItem(at: outputURL)
            let percent = CompressionPlanner.savingsFraction(original: originalBytes, compressed: outputBytes)
            throw CompressionError.notWorthIt(savingsPercent: Int(percent * 100))
        }

        return CompressionOutput(url: outputURL, plan: plan, originalBytes: originalBytes, outputBytes: outputBytes)
    }

    // MARK: - Transcoding

    private func transcode(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        transform: CGAffineTransform,
        colorProperties: ColorProperties,
        plan: CompressionPlan,
        sourceFrameRate: Double?,
        duration: CMTime,
        outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw CompressionError.readerFailed(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
        // Keep QuickTime metadata (location, capture device, creation date).
        if let metadata = try? await asset.load(.metadata) {
            writer.metadata = metadata.filter { $0.keySpace == .quickTimeMetadata || $0.keySpace == .quickTimeUserData }
        }

        // Video: decode to 4:2:0 (10-bit for HDR), let the writer scale and encode.
        let pixelFormat = plan.preservesHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw CompressionError.readerFailed("Unsupported video format") }
        reader.add(videoOutput)

        // AVAssetWriterInput raises an exception for invalid settings, so validate first and
        // fall back to letting the encoder pick color tags from the pixel buffers.
        var videoSettings = Self.videoSettings(for: plan, color: colorProperties)
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            videoSettings = Self.videoSettings(for: plan, color: ColorProperties())
        }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw CompressionError.writerFailed("This device can't encode \(plan.codec.displayName) at \(plan.width)×\(plan.height)")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { throw CompressionError.writerFailed("Unsupported video settings") }
        writer.add(videoInput)

        // Audio: decode to stereo PCM, re-encode as AAC.
        var audioPipe: (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
        if let audioTrack, let audioBitrate = plan.audioBitrate {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: Self.pcmSettings)
            output.alwaysCopiesSampleData = false
            let aacSettings = Self.aacSettings(bitrate: audioBitrate)
            if writer.canApply(outputSettings: aacSettings, forMediaType: .audio), reader.canAdd(output) {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
                input.expectsMediaDataInRealTime = false
                guard writer.canAdd(input) else { throw CompressionError.writerFailed("Unsupported audio settings") }
                reader.add(output)
                writer.add(input)
                audioPipe = (output, input)
            }
        }

        guard reader.startReading() else { throw CompressionError.readerFailed(reader.error?.localizedDescription) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw CompressionError.writerFailed(writer.error?.localizedDescription)
        }
        writer.startSession(atSourceTime: .zero)

        let frameDropper = FrameDropper(
            targetFrameRate: plan.frameRate,
            isActive: plan.frameRate < (sourceFrameRate ?? plan.frameRate) - 0.5
        )
        let progressReporter = ProgressReporter(duration: duration.seconds, report: progress)
        let session = TranscodeSession(reader: reader, writer: writer)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let group = DispatchGroup()

                group.enter()
                Self.pump(
                    output: videoOutput, input: videoInput, reader: reader,
                    queue: DispatchQueue(label: "squeeze.video", qos: .userInitiated),
                    onSample: { sample in
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        guard frameDropper.shouldKeep(time) else { return false }
                        progressReporter.update(time)
                        return true
                    },
                    completion: { group.leave() }
                )

                if let audioPipe {
                    group.enter()
                    Self.pump(
                        output: audioPipe.output, input: audioPipe.input, reader: reader,
                        queue: DispatchQueue(label: "squeeze.audio", qos: .userInitiated),
                        onSample: { _ in true },
                        completion: { group.leave() }
                    )
                }

                group.notify(queue: .global(qos: .userInitiated)) {
                    session.finish(continuation: continuation)
                }
            }
        } onCancel: {
            session.cancel()
        }
    }

    /// Moves samples from a reader output to a writer input until the output is drained.
    /// `onSample` returns `false` to drop a sample.
    private static func pump(
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        reader: AVAssetReader,
        queue: DispatchQueue,
        onSample: @escaping @Sendable (CMSampleBuffer) -> Bool,
        completion: @escaping @Sendable () -> Void
    ) {
        let state = PumpState()
        input.requestMediaDataWhenReady(on: queue) {
            guard !state.isFinished else { return }
            while input.isReadyForMoreMediaData {
                guard reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
                    state.isFinished = true
                    input.markAsFinished()
                    completion()
                    return
                }
                guard onSample(sample) else { continue }
                if !input.append(sample) {
                    state.isFinished = true
                    reader.cancelReading()
                    input.markAsFinished()
                    completion()
                    return
                }
            }
        }
    }

    // MARK: - Settings

    private static func videoSettings(for plan: CompressionPlan, color: ColorProperties) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: plan.videoBitrate,
            AVVideoExpectedSourceFrameRateKey: Int(plan.frameRate.rounded()),
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        switch plan.codec {
        case .hevc:
            compression[AVVideoProfileLevelKey] = plan.preservesHDR
                ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                : kVTProfileLevel_HEVC_Main_AutoLevel as String
            if plan.preservesHDR {
                compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto as String
            }
        case .h264:
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        }

        var settings: [String: Any] = [
            AVVideoCodecKey: plan.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let dictionary = color.dictionary {
            settings[AVVideoColorPropertiesKey] = dictionary
        }
        return settings
    }

    private static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVChannelLayoutKey: stereoLayout,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    private static func aacSettings(bitrate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: stereoLayout,
            AVEncoderBitRateKey: bitrate,
        ]
    }

    private static let stereoLayout: Data = {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }()

    // MARK: - Color

    struct ColorProperties {
        var primaries: String?
        var transferFunction: String?
        var matrix: String?

        var isHDR: Bool {
            transferFunction == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                || transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        }

        static let supportedPrimaries: Set<String> = [
            AVVideoColorPrimaries_ITU_R_709_2, AVVideoColorPrimaries_P3_D65, AVVideoColorPrimaries_ITU_R_2020,
        ]
        static let supportedTransferFunctions: Set<String> = [
            AVVideoTransferFunction_ITU_R_709_2, AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoTransferFunction_SMPTE_ST_2084_PQ,
        ]
        static let supportedMatrices: Set<String> = [
            AVVideoYCbCrMatrix_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_601_4, AVVideoYCbCrMatrix_ITU_R_2020,
        ]

        /// Writer color settings; the CoreMedia and AVFoundation constants share the same string values.
        var dictionary: [String: String]? {
            guard let primaries, let transferFunction, let matrix,
                  Self.supportedPrimaries.contains(primaries),
                  Self.supportedTransferFunctions.contains(transferFunction),
                  Self.supportedMatrices.contains(matrix) else { return nil }
            return [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transferFunction,
                AVVideoYCbCrMatrixKey: matrix,
            ]
        }
    }

    static func colorProperties(of description: CMFormatDescription?) -> ColorProperties {
        guard let description else { return ColorProperties() }
        func value(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(description, extensionKey: key) as? String
        }
        return ColorProperties(
            primaries: value(kCMFormatDescriptionExtension_ColorPrimaries),
            transferFunction: value(kCMFormatDescriptionExtension_TransferFunction),
            matrix: value(kCMFormatDescriptionExtension_YCbCrMatrix)
        )
    }
}

// MARK: - Helpers shared between the pump queues

/// Finishes (or cancels) the writer once both pumps are done.
private final class TranscodeSession: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let lock = NSLock()
    private var isCancelled = false

    init(reader: AVAssetReader, writer: AVAssetWriter) {
        self.reader = reader
        self.writer = writer
    }

    func cancel() {
        lock.withLock { isCancelled = true }
        reader.cancelReading()
    }

    func finish(continuation: CheckedContinuation<Void, Error>) {
        let cancelled = lock.withLock { isCancelled }
        if cancelled || reader.status == .cancelled && writer.status != .failed {
            writer.cancelWriting()
            continuation.resume(throwing: CancellationError())
            return
        }
        if reader.status == .failed {
            writer.cancelWriting()
            continuation.resume(throwing: CompressionError.readerFailed(reader.error?.localizedDescription))
            return
        }
        if writer.status == .failed {
            continuation.resume(throwing: CompressionError.writerFailed(writer.error?.localizedDescription))
            return
        }
        writer.finishWriting { [writer] in
            if writer.status == .completed {
                continuation.resume()
            } else {
                continuation.resume(throwing: CompressionError.writerFailed(writer.error?.localizedDescription))
            }
        }
    }
}

private final class PumpState: @unchecked Sendable {
    var isFinished = false
}

/// Drops frames to reach a lower frame rate by keeping one frame per target interval.
private final class FrameDropper: @unchecked Sendable {
    private let targetFrameRate: Double
    private let isActive: Bool
    private var lastBucket: Int64 = .min

    init(targetFrameRate: Double, isActive: Bool) {
        self.targetFrameRate = targetFrameRate
        self.isActive = isActive
    }

    func shouldKeep(_ time: CMTime) -> Bool {
        guard isActive, time.isNumeric else { return true }
        let bucket = Int64((time.seconds * targetFrameRate + 0.001).rounded(.down))
        guard bucket != lastBucket else { return false }
        lastBucket = bucket
        return true
    }
}

/// Throttles progress callbacks to whole-percent changes.
private final class ProgressReporter: @unchecked Sendable {
    private let duration: Double
    private let report: @Sendable (Double) -> Void
    private var lastPercent = -1

    init(duration: Double, report: @escaping @Sendable (Double) -> Void) {
        self.duration = duration
        self.report = report
    }

    func update(_ time: CMTime) {
        guard duration > 0, time.isNumeric else { return }
        let fraction = min(max(time.seconds / duration, 0), 1)
        let percent = Int(fraction * 100)
        guard percent != lastPercent else { return }
        lastPercent = percent
        report(fraction)
    }
}
