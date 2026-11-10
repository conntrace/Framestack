import Foundation

/// A control point of a tone curve: `input` and `output` are sRGB-encoded
/// values 0…1 (what the eye reads as evenly spaced tones).
public struct TonePoint: Sendable, Codable, Equatable {
    public var input: Double
    public var output: Double

    public init(input: Double, output: Double) {
        self.input = input
        self.output = output
    }
}

/// A master tone curve (PRD §7 "optional curves"), the last step of the
/// post-composite colour pipeline. It maps each channel's sRGB-encoded
/// value through a monotone cubic (Fritsch–Carlson) spline of the control
/// points: the curve passes through every point, never overshoots between
/// two points, and is flat beyond the first and last point. Values outside
/// 0…1 are clamped before the curve — a curve is defined on displayable
/// tones only (documented; the identity curve leaves the image untouched,
/// including values above 1).
public struct ToneCurve: Sendable, Codable, Equatable {
    /// At least two points; kept sorted by `input` when evaluated.
    public var points: [TonePoint]

    public static let defaultInputs: [Double] = [0, 0.25, 0.5, 0.75, 1]
    public static let identity = ToneCurve(points: defaultInputs.map { TonePoint(input: $0, output: $0) })

    public init(points: [TonePoint]) {
        self.points = points
    }

    /// True when every point lies on the diagonal (the curve changes nothing).
    public var isIdentity: Bool {
        points.allSatisfy { abs($0.input - $0.output) < 1e-9 }
    }

    /// Clamped, sorted, de-duplicated control points (a later point with
    /// the same input replaces the earlier one).
    public var normalizedPoints: [TonePoint] {
        var result: [TonePoint] = []
        for p in points.sorted(by: { $0.input < $1.input }) {
            let q = TonePoint(input: Self.clamp(p.input), output: Self.clamp(p.output))
            if let last = result.last, abs(last.input - q.input) < 1e-9 { result[result.count - 1] = q } else { result.append(q) }
        }
        return result
    }

    private static func clamp(_ v: Double) -> Double { min(max(v.isNaN ? 0 : v, 0), 1) }

    /// The curve's sRGB-encoded output for an sRGB-encoded input (clamped to 0…1).
    public func value(at x: Double) -> Double {
        Spline(points: normalizedPoints).value(at: Self.clamp(x))
    }

    /// A named starting shape (the editor's menu).
    public enum Shape: String, Sendable, CaseIterable, Identifiable {
        case linear, softContrast, strongContrast, liftShadows, fade, matte

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .linear: return "Linear"
            case .softContrast: return "Soft Contrast"
            case .strongContrast: return "Strong Contrast"
            case .liftShadows: return "Lift Shadows"
            case .fade: return "Fade"
            case .matte: return "Matte Blacks"
            }
        }

        public var curve: ToneCurve {
            let outputs: [Double]
            switch self {
            case .linear: outputs = [0, 0.25, 0.5, 0.75, 1]
            case .softContrast: outputs = [0, 0.22, 0.5, 0.78, 1]
            case .strongContrast: outputs = [0, 0.17, 0.5, 0.83, 1]
            case .liftShadows: outputs = [0, 0.33, 0.56, 0.77, 1]
            case .fade: outputs = [0.06, 0.28, 0.5, 0.73, 0.95]
            case .matte: outputs = [0.1, 0.27, 0.5, 0.75, 1]
            }
            return ToneCurve(points: zip(ToneCurve.defaultInputs, outputs).map { TonePoint(input: $0, output: $1) })
        }
    }

    /// Monotone cubic Hermite interpolation (Fritsch–Carlson tangents).
    struct Spline {
        let x: [Double]
        let y: [Double]
        let m: [Double]

        init(points: [TonePoint]) {
            x = points.map(\.input)
            y = points.map(\.output)
            let n = x.count
            guard n >= 2 else {
                m = Array(repeating: 0, count: n)
                return
            }
            var d = [Double](repeating: 0, count: n - 1)
            for i in 0..<(n - 1) { d[i] = (y[i + 1] - y[i]) / (x[i + 1] - x[i]) }
            var t = [Double](repeating: 0, count: n)
            t[0] = d[0]
            t[n - 1] = d[n - 2]
            if n > 2 {
                for i in 1..<(n - 1) {
                    // A local extremum (or a flat side) gets a zero tangent, so the
                    // spline cannot overshoot the control points.
                    t[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2
                }
            }
            for i in 0..<(n - 1) {
                if d[i] == 0 {
                    t[i] = 0
                    t[i + 1] = 0
                    continue
                }
                let a = t[i] / d[i], b = t[i + 1] / d[i]
                let s = a * a + b * b
                if s > 9 {
                    let tau = 3 / s.squareRoot()
                    t[i] = tau * a * d[i]
                    t[i + 1] = tau * b * d[i]
                }
            }
            m = t
        }

        func value(at v: Double) -> Double {
            guard let first = x.first, let last = x.last else { return v }
            if x.count == 1 || v <= first { return y[0] }
            if v >= last { return y[y.count - 1] }
            var i = 0
            while i < x.count - 2, v > x[i + 1] { i += 1 }
            let h = x[i + 1] - x[i]
            let s = (v - x[i]) / h
            let s2 = s * s, s3 = s2 * s
            let value = (2 * s3 - 3 * s2 + 1) * y[i] + (s3 - 2 * s2 + s) * h * m[i] + (-2 * s3 + 3 * s2) * y[i + 1] + (s3 - s2) * h * m[i + 1]
            return min(max(value, 0), 1)
        }
    }

    /// The curve sampled once for a whole image: encoded input → linear
    /// output, 4,096 intervals, linearly interpolated (the spline is smooth,
    /// so the table error is far below one 16-bit step).
    public struct Table: Sendable {
        public static let intervals = 4096
        let linear: [Double]

        init(curve: ToneCurve) {
            let spline = Spline(points: curve.normalizedPoints)
            linear = (0...Self.intervals).map { SRGBTransfer.decode(spline.value(at: Double($0) / Double(Self.intervals))) }
        }

        @inline(__always)
        public func linearOutput(forEncoded e: Double) -> Double {
            let f = min(max(e.isNaN ? 0 : e, 0), 1) * Double(Self.intervals)
            let i = min(Int(f), Self.intervals - 1)
            let t = f - Double(i)
            return linear[i] + (linear[i + 1] - linear[i]) * t
        }
    }

    public func table() -> Table { Table(curve: self) }
}
