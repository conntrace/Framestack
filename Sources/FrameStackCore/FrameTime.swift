import Foundation

/// An exact rational media time: `value / timescale` seconds.
///
/// Mirrors the numeric part of `CMTime` so the sampling engine can stay
/// independent of CoreMedia while never accumulating floating-point error.
/// Equality and ordering are exact (cross-multiplication with 128-bit
/// intermediates), so `1/30 == 20/600 == 512/15360`.
public struct FrameTime: Sendable, Codable, CustomStringConvertible {
    public let value: Int64
    /// Ticks per second. Always > 0.
    public let timescale: Int32

    public init(value: Int64, timescale: Int32) {
        precondition(timescale > 0, "FrameTime timescale must be positive")
        self.value = value
        self.timescale = timescale
    }

    /// Converts user-entered seconds to an exact tick count, rounding to the
    /// nearest tick. The default timescale (microseconds) represents any
    /// decimal with up to six fractional digits exactly.
    public init(seconds: Double, preferredTimescale: Int32 = 1_000_000) {
        precondition(seconds.isFinite, "FrameTime seconds must be finite")
        self.init(
            value: Int64((seconds * Double(preferredTimescale)).rounded()),
            timescale: preferredTimescale
        )
    }

    public static let zero = FrameTime(value: 0, timescale: 1)

    /// Approximate value in seconds, for display and for weighting math only.
    /// Never use this for frame identity or range membership.
    public var seconds: Double { Double(value) / Double(timescale) }

    public var description: String { "\(value)/\(timescale)" }

    /// Reduced form (value/g, timescale/g); used for hashing so equal times
    /// expressed in different timescales hash identically.
    var reduced: (value: Int64, timescale: Int64) {
        let g = Self.gcd(value.magnitude, UInt64(timescale))
        guard g > 1 else { return (value, Int64(timescale)) }
        return (value / Int64(g), Int64(timescale) / Int64(g))
    }

    private static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    /// -1, 0, or 1. Exact for all representable values.
    public static func compare(_ lhs: FrameTime, _ rhs: FrameTime) -> Int {
        if lhs.timescale == rhs.timescale {
            return lhs.value < rhs.value ? -1 : (lhs.value == rhs.value ? 0 : 1)
        }
        let a = lhs.value.multipliedFullWidth(by: Int64(rhs.timescale))
        let b = rhs.value.multipliedFullWidth(by: Int64(lhs.timescale))
        if a.high != b.high { return a.high < b.high ? -1 : 1 }
        if a.low != b.low { return a.low < b.low ? -1 : 1 }
        return 0
    }
}

extension FrameTime: Comparable, Hashable {
    public static func == (lhs: FrameTime, rhs: FrameTime) -> Bool {
        compare(lhs, rhs) == 0
    }

    public static func < (lhs: FrameTime, rhs: FrameTime) -> Bool {
        compare(lhs, rhs) < 0
    }

    public func hash(into hasher: inout Hasher) {
        let r = reduced
        hasher.combine(r.value)
        hasher.combine(r.timescale)
    }
}

/// A half-open time interval `[start, end)`: start inclusive, end exclusive.
///
/// A frame whose presentation timestamp equals `end` is *not* included. This
/// avoids the classic off-by-one at the clip end: `[0, duration)` contains
/// every frame of a clip, and `[2, 5)` on a 30 fps clip contains exactly the
/// 90 frames with timestamps 60/30 … 149/30.
public struct FrameTimeRange: Sendable, Codable, Equatable {
    public var start: FrameTime
    public var end: FrameTime

    public init(start: FrameTime, end: FrameTime) {
        self.start = start
        self.end = end
    }

    public var isEmpty: Bool { !(start < end) }

    public func contains(_ time: FrameTime) -> Bool {
        start <= time && time < end
    }

    public var durationSeconds: Double { end.seconds - start.seconds }
}
