import XCTest
@testable import SqueezeCore

final class CompressionPlannerTests: XCTestCase {
    private let fourK = SourceVideoInfo(
        width: 3840, height: 2160, frameRate: 30, duration: 60,
        videoBitrate: 22_000_000, audioBitrate: 256_000, fileSize: 170_000_000
    )

    func testOriginalResolutionIsKept() {
        let plan = CompressionPlanner.plan(for: fourK, settings: CompressionSettings(preset: .balanced))
        XCTAssertEqual(plan.width, 3840)
        XCTAssertEqual(plan.height, 2160)
        XCTAssertFalse(plan.isDownscaled)
        XCTAssertEqual(plan.codec, .hevc)
    }

    func testDownscaleUsesShortSideForPortraitVideos() {
        let dims = CompressionPlanner.outputDimensions(width: 2160, height: 3840, limit: .fhd1080)
        XCTAssertEqual(dims.width, 1080)
        XCTAssertEqual(dims.height, 1920)
    }

    func testDownscaleKeepsEvenDimensions() {
        let dims = CompressionPlanner.outputDimensions(width: 1917, height: 1083, limit: .hd720)
        XCTAssertEqual(dims.width % 2, 0)
        XCTAssertEqual(dims.height % 2, 0)
        XCTAssertEqual(dims.height, 720)
    }

    func testSmallVideosAreNeverUpscaled() {
        let dims = CompressionPlanner.outputDimensions(width: 640, height: 360, limit: .fhd1080)
        XCTAssertEqual(dims.width, 640)
        XCTAssertEqual(dims.height, 360)
    }

    func testFrameRateCap() {
        var source = fourK
        source.frameRate = 60
        var settings = CompressionSettings(preset: .balanced)
        settings.setEncoding(\.frameRate, to: .fps30)
        let plan = CompressionPlanner.plan(for: source, settings: settings)
        XCTAssertEqual(plan.frameRate, 30)
        XCTAssertTrue(plan.isFrameRateReduced)
    }

    func testFrameRateNeverIncreases() {
        var source = fourK
        source.frameRate = 24
        var settings = CompressionSettings(preset: .balanced)
        settings.setEncoding(\.frameRate, to: .fps30)
        XCTAssertEqual(CompressionPlanner.plan(for: source, settings: settings).frameRate, 24)
    }

    func testBitrateNeverExceedsSource() {
        let lowBitrate = SourceVideoInfo(width: 1920, height: 1080, frameRate: 30, duration: 10, videoBitrate: 1_000_000)
        let plan = CompressionPlanner.plan(for: lowBitrate, settings: CompressionSettings(preset: .maximumQuality))
        XCTAssertLessThanOrEqual(plan.videoBitrate, 900_000)
    }

    func testBitrateHasFloor() {
        let tiny = SourceVideoInfo(width: 160, height: 90, frameRate: 15, duration: 10)
        let plan = CompressionPlanner.plan(for: tiny, settings: CompressionSettings(preset: .extreme))
        XCTAssertEqual(plan.videoBitrate, CompressionPlanner.minimumVideoBitrate)
    }

    func testHEVCIsSmallerThanH264() {
        var hevc = CompressionSettings(preset: .balanced)
        hevc.setEncoding(\.codec, to: .hevc)
        var h264 = hevc
        h264.setEncoding(\.codec, to: .h264)
        let source = SourceVideoInfo(width: 1920, height: 1080, frameRate: 30, duration: 60, videoBitrate: 50_000_000)
        XCTAssertLessThan(
            CompressionPlanner.plan(for: source, settings: hevc).videoBitrate,
            CompressionPlanner.plan(for: source, settings: h264).videoBitrate
        )
    }

    func testHDRForcesHEVC() {
        var source = fourK
        source.isHDR = true
        var settings = CompressionSettings(preset: .balanced)
        settings.setEncoding(\.codec, to: .h264)
        let plan = CompressionPlanner.plan(for: source, settings: settings)
        XCTAssertEqual(plan.codec, .hevc)
        XCTAssertTrue(plan.preservesHDR)
    }

    func testPresetsGetProgressivelySmaller() {
        let sizes = [CompressionPreset.maximumQuality, .balanced, .spaceSaver, .extreme].map {
            CompressionPlanner.plan(for: fourK, settings: CompressionSettings(preset: $0)).estimatedFileSize
        }
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        XCTAssertLessThan(sizes.last!, fourK.fileSize!)
    }

    func testNoAudioTrack() {
        var source = fourK
        source.hasAudio = false
        XCTAssertNil(CompressionPlanner.plan(for: source, settings: .default).audioBitrate)
    }

    func testAudioBitrateNotAboveSource() {
        var source = fourK
        source.audioBitrate = 96_000
        let plan = CompressionPlanner.plan(for: source, settings: CompressionSettings(preset: .maximumQuality))
        XCTAssertEqual(plan.audioBitrate, 96_000)
    }

    func testEffectiveBitrateFromFileSize() {
        let source = SourceVideoInfo(width: 1920, height: 1080, duration: 8, fileSize: 8_000_000)
        // 8 MB over 8 s = 8 Mbit/s total, minus assumed 128 kbit/s audio.
        XCTAssertEqual(source.effectiveVideoBitrate!, 7_872_000, accuracy: 1)
    }

    func testEstimateMatchesBitrate() {
        let plan = CompressionPlanner.plan(for: fourK, settings: .default)
        let expected = Double(plan.videoBitrate + plan.audioBitrate!) * 60 / 8
        XCTAssertEqual(Double(plan.estimatedFileSize), expected * 1.02, accuracy: 10)
    }

    func testWorthKeeping() {
        XCTAssertTrue(CompressionPlanner.isWorthKeeping(original: 100, compressed: 50, minimumSavingsPercent: 10))
        XCTAssertFalse(CompressionPlanner.isWorthKeeping(original: 100, compressed: 95, minimumSavingsPercent: 10))
        XCTAssertFalse(CompressionPlanner.isWorthKeeping(original: 100, compressed: 120, minimumSavingsPercent: 0))
    }
}

final class CompressionSettingsTests: XCTestCase {
    func testApplyingPresetSetsParameters() {
        var settings = CompressionSettings.default
        settings.apply(.spaceSaver)
        XCTAssertEqual(settings.preset, .spaceSaver)
        XCTAssertEqual(settings.encoding, CompressionPreset.spaceSaver.parameters)
    }

    func testCustomKeepsCurrentParameters() {
        var settings = CompressionSettings(preset: .extreme)
        settings.apply(.custom)
        XCTAssertEqual(settings.preset, .custom)
        XCTAssertEqual(settings.encoding, CompressionPreset.extreme.parameters)
    }

    func testEditingParameterSwitchesToCustom() {
        var settings = CompressionSettings(preset: .balanced)
        settings.setEncoding(\.quality, to: .minimum)
        XCTAssertEqual(settings.preset, .custom)
    }

    func testEditingBackToPresetValuesRestoresPreset() {
        var settings = CompressionSettings(preset: .balanced)
        settings.setEncoding(\.quality, to: .minimum)
        settings.setEncoding(\.quality, to: .balanced)
        XCTAssertEqual(settings.preset, .balanced)
    }

    func testCodableRoundTrip() throws {
        var settings = CompressionSettings(preset: .spaceSaver, deleteOriginals: false, minimumSavingsPercent: 25)
        settings.setEncoding(\.audio, to: .high)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(CompressionSettings.self, from: data), settings)
    }
}
