import Foundation

/// What we know about a source video before compressing it.
public struct SourceVideoInfo: Equatable, Sendable {
    /// Encoded (un-rotated) pixel width.
    public var width: Int
    /// Encoded (un-rotated) pixel height.
    public var height: Int
    /// Nominal frame rate, if known.
    public var frameRate: Double?
    public var duration: TimeInterval
    /// Average video bitrate in bits per second, if known.
    public var videoBitrate: Double?
    /// Average audio bitrate in bits per second, if known.
    public var audioBitrate: Double?
    public var hasAudio: Bool
    public var fileSize: Int64?
    /// HLG or PQ transfer function (e.g. iPhone Dolby Vision / HDR recordings).
    public var isHDR: Bool

    public init(
        width: Int,
        height: Int,
        frameRate: Double? = nil,
        duration: TimeInterval,
        videoBitrate: Double? = nil,
        audioBitrate: Double? = nil,
        hasAudio: Bool = true,
        fileSize: Int64? = nil,
        isHDR: Bool = false
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.duration = duration
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.hasAudio = hasAudio
        self.fileSize = fileSize
        self.isHDR = isHDR
    }

    /// Frame rate assumed when the real one is unknown (e.g. estimates from Photos metadata).
    public static let assumedFrameRate: Double = 30

    /// The known video bitrate, or one derived from file size and duration.
    public var effectiveVideoBitrate: Double? {
        if let videoBitrate, videoBitrate > 0 { return videoBitrate }
        guard let fileSize, fileSize > 0, duration > 0 else { return nil }
        let total = Double(fileSize) * 8 / duration
        let audio = hasAudio ? (audioBitrate ?? 128_000) : 0
        return max(total - audio, total * 0.5)
    }
}

/// The concrete encoder configuration for one video.
public struct CompressionPlan: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var codec: VideoCodec
    public var videoBitrate: Int
    /// `nil` when the source has no audio track.
    public var audioBitrate: Int?
    /// Encode as 10-bit HEVC and keep the HDR transfer function.
    public var preservesHDR: Bool
    public var estimatedFileSize: Int64

    public var isDownscaled: Bool = false
    public var isFrameRateReduced: Bool = false
}

public enum CompressionPlanner {
    /// Never go below this video bitrate, no matter how small the frame is.
    public static let minimumVideoBitrate = 250_000
    /// Container overhead added to size estimates.
    static let containerOverhead = 1.02
    /// When the planned bitrate would exceed the source, cap it to this fraction of the source.
    static let sourceBitrateCap = 0.9

    public static func plan(for source: SourceVideoInfo, settings: CompressionSettings) -> CompressionPlan {
        plan(for: source, encoding: settings.encoding)
    }

    public static func plan(for source: SourceVideoInfo, encoding: EncodingParameters) -> CompressionPlan {
        let (width, height) = outputDimensions(width: source.width, height: source.height, limit: encoding.resolution)
        let sourceFrameRate = (source.frameRate ?? 0) > 0 ? source.frameRate! : SourceVideoInfo.assumedFrameRate
        let frameRate = min(sourceFrameRate, encoding.frameRate.maxFrameRate ?? sourceFrameRate)

        // H.264 cannot carry the 10-bit HDR signal we read from the source; HDR always goes to HEVC.
        let codec: VideoCodec = source.isHDR ? .hevc : encoding.codec

        let bitsPerPixel = encoding.quality.bitsPerPixel * codec.efficiencyFactor * (source.isHDR ? 1.15 : 1.0)
        var videoBitrate = Double(width * height) * frameRate * bitsPerPixel
        if let sourceBitrate = source.effectiveVideoBitrate {
            // Re-encoding above the source bitrate only makes the file bigger.
            videoBitrate = min(videoBitrate, sourceBitrate * sourceBitrateCap)
        }
        let finalVideoBitrate = max(Int(videoBitrate.rounded()), minimumVideoBitrate)

        var audioBitrate: Int?
        if source.hasAudio {
            let target = encoding.audio.bitrate
            if let sourceAudio = source.audioBitrate, sourceAudio > 0 {
                audioBitrate = min(target, max(AudioQuality.low.bitrate, Int(sourceAudio)))
            } else {
                audioBitrate = target
            }
        }

        let totalBitrate = Double(finalVideoBitrate + (audioBitrate ?? 0))
        let estimated = Int64((totalBitrate * max(source.duration, 0) / 8 * containerOverhead).rounded())

        var plan = CompressionPlan(
            width: width,
            height: height,
            frameRate: frameRate,
            codec: codec,
            videoBitrate: finalVideoBitrate,
            audioBitrate: audioBitrate,
            preservesHDR: source.isHDR,
            estimatedFileSize: estimated
        )
        plan.isDownscaled = width < source.width || height < source.height
        plan.isFrameRateReduced = frameRate < sourceFrameRate - 0.5
        return plan
    }

    /// Estimated bytes saved (never negative). Requires `source.fileSize`.
    public static func estimatedSavings(for source: SourceVideoInfo, encoding: EncodingParameters) -> Int64 {
        guard let fileSize = source.fileSize else { return 0 }
        return max(0, fileSize - plan(for: source, encoding: encoding).estimatedFileSize)
    }

    /// Fraction (0...1) of the original size that would be saved.
    public static func savingsFraction(original: Int64, compressed: Int64) -> Double {
        guard original > 0 else { return 0 }
        return max(0, Double(original - compressed) / Double(original))
    }

    /// Whether a result is worth keeping given the user's minimum savings setting.
    public static func isWorthKeeping(original: Int64, compressed: Int64, minimumSavingsPercent: Int) -> Bool {
        savingsFraction(original: original, compressed: compressed) * 100 >= Double(minimumSavingsPercent)
            && compressed < original
    }

    /// Scale so the short side fits the limit, keeping aspect ratio and even dimensions
    /// (required by the 4:2:0 encoders).
    public static func outputDimensions(width: Int, height: Int, limit: ResolutionLimit) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (evenDimension(Double(width)), evenDimension(Double(height))) }
        let shortSide = min(width, height)
        var scale = 1.0
        if let maxShortSide = limit.maxShortSide, shortSide > maxShortSide {
            scale = Double(maxShortSide) / Double(shortSide)
        }
        return (evenDimension(Double(width) * scale), evenDimension(Double(height) * scale))
    }

    static func evenDimension(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }
}
