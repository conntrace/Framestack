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
    private static func lowerBound(_ frames: [FrameTime], _ time: FrameTime) -> Int {
        var lo = 0
        var hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
