import Foundation

/// One part of a time range that was split into consecutive segments.
public struct RangeSegment: Sendable, Equatable, Identifiable {
    /// 0-based position among the segments.
    public var index: Int
    /// `[start, end)`; the segments of one split touch and cover the range exactly.
    public var range: FrameTimeRange
    /// Frames of the timeline inside `range`.
    public var frameCount: Int

    public var id: Int { index }

    public init(index: Int, range: FrameTimeRange, frameCount: Int) {
        self.index = index
        self.range = range
        self.frameCount = frameCount
    }
}

/// Temporal range segmentation (PRD §5.3): the frames of a range divided
/// into N consecutive groups, each exported as its own composite.
///
/// The split is by **frame count**, not by seconds, so every segment holds
/// the same number of frames even when the timestamps are irregular. When
/// the frames do not divide evenly the earlier segments get one frame more
/// (10 frames in 3 parts → 4, 3, 3). Boundaries are frame timestamps: a
/// segment starts at the timestamp of its first frame (the first one at the
/// range start) and ends where the next one starts (the last at the range
/// end), so the half-open segments cover `[start, end)` without overlap.
public enum RangeSegmenter {
    /// Upper bound on the parts a range may be split into.
    public static let maximumCount = 99

    /// At most `count` segments (fewer when the range holds fewer frames;
    /// none when it holds no frame). A `count` below 1 is treated as 1.
    public static func segments(of range: FrameTimeRange, in timeline: FrameTimeline, count: Int) -> [RangeSegment] {
        guard let indices = timeline.frameIndices(in: range) else { return [] }
        let total = indices.count
        let parts = min(max(count, 1), total, maximumCount)
        let base = total / parts
        let extra = total % parts
        var segments: [RangeSegment] = []
        segments.reserveCapacity(parts)
        var first = indices.lowerBound
        for part in 0..<parts {
            let size = base + (part < extra ? 1 : 0)
            let next = first + size
            let start = part == 0 ? range.start : timeline.frames[first]
            let end = part == parts - 1 ? range.end : timeline.frames[next]
            segments.append(RangeSegment(index: part, range: FrameTimeRange(start: start, end: end), frameCount: size))
            first = next
        }
        return segments
    }

    /// "part 03 of 12" — zero-padded to the width of the total so the files sort in time order.
    public static func label(part index: Int, of count: Int) -> String {
        let width = String(count).count
        let number = String(index + 1)
        return "part \(String(repeating: "0", count: max(0, width - number.count)))\(number) of \(count)"
    }

    /// "5 parts of 30 frames" / "3 parts of 3 or 4 frames".
    public static func summary(of segments: [RangeSegment]) -> String {
        guard let smallest = segments.map(\.frameCount).min(), let largest = segments.map(\.frameCount).max() else { return "No frames in the range" }
        let size = smallest == largest ? "\(largest) frame\(largest == 1 ? "" : "s")" : "\(smallest) or \(largest) frames"
        return "\(segments.count) part\(segments.count == 1 ? "" : "s") of \(size)"
    }
}
