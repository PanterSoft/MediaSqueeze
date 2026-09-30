import Foundation

enum Formatting {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional
        return formatter.string(from: max(0, seconds.rounded())) ?? "0:00"
    }

    static func resolution(width: Int, height: Int) -> String {
        let shortSide = min(width, height)
        switch shortSide {
        case 2160...: return "4K"
        case 1440..<2160: return "1440p"
        case 1080..<1440: return "1080p"
        case 720..<1080: return "720p"
        default: return "\(shortSide)p"
        }
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "Unknown date" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
