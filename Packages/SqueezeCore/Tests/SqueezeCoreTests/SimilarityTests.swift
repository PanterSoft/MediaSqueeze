import XCTest
@testable import SqueezeCore

final class PerceptualHashTests: XCTestCase {
    /// A 9×8 horizontal gradient getting darker to the right sets every bit.
    func testDarkeningGradientSetsAllBits() {
        let pixels = (0..<8).flatMap { _ in (0..<9).map { UInt8(250 - $0 * 20) } }
        XCTAssertEqual(PerceptualHash.differenceHash(grayscale: pixels), .max)
    }

    func testBrighteningGradientSetsNoBits() {
        let pixels = (0..<8).flatMap { _ in (0..<9).map { UInt8($0 * 20) } }
        XCTAssertEqual(PerceptualHash.differenceHash(grayscale: pixels), 0)
    }

    func testRejectsWrongInputSize() {
        XCTAssertNil(PerceptualHash.differenceHash(grayscale: [0, 1, 2]))
    }

    func testDistance() {
        XCTAssertEqual(PerceptualHash.distance(0, 0), 0)
        XCTAssertEqual(PerceptualHash.distance(0, .max), 64)
        XCTAssertEqual(PerceptualHash.distance(0b1011, 0b0001), 2)
    }

    func testDownsampleAveragesBlocks() {
        // 4×2 image: left half 0, right half 200.
        let pixels: [UInt8] = [0, 0, 200, 200, 0, 0, 200, 200]
        XCTAssertEqual(PerceptualHash.downsample(pixels, width: 4, height: 2, toWidth: 2, toHeight: 1), [0, 200])
    }

    func testHashIsStableAcrossResolutions() {
        let large = Self.pattern(width: 90, height: 80)
        let small = Self.pattern(width: 45, height: 40)
        let a = PerceptualHash.differenceHash(grayscale: large, width: 90, height: 80)!
        let b = PerceptualHash.differenceHash(grayscale: small, width: 45, height: 40)!
        XCTAssertLessThanOrEqual(PerceptualHash.distance(a, b), 2)
    }

    func testHashIsStableUnderBrightnessShift() {
        let base = Self.pattern(width: 90, height: 80)
        let brighter = base.map { UInt8(min(255, Int($0) + 20)) }
        let a = PerceptualHash.differenceHash(grayscale: base, width: 90, height: 80)!
        let b = PerceptualHash.differenceHash(grayscale: brighter, width: 90, height: 80)!
        XCTAssertLessThanOrEqual(PerceptualHash.distance(a, b), 2)
    }

    func testDifferentImagesAreFarApart() {
        let a = PerceptualHash.differenceHash(grayscale: Self.pattern(width: 90, height: 80), width: 90, height: 80)!
        let b = PerceptualHash.differenceHash(grayscale: Self.pattern(width: 90, height: 80, phase: 2.1), width: 90, height: 80)!
        XCTAssertGreaterThan(PerceptualHash.distance(a, b), 10)
    }

    static func pattern(width: Int, height: Int, phase: Double = 0) -> [UInt8] {
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width)
                let v = Double(y) / Double(height)
                let value = 127 + 100 * sin(u * 9 + phase) * cos(v * 7 - phase * 1.7)
                pixels.append(UInt8(max(0, min(255, value))))
            }
        }
        return pixels
    }
}

final class SimilarityGrouperTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func photo(_ id: String, hash: UInt64, size: Int64 = 1_000, width: Int = 4032, height: Int = 3024,
                       minutes: Double = 0, favorite: Bool = false) -> HashedMedia {
        HashedMedia(id: id, hash: hash, kind: .photo, pixelWidth: width, pixelHeight: height,
                    creationDate: base.addingTimeInterval(minutes * 60), fileSize: size, isFavorite: favorite)
    }

    func testExactDuplicatesAreGrouped() {
        let items = [photo("a", hash: 0xABCD), photo("b", hash: 0xABCD), photo("c", hash: 0xFFFF_0000_FFFF_0000)]
        let groups = SimilarityGrouper.groups(from: items, options: .duplicates)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].members.map(\.id)), ["a", "b"])
    }

    func testNearDuplicatesWithinDistanceAreGrouped() {
        let items = [photo("a", hash: 0b1111), photo("b", hash: 0b0011)]
        XCTAssertEqual(SimilarityGrouper.groups(from: items, options: .duplicates).count, 1)
        XCTAssertTrue(SimilarityGrouper.groups(from: items, options: SimilarityOptions(maxDistance: 1)).isEmpty)
    }

    func testBlockIndexFindsMatchesSpreadAcrossBlocks() {
        // Differences in the lowest and highest bits land in different blocks.
        let hash: UInt64 = 0x0F0F_0F0F_0F0F_0F0F
        let items = [photo("a", hash: hash), photo("b", hash: hash ^ 1 ^ (1 << 63))]
        XCTAssertEqual(SimilarityGrouper.groups(from: items, options: .duplicates).count, 1)
    }

    func testDifferentAspectRatiosAreNotDuplicates() {
        let items = [photo("a", hash: 42), photo("b", hash: 42, width: 3024, height: 3024)]
        XCTAssertTrue(SimilarityGrouper.groups(from: items, options: .duplicates).isEmpty)
    }

    func testPhotosAndVideosNeverMatch() {
        let video = HashedMedia(id: "v", hash: 42, kind: .video, pixelWidth: 4032, pixelHeight: 3024, duration: 3)
        XCTAssertTrue(SimilarityGrouper.groups(from: [photo("p", hash: 42), video], options: .duplicates).isEmpty)
    }

    func testVideosNeedSimilarDuration() {
        let a = HashedMedia(id: "a", hash: 7, kind: .video, pixelWidth: 1920, pixelHeight: 1080, duration: 10)
        let b = HashedMedia(id: "b", hash: 7, kind: .video, pixelWidth: 1280, pixelHeight: 720, duration: 10.4)
        let c = HashedMedia(id: "c", hash: 7, kind: .video, pixelWidth: 1920, pixelHeight: 1080, duration: 30)
        let groups = SimilarityGrouper.groups(from: [a, b, c], options: .duplicates)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].members.map(\.id)), ["a", "b"])
        XCTAssertEqual(groups[0].keeperID, "a", "higher resolution copy should be kept")
    }

    func testTimeWindowLimitsSimilarMatches() {
        let options = SimilarityOptions(maxDistance: 8, maxTimeInterval: 5 * 60)
        let items = [photo("a", hash: 0xFF, minutes: 0), photo("b", hash: 0xF0, minutes: 2), photo("c", hash: 0xFF, minutes: 60)]
        let groups = SimilarityGrouper.groups(from: items, options: options)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].members.map(\.id)), ["a", "b"])
    }

    func testBurstsChainTransitively() {
        let options = SimilarityOptions(maxDistance: 2, maxTimeInterval: 60)
        let items = [photo("a", hash: 0b0000, minutes: 0), photo("b", hash: 0b0011, minutes: 0.1), photo("c", hash: 0b1111, minutes: 0.2)]
        let groups = SimilarityGrouper.groups(from: items, options: options)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].members.count, 3)
    }

    func testKeeperPrefersFavoriteThenResolutionThenSize() {
        let favorite = photo("fav", hash: 1, size: 10, width: 400, height: 300, favorite: true)
        let big = photo("big", hash: 1, size: 5_000)
        let small = photo("small", hash: 1, size: 100)
        XCTAssertEqual(KeeperRanking.best(of: [big, favorite, small]).id, "fav")
        XCTAssertEqual(KeeperRanking.best(of: [small, big]).id, "big")
    }

    func testKeeperPrefersOlderWhenOtherwiseEqual() {
        let older = photo("older", hash: 1, minutes: 0)
        let newer = photo("newer", hash: 1, minutes: 5)
        XCTAssertEqual(KeeperRanking.best(of: [newer, older]).id, "older")
    }

    func testGroupsSortedByReclaimableBytes() {
        let items = [
            photo("a1", hash: 0x1, size: 10), photo("a2", hash: 0x1, size: 10),
            photo("b1", hash: 0xFFFF_FFFF_0000_0000, size: 900), photo("b2", hash: 0xFFFF_FFFF_0000_0000, size: 900),
        ]
        let groups = SimilarityGrouper.groups(from: items, options: .duplicates)
        XCTAssertEqual(groups.map(\.reclaimableBytes), [900, 10])
    }

    func testHashBlocksCoverAllBits() {
        for count in [1, 3, 7, 13, 64] {
            let blocks = SimilarityGrouper.hashBlocks(count: count)
            XCTAssertEqual(blocks.count, count)
            let covered = blocks.reduce(UInt64(0)) { $0 | ($1.mask << $1.shift) }
            XCTAssertEqual(covered, .max, "count \(count)")
        }
    }

    func testSimilarSensitivityRange() {
        XCTAssertEqual(SimilarityOptions.similar(sensitivity: 0).maxDistance, 5)
        XCTAssertEqual(SimilarityOptions.similar(sensitivity: 1).maxDistance, 14)
        XCTAssertEqual(SimilarityOptions.similar(sensitivity: 5).maxDistance, 14)
    }
}
