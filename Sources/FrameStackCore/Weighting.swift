import Foundation

/// Temporal weighting (PRD §5.3): a continuous non-negative weight function
/// over the selection's normalised time 0…1, where 0 is the first selected
/// frame's timestamp and 1 the last's — real timestamps, not frame indices,
/// so variable frame rates weight by time.
public enum WeightPreset: String, Sendable, Codable, CaseIterable, Identifiable {
    case flat
    case early
    case late
    case middle
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .flat: return "Flat"
        case .early: return "Favor Early"
        case .late: return "Favor Late"
        case .middle: return "Favor Middle"
        case .custom: return "Custom"
        }
    }
}

/// A control point of a custom curve: `time` 0…1, `weight` 0…1.
public struct WeightPoint: Sendable, Codable, Equatable {
    public var time: Double
    public var weight: Double

    public init(time: Double, weight: Double) {
        self.time = time
        self.weight = weight
    }
}

/// The weights actually applied to one selection.
public struct WeightedSelection: Sendable, Equatable {
    /// Raw curve values w(t_i), 0…1, one per selected frame.
    public let raw: [Double]
    /// `raw / Σ raw` — the weights of a weighted Average (sum to 1).
    public let normalized: [Double]
    /// Normalised times t_i of the selected frames.
    public let times: [Double]
    /// All raw weights were zero, so Flat was used instead (PRD: "prevent
    /// zero-total-weight errors").
    public let usedFlatFallback: Bool

    /// `1 / Σ w²` for normalised weights: how many equal-weight frames the
    /// weighted average is statistically worth (N for Flat, less otherwise).
    public var effectiveFrameCount: Double {
        let s = normalized.reduce(0) { $0 + $1 * $1 }
        return s > 0 ? 1 / s : 0
    }

    public var rawRange: ClosedRange<Double> {
        guard let lo = raw.min(), let hi = raw.max() else { return 1...1 }
        return lo...hi
    }
}

/// Preset or custom weight curve. Presets never reach exactly zero ("favor",
/// not "exclude"): `floor + (1 − floor) × shape(t)` with floor 0.1.
public struct WeightCurve: Sendable, Codable, Equatable {
    public var preset: WeightPreset
    /// Control points of the custom curve (used only when `preset == .custom`),
    /// sorted by time, linearly interpolated, flat beyond the ends.
    public var points: [WeightPoint]

    public static let presetFloor = 0.1
    public static let flat = WeightCurve(preset: .flat)
    public static let defaultCustomPoints = [WeightPoint(time: 0, weight: 0.5), WeightPoint(time: 0.25, weight: 0.5),
                                             WeightPoint(time: 0.5, weight: 0.5), WeightPoint(time: 0.75, weight: 0.5),
                                             WeightPoint(time: 1, weight: 0.5)]

    public init(preset: WeightPreset, points: [WeightPoint] = WeightCurve.defaultCustomPoints) {
        self.preset = preset
        self.points = points
    }

    private enum CodingKeys: String, CodingKey { case preset, points }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decode(WeightPreset.self, forKey: .preset)
        points = try c.decodeIfPresent([WeightPoint].self, forKey: .points) ?? Self.defaultCustomPoints
    }

    public var isFlat: Bool { preset == .flat }

    public var explanation: String {
        switch preset {
        case .flat: return "Every selected frame counts the same (equal-weight Average)."
        case .early: return "Weight falls from 1 at the first selected frame to 0.1 at the last; early moments dominate."
        case .late: return "Weight rises from 0.1 at the first selected frame to 1 at the last; late moments dominate."
        case .middle: return "Weight peaks at 1 in the middle of the selection and falls to 0.1 at both ends."
        case .custom: return "Drag the points. Weight is interpolated between them along the selection's time."
        }
    }

    /// The curve's value at normalised time `t` (clamped to 0…1), 0…1.
    public func weight(at t: Double) -> Double {
        let t = min(max(t.isNaN ? 0 : t, 0), 1)
        let floor = Self.presetFloor
        switch preset {
        case .flat: return 1
        case .early: return floor + (1 - floor) * (1 - t)
        case .late: return floor + (1 - floor) * t
        case .middle: return floor + (1 - floor) * (1 - abs(2 * t - 1))
        case .custom:
            // Control points are clamped to 0…1 before interpolating.
            let sorted = points.map { WeightPoint(time: min(max($0.time, 0), 1), weight: clampWeight($0.weight)) }
                .sorted { $0.time < $1.time }
            guard let first = sorted.first, let last = sorted.last else { return 1 }
            if t <= first.time { return clampWeight(first.weight) }
            if t >= last.time { return clampWeight(last.weight) }
            for i in 1..<sorted.count where t <= sorted[i].time {
                let a = sorted[i - 1], b = sorted[i]
                let span = b.time - a.time
                let f = span > 0 ? (t - a.time) / span : 1
                return clampWeight(a.weight + (b.weight - a.weight) * f)
            }
            return clampWeight(last.weight)
        }
    }

    private func clampWeight(_ w: Double) -> Double { min(max(w.isNaN ? 0 : w, 0), 1) }

    /// Normalised times of ascending timestamps: 0 for the first, 1 for the
    /// last, proportional to real time between. A single frame is at 0.
    public static func normalizedTimes(_ times: [FrameTime]) -> [Double] {
        guard let first = times.first, let last = times.last, times.count > 1 else {
            return times.map { _ in 0 }
        }
        let span = last.seconds - first.seconds
        guard span > 0 else { return times.map { _ in 0 } }
        return times.map { ($0.seconds - first.seconds) / span }
    }

    /// Weights for a selection (ascending timestamps). Falls back to Flat
    /// when every raw weight is zero.
    public func weights(for times: [FrameTime]) -> WeightedSelection {
        let t = Self.normalizedTimes(times)
        var raw = t.map { weight(at: $0) }
        var fallback = false
        let total = raw.reduce(0, +)
        if total <= 0 || !total.isFinite {
            raw = t.map { _ in 1.0 }
            fallback = true
        }
        let sum = raw.reduce(0, +)
        let normalized = sum > 0 ? raw.map { $0 / sum } : raw
        return WeightedSelection(raw: raw, normalized: normalized, times: t, usedFlatFallback: fallback)
    }
}
