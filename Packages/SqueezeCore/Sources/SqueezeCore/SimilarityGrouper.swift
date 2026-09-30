import Foundation

public enum MediaKind: String, Codable, Sendable {
    case photo
    case video
}

/// A photo or video with its perceptual hash and the metadata needed to group it.
public struct HashedMedia: Identifiable, Equatable, Sendable {
    public var id: String
    public var hash: UInt64
    public var kind: MediaKind
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var creationDate: Date?
    public var duration: TimeInterval
    public var fileSize: Int64
    public var isFavorite: Bool

    public init(
        id: String,
        hash: UInt64,
        kind: MediaKind,
        pixelWidth: Int,
        pixelHeight: Int,
        creationDate: Date? = nil,
        duration: TimeInterval = 0,
        fileSize: Int64 = 0,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.hash = hash
        self.kind = kind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.duration = duration
        self.fileSize = fileSize
        self.isFavorite = isFavorite
    }

    var aspectRatio: Double {
        guard pixelHeight > 0 else { return 0 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    var pixelCount: Int { pixelWidth * pixelHeight }
}

public struct SimilarityOptions: Equatable, Sendable {
    /// Maximum number of differing hash bits for two items to match.
    public var maxDistance: Int
    /// Only compare items created within this interval of each other (`nil` = compare everything).
    public var maxTimeInterval: TimeInterval?
    /// Relative tolerance for aspect ratios (crops are not duplicates).
    public var aspectRatioTolerance: Double
    /// Videos must have (almost) the same length to match.
    public var videoDurationTolerance: TimeInterval

    public init(
        maxDistance: Int,
        maxTimeInterval: TimeInterval? = nil,
        aspectRatioTolerance: Double = 0.03,
        videoDurationTolerance: TimeInterval = 1.0
    ) {
        self.maxDistance = max(0, min(maxDistance, 63))
        self.maxTimeInterval = maxTimeInterval
        self.aspectRatioTolerance = aspectRatioTolerance
        self.videoDurationTolerance = videoDurationTolerance
    }

    /// Exact copies and re-encoded / resized copies of the same media.
    public static let duplicates = SimilarityOptions(maxDistance: 2)

    /// Visually similar shots (bursts, retakes). `sensitivity` in 0...1: higher finds more.
    public static func similar(sensitivity: Double, withinSeconds interval: TimeInterval? = 10 * 60) -> SimilarityOptions {
        let clamped = min(max(sensitivity, 0), 1)
        return SimilarityOptions(maxDistance: 5 + Int((clamped * 9).rounded()), maxTimeInterval: interval)
    }
}

/// A set of duplicate/similar items. `keeperID` is the one we suggest keeping.
public struct MediaGroup: Identifiable, Equatable, Sendable {
    public var id: String { members.first?.id ?? "" }
    public var members: [HashedMedia]
    public var keeperID: String

    public init(members: [HashedMedia], keeperID: String) {
        self.members = members
        self.keeperID = keeperID
    }

    /// Bytes freed by deleting everything except the keeper.
    public var reclaimableBytes: Int64 {
        members.filter { $0.id != keeperID }.reduce(0) { $0 + $1.fileSize }
    }
}

public enum SimilarityGrouper {
    /// Groups items whose hashes are within `options.maxDistance` of each other.
    /// Matches are transitive (A~B and B~C puts A, B and C in one group), which keeps
    /// burst sequences together. Groups are sorted by reclaimable bytes, largest first.
    public static func groups(from items: [HashedMedia], options: SimilarityOptions) -> [MediaGroup] {
        guard items.count > 1 else { return [] }
        var unionFind = UnionFind(count: items.count)

        if let window = options.maxTimeInterval {
            unionWithinTimeWindow(items, window: window, options: options, into: &unionFind)
        } else {
            unionByHashBlocks(items, options: options, into: &unionFind)
        }

        var membersByRoot: [Int: [Int]] = [:]
        for index in items.indices {
            membersByRoot[unionFind.find(index), default: []].append(index)
        }

        var groups: [MediaGroup] = []
        for indices in membersByRoot.values where indices.count > 1 {
            let members = indices
                .map { items[$0] }
                .sorted { ($0.creationDate ?? .distantPast, $0.id) < ($1.creationDate ?? .distantPast, $1.id) }
            let keeper = KeeperRanking.best(of: members)
            groups.append(MediaGroup(members: members, keeperID: keeper.id))
        }
        return groups.sorted {
            ($0.reclaimableBytes, $0.members.count, $0.id) > ($1.reclaimableBytes, $1.members.count, $1.id)
        }
    }

    /// Whether two items count as a match under `options` (ignores the time window).
    public static func matches(_ lhs: HashedMedia, _ rhs: HashedMedia, options: SimilarityOptions) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        guard PerceptualHash.distance(lhs.hash, rhs.hash) <= options.maxDistance else { return false }
        let ratioA = lhs.aspectRatio
        let ratioB = rhs.aspectRatio
        if ratioA > 0, ratioB > 0, abs(ratioA - ratioB) / max(ratioA, ratioB) > options.aspectRatioTolerance {
            return false
        }
        if lhs.kind == .video, abs(lhs.duration - rhs.duration) > options.videoDurationTolerance {
            return false
        }
        return true
    }

    // MARK: - Candidate generation

    /// Items sorted by date; compare each with its successors inside the time window.
    private static func unionWithinTimeWindow(
        _ items: [HashedMedia],
        window: TimeInterval,
        options: SimilarityOptions,
        into unionFind: inout UnionFind
    ) {
        let dated = items.indices
            .compactMap { index in items[index].creationDate.map { (index, $0) } }
            .sorted { $0.1 < $1.1 }
        for (position, (index, date)) in dated.enumerated() {
            var next = position + 1
            while next < dated.count, dated[next].1.timeIntervalSince(date) <= window {
                let other = dated[next].0
                if unionFind.find(index) != unionFind.find(other), matches(items[index], items[other], options: options) {
                    unionFind.union(index, other)
                }
                next += 1
            }
        }
    }

    /// Pigeonhole principle: split the 64-bit hash into `maxDistance + 1` blocks. Two hashes
    /// within `maxDistance` bits must agree exactly on at least one block, so only items that
    /// share a block value need to be compared.
    private static func unionByHashBlocks(_ items: [HashedMedia], options: SimilarityOptions, into unionFind: inout UnionFind) {
        let blockCount = options.maxDistance + 1
        for block in hashBlocks(count: blockCount) {
            var buckets: [UInt64: [Int]] = [:]
            for index in items.indices {
                let key = (items[index].hash >> block.shift) & block.mask
                buckets[key, default: []].append(index)
            }
            for bucket in buckets.values where bucket.count > 1 {
                for i in 0..<(bucket.count - 1) {
                    for j in (i + 1)..<bucket.count {
                        let a = bucket[i]
                        let b = bucket[j]
                        if unionFind.find(a) != unionFind.find(b), matches(items[a], items[b], options: options) {
                            unionFind.union(a, b)
                        }
                    }
                }
            }
        }
    }

    struct HashBlock: Equatable {
        var shift: UInt64
        var mask: UInt64
    }

    /// Splits 64 bits into `count` contiguous blocks whose widths differ by at most one bit.
    static func hashBlocks(count: Int) -> [HashBlock] {
        let count = max(1, min(count, 64))
        var blocks: [HashBlock] = []
        var shift = 0
        for index in 0..<count {
            let width = 64 / count + (index < 64 % count ? 1 : 0)
            let mask: UInt64 = width >= 64 ? .max : (UInt64(1) << UInt64(width)) - 1
            blocks.append(HashBlock(shift: UInt64(shift), mask: mask))
            shift += width
        }
        return blocks
    }
}

/// Picks the item to keep in a group: favourites first, then the highest resolution,
/// then the largest file (least compressed), then the oldest (the original).
public enum KeeperRanking {
    public static func best(of members: [HashedMedia]) -> HashedMedia {
        precondition(!members.isEmpty, "A group needs at least one member")
        return members.max(by: isRankedLower)!
    }

    /// `true` if `lhs` is a worse keeper than `rhs`.
    static func isRankedLower(_ lhs: HashedMedia, _ rhs: HashedMedia) -> Bool {
        if lhs.isFavorite != rhs.isFavorite { return !lhs.isFavorite }
        if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount < rhs.pixelCount }
        if lhs.fileSize != rhs.fileSize { return lhs.fileSize < rhs.fileSize }
        let lhsDate = lhs.creationDate ?? .distantFuture
        let rhsDate = rhs.creationDate ?? .distantFuture
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.id > rhs.id
    }
}

struct UnionFind {
    private var parent: [Int]
    private var rank: [UInt8]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ element: Int) -> Int {
        var root = element
        while parent[root] != root { root = parent[root] }
        var current = element
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let rootA = find(a)
        let rootB = find(b)
        guard rootA != rootB else { return }
        if rank[rootA] < rank[rootB] {
            parent[rootA] = rootB
        } else if rank[rootA] > rank[rootB] {
            parent[rootB] = rootA
        } else {
            parent[rootB] = rootA
            rank[rootA] += 1
        }
    }
}
