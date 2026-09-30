import Foundation

/// Video codec used for the compressed output.
public enum VideoCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case hevc
    case h264

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hevc: return "HEVC (H.265)"
        case .h264: return "H.264"
        }
    }

    public var summary: String {
        switch self {
        case .hevc:
            return "About 35% smaller than H.264 at the same visual quality. Plays on all Apple devices from 2017 on."
        case .h264:
            return "Maximum compatibility with older devices, Windows PCs and web uploads, but larger files."
        }
    }

    /// Bitrate needed relative to H.264 for comparable visual quality.
    public var efficiencyFactor: Double {
        switch self {
        case .hevc: return 0.65
        case .h264: return 1.0
        }
    }
}

/// Upper bound for the output resolution, applied to the video's short side
/// so portrait and landscape videos are treated the same way.
public enum ResolutionLimit: String, Codable, CaseIterable, Identifiable, Sendable {
    case original
    case uhd2160
    case qhd1440
    case fhd1080
    case hd720
    case sd540

    public var id: String { rawValue }

    public var maxShortSide: Int? {
        switch self {
        case .original: return nil
        case .uhd2160: return 2160
        case .qhd1440: return 1440
        case .fhd1080: return 1080
        case .hd720: return 720
        case .sd540: return 540
        }
    }

    public var displayName: String {
        switch self {
        case .original: return "Keep original"
        case .uhd2160: return "4K (2160p)"
        case .qhd1440: return "1440p"
        case .fhd1080: return "Full HD (1080p)"
        case .hd720: return "HD (720p)"
        case .sd540: return "540p"
        }
    }
}

/// Upper bound for the output frame rate.
public enum FrameRateLimit: String, Codable, CaseIterable, Identifiable, Sendable {
    case original
    case fps60
    case fps30
    case fps24

    public var id: String { rawValue }

    public var maxFrameRate: Double? {
        switch self {
        case .original: return nil
        case .fps60: return 60
        case .fps30: return 30
        case .fps24: return 24
        }
    }

    public var displayName: String {
        switch self {
        case .original: return "Keep original"
        case .fps60: return "Up to 60 fps"
        case .fps30: return "Up to 30 fps"
        case .fps24: return "Up to 24 fps (cinematic)"
        }
    }
}

/// How aggressively the video stream is compressed. Expressed as the number of
/// bits spent per pixel per frame for H.264; HEVC scales this down by its
/// efficiency factor.
public enum QualityLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case maximum
    case high
    case balanced
    case compact
    case minimum

    public var id: String { rawValue }

    public var bitsPerPixel: Double {
        switch self {
        case .maximum: return 0.12
        case .high: return 0.09
        case .balanced: return 0.07
        case .compact: return 0.05
        case .minimum: return 0.035
        }
    }

    public var displayName: String {
        switch self {
        case .maximum: return "Maximum"
        case .high: return "High"
        case .balanced: return "Balanced"
        case .compact: return "Compact"
        case .minimum: return "Minimum"
        }
    }

    public var impactDescription: String {
        switch self {
        case .maximum:
            return "Visually indistinguishable from the original, even on a large screen."
        case .high:
            return "Differences are only visible when comparing still frames side by side."
        case .balanced:
            return "Looks great on phones and tablets. Fine detail in fast motion can soften slightly."
        case .compact:
            return "Good for sharing and casual viewing. Grass, water and low light may show blockiness."
        case .minimum:
            return "Smallest files. Noticeable artifacts in detailed or fast-moving scenes."
        }
    }
}

/// Bitrate of the re-encoded AAC audio track.
public enum AudioQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case high
    case standard
    case low

    public var id: String { rawValue }

    public var bitrate: Int {
        switch self {
        case .high: return 192_000
        case .standard: return 128_000
        case .low: return 64_000
        }
    }

    public var displayName: String {
        switch self {
        case .high: return "High (192 kbps)"
        case .standard: return "Standard (128 kbps)"
        case .low: return "Voice (64 kbps)"
        }
    }
}

/// Ready-made combinations of the settings above.
public enum CompressionPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case maximumQuality
    case balanced
    case spaceSaver
    case extreme
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .maximumQuality: return "Maximum Quality"
        case .balanced: return "Balanced"
        case .spaceSaver: return "Space Saver"
        case .extreme: return "Extreme"
        case .custom: return "Custom"
        }
    }

    public var summary: String {
        switch self {
        case .maximumQuality:
            return "Keeps resolution and frame rate. Typically saves 30–50% on videos recorded in H.264."
        case .balanced:
            return "Keeps resolution and frame rate with efficient HEVC encoding. Typically saves 50–70%."
        case .spaceSaver:
            return "Scales to 1080p at up to 30 fps. Typically saves 70–85%, ideal for everyday clips."
        case .extreme:
            return "Scales to 720p at up to 30 fps. Saves 85–95%; for videos you only want to keep as memories."
        case .custom:
            return "Choose codec, resolution, frame rate and quality yourself."
        }
    }

    public var symbolName: String {
        switch self {
        case .maximumQuality: return "sparkles.tv"
        case .balanced: return "scale.3d"
        case .spaceSaver: return "archivebox"
        case .extreme: return "arrow.down.right.and.arrow.up.left"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// The encoding parameters of this preset, or `nil` for `.custom`.
    public var parameters: EncodingParameters? {
        switch self {
        case .maximumQuality:
            return EncodingParameters(codec: .hevc, resolution: .original, frameRate: .original, quality: .maximum, audio: .high)
        case .balanced:
            return EncodingParameters(codec: .hevc, resolution: .original, frameRate: .original, quality: .balanced, audio: .standard)
        case .spaceSaver:
            return EncodingParameters(codec: .hevc, resolution: .fhd1080, frameRate: .fps30, quality: .compact, audio: .standard)
        case .extreme:
            return EncodingParameters(codec: .hevc, resolution: .hd720, frameRate: .fps30, quality: .minimum, audio: .low)
        case .custom:
            return nil
        }
    }
}

/// The parts of the settings that a preset controls.
public struct EncodingParameters: Codable, Equatable, Sendable {
    public var codec: VideoCodec
    public var resolution: ResolutionLimit
    public var frameRate: FrameRateLimit
    public var quality: QualityLevel
    public var audio: AudioQuality

    public init(codec: VideoCodec, resolution: ResolutionLimit, frameRate: FrameRateLimit, quality: QualityLevel, audio: AudioQuality) {
        self.codec = codec
        self.resolution = resolution
        self.frameRate = frameRate
        self.quality = quality
        self.audio = audio
    }
}

/// Everything the user can configure about video compression.
public struct CompressionSettings: Codable, Equatable, Sendable {
    public var preset: CompressionPreset
    public var encoding: EncodingParameters
    /// Move the original to "Recently Deleted" once the compressed copy is saved.
    public var deleteOriginals: Bool
    /// Skip a video (and keep the original) if compression would save less than this.
    public var minimumSavingsPercent: Int
    /// Hide and skip videos that this app produced itself.
    public var skipPreviouslyCompressed: Bool

    public static let `default` = CompressionSettings(preset: .balanced)

    public init(
        preset: CompressionPreset,
        deleteOriginals: Bool = true,
        minimumSavingsPercent: Int = 10,
        skipPreviouslyCompressed: Bool = true
    ) {
        self.preset = preset
        self.encoding = (preset.parameters ?? CompressionPreset.balanced.parameters)!
        self.deleteOriginals = deleteOriginals
        self.minimumSavingsPercent = minimumSavingsPercent
        self.skipPreviouslyCompressed = skipPreviouslyCompressed
    }

    /// Switch to a preset, overwriting the encoding parameters (except for `.custom`,
    /// which keeps the current parameters as a starting point).
    public mutating func apply(_ preset: CompressionPreset) {
        self.preset = preset
        if let parameters = preset.parameters {
            encoding = parameters
        }
    }

    /// Change one encoding parameter. The preset becomes whichever preset matches the
    /// resulting parameters, or `.custom` if none does.
    public mutating func setEncoding<Value>(_ keyPath: WritableKeyPath<EncodingParameters, Value>, to value: Value) {
        encoding[keyPath: keyPath] = value
        preset = Self.matchingPreset(for: encoding)
    }

    public static func matchingPreset(for encoding: EncodingParameters) -> CompressionPreset {
        CompressionPreset.allCases.first { $0.parameters == encoding } ?? .custom
    }
}
