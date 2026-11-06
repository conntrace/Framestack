import Foundation

/// The ordered, de-duplicated presentation timestamps of a source.
///
/// Built from the timestamps actually found in the stream (never from
/// `duration × nominal fps`). Input order does not matter: timestamps are
/// sorted ascending (decode order differs from presentation order when a
/// codec uses B-frames).
///
/// Duplicate policy: if two samples carry the same presentation timestamp,
/// the first one encountered is kept and the rest are counted in
/// `duplicateTimestampsDropped`. Frame identity is the timestamp, so a
/// duplicate could never be addressed separately anyway.
public struct FrameTimeline: Sendable, Equatable {
    public let frames: [FrameTime]
    public let duplicateTimestampsDropped: Int

    public init(presentationTimes: [FrameTime]) {
        let sorted = presentationTimes.enumerated().sorted { lhs, rhs in
            // Stable: equal timestamps keep encounter order.
            lhs.element == rhs.element ? lhs.offset < rhs.offset : lhs.element < rhs.element
        }
        var unique: [FrameTime] = []
        unique.reserveCapacity(sorted.count)
        var dropped = 0
        for item in sorted {
            if let last = unique.last, last == item.element {
                dropped += 1
            } else {
                unique.append(item.element)
            }
        }
        frames = unique
        duplicateTimestampsDropped = dropped
    }

    public var count: Int { frames.count }

    // MARK: Navigation helpers (timeline UI, frame-accurate entry)

    /// Index of the frame whose timestamp is nearest to `time` (the earlier
    /// one on a tie); nil for an empty timeline.
    public func nearestIndex(to time: FrameTime) -> Int? {
        guard !frames.isEmpty else { return nil }
        let upper = FrameSampler.lowerBound(frames, time)
        if upper == 0 { return 0 }
        if upper == frames.count { return frames.count - 1 }
        let before = frames[upper - 1]
        let after = frames[upper]
        return (time.seconds - before.seconds) <= (after.seconds - time.seconds) ? upper - 1 : upper
    }

    /// Index of the last frame whose timestamp is `<= time`; nil if `time`
    /// is before the first frame.
    public func index(atOrBefore time: FrameTime) -> Int? {
        let upper = FrameSampler.lowerBound(frames, time)
        if upper < frames.count, frames[upper] == time { return upper }
        return upper == 0 ? nil : upper - 1
    }

    /// The exclusive end time that makes frame `index` the last included
    /// frame: the next frame's timestamp, or `end` (the clip duration) after
    /// the final frame.
    public func boundary(after index: Int, end: FrameTime) -> FrameTime {
        precondition(index >= 0 && index < frames.count)
        return index + 1 < frames.count ? frames[index + 1] : end
    }

    /// `[frames[first], boundary after last)` — the range that selects
    /// exactly frames `first…last` (inclusive). Indices are clamped and
    /// ordered.
    public func range(firstFrame: Int, lastFrame: Int, end: FrameTime) -> FrameTimeRange {
        precondition(!frames.isEmpty)
        let first = min(max(firstFrame, 0), frames.count - 1)
        let last = min(max(lastFrame, first), frames.count - 1)
        return FrameTimeRange(start: frames[first], end: boundary(after: last, end: end))
    }

    /// Inclusive indices of the frames inside `range`, or nil if none.
    public func frameIndices(in range: FrameTimeRange) -> ClosedRange<Int>? {
        let eligible = FrameSampler.eligibleIndices(in: self, range: range)
        return eligible.isEmpty ? nil : eligible.lowerBound...(eligible.upperBound - 1)
    }

    /// Nearest range boundary to `time`: a frame start time or `end`. Used to
    /// snap dragged in/out handles so a range always starts on a frame and
    /// ends just before one.
    public func nearestBoundary(to time: FrameTime, end: FrameTime) -> FrameTime {
        guard let i = nearestIndex(to: time) else { return end }
        let candidates = [frames[i], boundary(after: i, end: end)]
        return candidates.min { abs($0.seconds - time.seconds) < abs($1.seconds - time.seconds) }!
    }
}

/// How frames are chosen from the eligible frames of the selected range.
public enum SamplingMode: Sendable, Codable, Equatable, Hashable {
    /// Every eligible frame.
    case all
    /// Every Nth eligible frame, starting with the first (N >= 1).
    case everyNth(Int)
    /// K distinct eligible frames evenly distributed by index; for K > 1 the
    /// first and last eligible frames are always included; K = 1 picks the
    /// middle frame (lower middle for an even count).
    case exactCount(Int)
}

public enum SamplingNotice: Sendable, Equatable, CustomStringConvertible {
    /// Exact Count asked for more frames than are eligible; every eligible
    /// frame was selected instead (frames are never duplicated).
    case exactCountClamped(requested: Int, available: Int)

    public var description: String {
        switch self {
        case let .exactCountClamped(requested, available):
            return "Requested \(requested) frames but only \(available) are in range; using all \(available)."
        }
    }
}

public enum SamplingError: Error, Equatable, LocalizedError {
    case emptyRange
    case noEligibleFrames
    case invalidInterval(Int)
    case invalidCount(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyRange:
            return "The range end must be after its start."
        case .noEligibleFrames:
            return "No frames fall inside the selected range."
        case let .invalidInterval(n):
            return "Frame interval must be at least 1 (got \(n))."
        case let .invalidCount(k):
            return "Frame count must be at least 1 (got \(k))."
        }
    }
}

public struct SamplingResult: Sendable, Equatable {
    /// Indices into `FrameTimeline.frames` of the frames inside the range.
    /// Contiguous because the timeline is sorted.
    public let eligibleIndices: Range<Int>
    /// Indices into `FrameTimeline.frames` of the selected frames; strictly
    /// ascending, therefore unique and chronological.
    public let selectedIndices: [Int]
    public let notices: [SamplingNotice]

    public var eligibleCount: Int { eligibleIndices.count }
    public var selectedCount: Int { selectedIndices.count }

    public func selectedTimes(in timeline: FrameTimeline) -> [FrameTime] {
        selectedIndices.map { timeline.frames[$0] }
    }
}

public enum FrameSampler {
    /// The contiguous index range of timeline frames inside `[start, end)`.
    public static func eligibleIndices(in timeline: FrameTimeline, range: FrameTimeRange) -> Range<Int> {
        let lower = lowerBound(timeline.frames, range.start)
        let upper = lowerBound(timeline.frames, range.end)
        return lower..<max(lower, upper)
    }

    public static func select(
        from timeline: FrameTimeline,
        range: FrameTimeRange,
        mode: SamplingMode
    ) throws -> SamplingResult {
        guard !range.isEmpty else { throw SamplingError.emptyRange }
        let eligible = eligibleIndices(in: timeline, range: range)
        guard !eligible.isEmpty else { throw SamplingError.noEligibleFrames }
        let (positions, notices) = try selectPositions(eligibleCount: eligible.count, mode: mode)
        return SamplingResult(
            eligibleIndices: eligible,
            selectedIndices: positions.map { eligible.lowerBound + $0 },
            notices: notices
        )
    }

    /// Pure index selection over `m` eligible frames (positions `0..<m`).
    public static func selectPositions(
        eligibleCount m: Int,
        mode: SamplingMode
    ) throws -> (positions: [Int], notices: [SamplingNotice]) {
        precondition(m >= 0)
        switch mode {
        case .all:
            return (Array(0..<m), [])

        case let .everyNth(n):
            guard n >= 1 else { throw SamplingError.invalidInterval(n) }
            return (Array(stride(from: 0, to: m, by: n)), [])

        case let .exactCount(k):
            guard k >= 1 else { throw SamplingError.invalidCount(k) }
            guard m > 0 else { return ([], []) }
            if k >= m {
                let notices: [SamplingNotice] = k > m
                    ? [.exactCountClamped(requested: k, available: m)]
                    : []
                return (Array(0..<m), notices)
            }
            if k == 1 {
                return ([(m - 1) / 2], [])
            }
            // position_i = round(i * (m-1) / (k-1)), round half up, computed
            // exactly in integers. Because k <= m the spacing is >= 1, so the
            // positions are strictly increasing (distinct), start at 0 and end
            // at m-1.
            let span = m - 1
            let steps = k - 1
            let positions = (0..<k).map { i in (2 * i * span + steps) / (2 * steps) }
            return (positions, [])
        }
    }

    /// First index whose time is >= `time`.
    static func lowerBound(_ frames: [FrameTime], _ time: FrameTime) -> Int {
        var lo = 0
        var hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
