import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// How the selected frames are combined (PRD §5.2). Every mode works on
/// FrameStack's working space — linear light, premultiplied Float32 RGBA
/// (see `LinearImage`) — and the same reducer serves preview and export.
///
/// Order-dependent modes consume frames oldest to newest; the renderer
/// delivers decoded frames in presentation order. See DECISIONS.md D-017
/// for the exact formulas, the start frame, the opacity rule and alpha.
public enum BlendMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case average
    case lighten
    case darken
    case screen
    case multiply
    case additive
    case difference
    case normal
    case median
    case maxLuminance
    case minLuminance

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .average: return "Average"
        case .lighten: return "Lighten"
        case .darken: return "Darken"
        case .screen: return "Screen"
        case .multiply: return "Multiply"
        case .additive: return "Additive"
        case .difference: return "Difference"
        case .normal: return "Normal (opacity stack)"
        case .median: return "Median"
        case .maxLuminance: return "Max Luminance"
        case .minLuminance: return "Min Luminance"
        }
    }

    /// Short, precise explanation surfaced in the UI (PRD §5.2 "mathematical
    /// transparency").
    public var explanation: String {
        switch self {
        case .average:
            return "Equal-weight mean: every selected frame contributes exactly 1/N. "
                + "Computed per channel in linear light with 64-bit accumulators, "
                + "like a long exposure. Not the same as stacking semi-transparent layers."
        case .lighten:
            return "Per-channel maximum across the selected frames: each channel keeps the "
                + "brightest value it ever had, so light trails stay bright. The result can be "
                + "a color no single frame contained. Order does not matter."
        case .darken:
            return "Per-channel minimum across the selected frames: each channel keeps the "
                + "darkest value it ever had, so dark trails stay dark. The result can be a "
                + "color no single frame contained. Order does not matter."
        case .screen:
            return "Sequential screen in linear light, oldest to newest, starting from the first "
                + "selected frame: new = 1 − (1 − composite) × (1 − frame). Each frame can only "
                + "brighten; many frames wash out toward white. Opacity scales each frame's effect."
        case .multiply:
            return "Sequential multiply in linear light, oldest to newest, starting from the first "
                + "selected frame: new = composite × frame. Each frame can only darken; many frames "
                + "approach black. Opacity scales each frame's effect."
        case .additive:
            return "Sum of all selected frames in linear light (each × opacity), like leaving the "
                + "shutter open. Values above 1 are kept in float and clipped only on export, so "
                + "highlights clip unless the scene is dark. Order does not matter."
        case .difference:
            return "Sequential absolute difference, oldest to newest, starting from the first "
                + "selected frame: new = |composite − frame|. Order-dependent; not a variance "
                + "or motion map. Opacity scales each frame's effect."
        case .normal:
            return "Chronological source-over: each frame is laid over the composite at the "
                + "chosen opacity. At 100 % only the last selected frame is visible; lower "
                + "opacity fades earlier frames away geometrically. Not an equal-weight average."
        case .median:
            return "Exact per-channel median of every selected frame at each pixel (the mean of the "
                + "two middle values for an even count), in linear light. Removes anything present in "
                + "fewer than half the frames — a moving subject vanishes, the static scene stays. "
                + "Needs the whole frame history: computed in horizontal bands within a memory "
                + "budget, decoding the clip once per band. Order and weights do not matter."
        case .maxLuminance:
            return "At each pixel the complete color of the single frame with the greatest "
                + "linear luminance (0.2126 R + 0.7152 G + 0.0722 B). Unlike Lighten the result is "
                + "always a color some frame really had there. Ties keep the earlier frame."
        case .minLuminance:
            return "At each pixel the complete color of the single frame with the least linear "
                + "luminance. Unlike Darken the result is always a color some frame really had "
                + "there. Ties keep the earlier frame."
        }
    }

    /// The exact median cannot stream: the renderer computes it band by band
    /// (see `MedianPlan`), decoding the source once per band.
    public var requiresFrameHistory: Bool { self == .median }

    /// The result depends on the chronological order of the frames.
    public var isOrderDependent: Bool {
        switch self {
        case .average, .lighten, .darken, .additive, .median, .maxLuminance, .minLuminance: return false
        case .screen, .multiply, .difference, .normal: return true
        }
    }

    /// The opacity parameter changes the result.
    public var usesOpacity: Bool {
        switch self {
        case .average, .lighten, .darken, .median, .maxLuminance, .minLuminance: return false
        case .screen, .multiply, .additive, .difference, .normal: return true
        }
    }

    /// Temporal weights change the result (mirrors the reducers' `usesWeights`).
    public var usesWeights: Bool {
        switch self {
        case .lighten, .darken, .median, .maxLuminance, .minLuminance: return false
        case .average, .additive, .screen, .multiply, .difference, .normal: return true
        }
    }

    /// Creates the streaming reducer for this mode at the given output size.
    /// `opacity` (0…1) is ignored by modes where `usesOpacity` is false.
    public func makeReducer(width: Int, height: Int, opacity: Float = 1) -> FrameReducer {
        switch self {
        case .average: return AverageAccumulator(width: width, height: height)
        case .lighten: return ExtremumReducer(width: width, height: height, kind: .maximum)
        case .darken: return ExtremumReducer(width: width, height: height, kind: .minimum)
        case .additive: return AdditiveReducer(width: width, height: height, opacity: opacity)
        case .screen: return SequentialReducer(width: width, height: height, operation: .screen, opacity: opacity)
        case .multiply: return SequentialReducer(width: width, height: height, operation: .multiply, opacity: opacity)
        case .difference: return SequentialReducer(width: width, height: height, operation: .difference, opacity: opacity)
        case .normal: return SequentialReducer(width: width, height: height, operation: .normal, opacity: opacity)
        case .maxLuminance: return LuminanceExtremumReducer(width: width, height: height, kind: .maximum)
        case .minLuminance: return LuminanceExtremumReducer(width: width, height: height, kind: .minimum)
        case .median:
            // Only meaningful for a band whose whole history fits; the
            // renderer sizes bands with `MedianPlan`. Used directly by tests.
            return MedianBandAccumulator(width: width, height: height, frameCapacity: 4096)
        }
    }
}

public enum CompositingError: Error, Equatable, LocalizedError {
    case dimensionMismatch(expected: Int, actual: Int)
    case noFrames
    case zeroTotalWeight
    case historyFull(capacity: Int)

    public var errorDescription: String? {
        switch self {
        case let .dimensionMismatch(expected, actual):
            return "Frame size changed mid-stack (expected \(expected) samples, got \(actual))."
        case .noFrames:
            return "No frames were composited."
        case .zeroTotalWeight:
            return "Every frame had zero weight; nothing could be averaged."
        case let .historyFull(capacity):
            return "More frames than the median band can hold (\(capacity))."
        }
    }
}

/// A streaming reduction of frames into one composite.
///
/// Frames are added one at a time (interleaved RGBA Float32 in the working
/// space, `width × height × 4` samples) and discarded; the reducer holds
/// only output-sized state, never a frame history. `result()` may be called
/// at any point after the first frame and leaves the reducer usable.
public protocol FrameReducer: AnyObject {
    var width: Int { get }
    var height: Int { get }
    /// Frames added so far.
    var count: Int { get }
    /// Approximate bytes held, for diagnostics and memory tests.
    var memoryFootprintBytes: Int { get }
    func add(_ frame: UnsafeBufferPointer<Float>) throws
    /// Adds a frame with a temporal weight (PRD §5.3). Modes that cannot use
    /// a weight (Lighten/Darken) ignore it; see each reducer.
    func add(_ frame: UnsafeBufferPointer<Float>, weight: Double) throws
    /// Whether this mode's result changes with temporal weights.
    var usesWeights: Bool { get }
    func result() throws -> LinearImage
}

public extension FrameReducer {
    func add(_ image: LinearImage) throws {
        try image.pixels.withUnsafeBufferPointer { try add($0) }
    }

    func add(_ image: LinearImage, weight: Double) throws {
        try image.pixels.withUnsafeBufferPointer { try add($0, weight: weight) }
    }

    /// Default: the weight is ignored.
    func add(_ frame: UnsafeBufferPointer<Float>, weight: Double) throws {
        try add(frame)
    }

    /// Whether this mode's result changes with temporal weights.
    var usesWeights: Bool { true }

    var sampleCount: Int { width * height * LinearImage.channelCount }

    func checkDimensions(_ frame: UnsafeBufferPointer<Float>) throws {
        guard frame.count == sampleCount else {
            throw CompositingError.dimensionMismatch(expected: sampleCount, actual: frame.count)
        }
    }
}

// MARK: - Average / Additive (Float64 sums)

/// Streaming, order-independent equal-weight mean (also the sum behind
/// Additive).
///
/// Memory is bounded by the output size, never by frame count: one 64-bit
/// sum per channel (`width × height × 4 × 8` bytes) plus a small fixed
/// conversion scratch buffer. Each frame is added once (no intermediate
/// rounding to 8 bits), and the result is `sum / count` per channel.
///
/// Precision: a Float32 input has a 24-bit significand, so sums of up to
/// 2^29 frames of the same value are exact in Float64; averaging N identical
/// frames reproduces the frame bit-for-bit.
///
/// Alpha: channels are averaged as stored (premultiplied), which is the
/// coverage-weighted mean of color. For opaque video A stays exactly 1.
public final class AverageAccumulator: FrameReducer {
    public let width: Int
    public let height: Int
    public private(set) var count: Int = 0
    /// Σ weights of the frames added (equals `count` when unweighted).
    public private(set) var weightTotal: Double = 0

    private var sums: [Double]
    #if canImport(Accelerate)
    private static let chunkSize = 16_384
    private var scratch: [Double]
    #endif

    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        sums = [Double](repeating: 0, count: width * height * LinearImage.channelCount)
        #if canImport(Accelerate)
        scratch = [Double](repeating: 0, count: Self.chunkSize)
        #endif
    }

    public var memoryFootprintBytes: Int {
        #if canImport(Accelerate)
        return (sums.count + scratch.count) * MemoryLayout<Double>.stride
        #else
        return sums.count * MemoryLayout<Double>.stride
        #endif
    }

    /// Adds one frame given as interleaved RGBA Float32 in the working space.
    public func add(_ frame: UnsafeBufferPointer<Float>) throws {
        try add(frame, weight: 1)
    }

    /// Adds `weight × frame` (weighted Average / exposure accumulation).
    /// A weight of exactly 1 reproduces the unweighted sum bit for bit.
    public func add(_ frame: UnsafeBufferPointer<Float>, weight: Double) throws {
        try checkDimensions(frame)
        precondition(weight.isFinite && weight >= 0, "weights must be finite and non-negative")
        guard let src = frame.baseAddress else { return }
        let total = frame.count
        var w = weight
        sums.withUnsafeMutableBufferPointer { accBuffer in
            let acc = accBuffer.baseAddress!
            #if canImport(Accelerate)
            scratch.withUnsafeMutableBufferPointer { scratchBuffer in
                let tmp = scratchBuffer.baseAddress!
                var offset = 0
                while offset < total {
                    let n = min(Self.chunkSize, total - offset)
                    vDSP_vspdp(src + offset, 1, tmp, 1, vDSP_Length(n))
                    if weight == 1 {
                        vDSP_vaddD(acc + offset, 1, tmp, 1, acc + offset, 1, vDSP_Length(n))
                    } else {
                        // acc = tmp × w + acc
                        vDSP_vsmaD(tmp, 1, &w, acc + offset, 1, acc + offset, 1, vDSP_Length(n))
                    }
                    offset += n
                }
            }
            #else
            for i in 0..<total {
                acc[i] += Double(src[i]) * w
            }
            #endif
        }
        count += 1
        weightTotal += weight
    }

    /// The weighted mean of all added frames (`Σ w·frame / Σ w`; the plain
    /// mean when unweighted). The accumulator stays usable.
    public func result() throws -> LinearImage {
        guard count > 0 else { throw CompositingError.noFrames }
        guard weightTotal > 0 else { throw CompositingError.zeroTotalWeight }
        return scaled(by: 1 / weightTotal)
    }

    /// The sum of all added frames times `scale` (Additive).
    public func sum(scaledBy scale: Double) throws -> LinearImage {
        guard count > 0 else { throw CompositingError.noFrames }
        return scaled(by: scale)
    }

    private func scaled(by scale: Double) -> LinearImage {
        var out = [Float](repeating: 0, count: sums.count)
        var factor = scale
        let total = sums.count
        sums.withUnsafeBufferPointer { accBuffer in
            out.withUnsafeMutableBufferPointer { outBuffer in
                let acc = accBuffer.baseAddress!
                let dst = outBuffer.baseAddress!
                #if canImport(Accelerate)
                scratch.withUnsafeMutableBufferPointer { scratchBuffer in
                    let tmp = scratchBuffer.baseAddress!
                    var offset = 0
                    while offset < total {
                        let n = min(Self.chunkSize, total - offset)
                        vDSP_vsmulD(acc + offset, 1, &factor, tmp, 1, vDSP_Length(n))
                        vDSP_vdpsp(tmp, 1, dst + offset, 1, vDSP_Length(n))
                        offset += n
                    }
                }
                #else
                for i in 0..<total {
                    dst[i] = Float(acc[i] * factor)
                }
                #endif
            }
        }
        return LinearImage(width: width, height: height, pixels: out)
    }
}

/// Additive: `Σ frame × opacity` in Float64. Values above 1 are preserved
/// (clipped only when encoding for export). Alpha is summed too, so an
/// opaque N-frame stack has alpha N × opacity; the exporter treats alpha
/// ≥ 1 as opaque.
public final class AdditiveReducer: FrameReducer {
    private let sums: AverageAccumulator
    public let opacity: Float

    public init(width: Int, height: Int, opacity: Float) {
        sums = AverageAccumulator(width: width, height: height)
        self.opacity = opacity
    }

    public var width: Int { sums.width }
    public var height: Int { sums.height }
    public var count: Int { sums.count }
    public var memoryFootprintBytes: Int { sums.memoryFootprintBytes }
    public func add(_ frame: UnsafeBufferPointer<Float>) throws { try sums.add(frame) }
    /// Exposure accumulation: the raw curve weight scales each frame's
    /// contribution (not normalised — "intentionally using exposure accumulation").
    public func add(_ frame: UnsafeBufferPointer<Float>, weight: Double) throws { try sums.add(frame, weight: weight) }
    public func result() throws -> LinearImage { try sums.sum(scaledBy: Double(opacity)) }
}

// MARK: - Lighten / Darken (per-channel extremum)

/// Per-channel running maximum (Lighten) or minimum (Darken), Float32,
/// exact (no arithmetic, only comparisons). Alpha is reduced the same way;
/// opaque sources stay opaque.
public final class ExtremumReducer: FrameReducer {
    public enum Kind: Sendable { case maximum, minimum }

    public let width: Int
    public let height: Int
    public let kind: Kind
    public private(set) var count: Int = 0
    private var state: [Float]

    public init(width: Int, height: Int, kind: Kind) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        self.kind = kind
        state = [Float](repeating: 0, count: width * height * LinearImage.channelCount)
    }

    public var memoryFootprintBytes: Int { state.count * MemoryLayout<Float>.stride }
    /// A per-channel extremum has no notion of weight.
    public var usesWeights: Bool { false }

    public func add(_ frame: UnsafeBufferPointer<Float>) throws {
        try checkDimensions(frame)
        guard let src = frame.baseAddress else { return }
        let total = frame.count
        let kind = self.kind
        state.withUnsafeMutableBufferPointer { buffer in
            let dst = buffer.baseAddress!
            if count == 0 {
                dst.update(from: src, count: total)
                return
            }
            #if canImport(Accelerate)
            // vDSP_vmax/vmin permit in-place operation (output may alias an input).
            switch kind {
            case .maximum: vDSP_vmax(dst, 1, src, 1, dst, 1, vDSP_Length(total))
            case .minimum: vDSP_vmin(dst, 1, src, 1, dst, 1, vDSP_Length(total))
            }
            #else
            switch kind {
            case .maximum: for i in 0..<total { dst[i] = max(dst[i], src[i]) }
            case .minimum: for i in 0..<total { dst[i] = min(dst[i], src[i]) }
            }
            #endif
        }
        count += 1
    }

    public func result() throws -> LinearImage {
        guard count > 0 else { throw CompositingError.noFrames }
        return LinearImage(width: width, height: height, pixels: state)
    }
}

// MARK: - Sequential modes (Screen, Multiply, Difference, Normal)

/// Order-dependent compositing, oldest frame first.
///
/// The first frame initialises the composite unchanged. Every later frame F
/// updates each color channel of the composite C as
///
///     C' = C + opacity × (B(C, F) − C)
///
/// where B is the mode's blend function on linear-light values:
/// screen `C + F − C·F`, multiply `C·F`, difference `|C − F|`, normal `F`.
/// Frames are premultiplied RGBA; a frame that only partly covers a pixel
/// (alpha a_F < 1, e.g. a masked or aligned frame) blends only where it
/// covers: `B' = (1 − a_F) × C + a_F × B(C, F ÷ a_F)` (the W3C compositing
/// rule), so an uncovered pixel leaves the composite unchanged and Normal is
/// exact source-over. For opaque frames this is the plain blend. Alpha uses
/// source-over coverage (`A' = A + opacity × a_F × (1 − A)`). With opacity
/// 0 nothing changes. State is one Float32 RGBA image.
public final class SequentialReducer: FrameReducer {
    public enum Operation: Sendable { case screen, multiply, difference, normal }

    public let width: Int
    public let height: Int
    public let operation: Operation
    public let opacity: Float
    public private(set) var count: Int = 0
    private var state: [Float]

    public init(width: Int, height: Int, operation: Operation, opacity: Float) {
        precondition(width > 0 && height > 0)
        precondition(opacity.isFinite)
        self.width = width
        self.height = height
        self.operation = operation
        self.opacity = min(max(opacity, 0), 1)
        state = [Float](repeating: 0, count: width * height * LinearImage.channelCount)
    }

    public var memoryFootprintBytes: Int { state.count * MemoryLayout<Float>.stride }

    public func add(_ frame: UnsafeBufferPointer<Float>) throws {
        try add(frame, weight: 1)
    }

    /// The raw curve weight scales this frame's opacity (`opacity × weight`).
    /// The first frame initialises the composite regardless of its weight.
    public func add(_ frame: UnsafeBufferPointer<Float>, weight: Double) throws {
        try checkDimensions(frame)
        guard let src = frame.baseAddress else { return }
        let total = frame.count
        let a = opacity * Float(min(max(weight, 0), 1))
        let operation = self.operation
        state.withUnsafeMutableBufferPointer { buffer in
            let c = buffer.baseAddress!
            if count == 0 {
                c.update(from: src, count: total)
                return
            }
            var i = 0
            while i < total {
                let fa = min(max(src[i + 3], 0), 1)
                // RGB: blend only where the frame covers the pixel.
                for k in i..<(i + 3) {
                    let cv = c[k]
                    let fv = src[k]
                    let straight = fa > 0 ? fv / fa : 0
                    let b: Float
                    switch operation {
                    case .screen: b = cv + straight - cv * straight
                    case .multiply: b = cv * straight
                    case .difference: b = abs(cv - straight)
                    case .normal: b = straight
                    }
                    let blended = (1 - fa) * cv + fa * b
                    c[k] = cv + a * (blended - cv)
                }
                // Alpha: source-over coverage.
                let ca = c[i + 3]
                c[i + 3] = ca + a * fa * (1 - ca)
                i += LinearImage.channelCount
            }
        }
        count += 1
    }

    public func result() throws -> LinearImage {
        guard count > 0 else { throw CompositingError.noFrames }
        return LinearImage(width: width, height: height, pixels: state)
    }
}
