import Foundation

/// Difference hash ("dHash"): a 64-bit fingerprint of an image's structure that stays
/// stable across re-encoding, resizing and small colour changes. Two images whose
/// hashes differ in only a few bits look (nearly) the same.
public enum PerceptualHash {
    /// Input size expected by `differenceHash(grayscale:)`.
    public static let inputWidth = 9
    public static let inputHeight = 8

    /// Computes the dHash from a 9×8 row-major grayscale image: each bit records whether
    /// a pixel is brighter than its right-hand neighbour.
    public static func differenceHash(grayscale pixels: [UInt8]) -> UInt64? {
        guard pixels.count == inputWidth * inputHeight else { return nil }
        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0..<inputHeight {
            let rowStart = row * inputWidth
            for column in 0..<(inputWidth - 1) {
                if pixels[rowStart + column] > pixels[rowStart + column + 1] {
                    hash |= 1 << bit
                }
                bit += 1
            }
        }
        return hash
    }

    /// Convenience: box-filter an arbitrary grayscale image down to 9×8 and hash it.
    public static func differenceHash(grayscale pixels: [UInt8], width: Int, height: Int) -> UInt64? {
        guard let small = downsample(pixels, width: width, height: height, toWidth: inputWidth, toHeight: inputHeight) else {
            return nil
        }
        return differenceHash(grayscale: small)
    }

    /// Number of differing bits.
    public static func distance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// Area-average downsampling of a row-major 8-bit grayscale image.
    public static func downsample(_ pixels: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8]? {
        guard width > 0, height > 0, toWidth > 0, toHeight > 0, pixels.count == width * height else { return nil }
        var result = [UInt8](repeating: 0, count: toWidth * toHeight)
        for targetRow in 0..<toHeight {
            let y0 = targetRow * height / toHeight
            let y1 = max(y0 + 1, (targetRow + 1) * height / toHeight)
            for targetColumn in 0..<toWidth {
                let x0 = targetColumn * width / toWidth
                let x1 = max(x0 + 1, (targetColumn + 1) * width / toWidth)
                var sum = 0
                for y in y0..<min(y1, height) {
                    let rowStart = y * width
                    for x in x0..<min(x1, width) {
                        sum += Int(pixels[rowStart + x])
                    }
                }
                let count = (min(y1, height) - y0) * (min(x1, width) - x0)
                result[targetRow * toWidth + targetColumn] = UInt8(sum / max(count, 1))
            }
        }
        return result
    }
}
