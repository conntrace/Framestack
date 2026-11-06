import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// How the selected frames are combined.
///
/// M1 implements Average only. The remaining PRD §5.2 modes (Lighten,
/// Darken, Screen, Multiply, Additive, Difference, Normal/Opacity, Median,
/// luminance max/min, motion accumulation) are planned in
/// IMPLEMENTATION_PLAN.md (M2, M6) and will be added here as reducers with
/// their own reference tests.
public enum BlendMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case average

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .average: return "Average"
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
        }
    }
}

public enum CompositingError: Error, Equatable, LocalizedError {
    case dimensionMismatch(expected: Int, actual: Int)
    case noFrames

    public var errorDescription: String? {
        switch self {
        case let .dimensionMismatch(expected, actual):
            return "Frame size changed mid-stack (expected \(expected) samples, got \(actual))."
        case .noFrames:
            return "No frames were composited."
        }
    }
}

/// Streaming, order-independent equal-weight mean.
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
public final class AverageAccumulator {
    public let width: Int
    public let height: Int
    public private(set) var count: Int = 0

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

    public var sampleCount: Int { sums.count }

    /// Approximate bytes held by this accumulator.
    public var memoryFootprintBytes: Int {
        #if canImport(Accelerate)
        return (sums.count + scratch.count) * MemoryLayout<Double>.stride
        #else
        return sums.count * MemoryLayout<Double>.stride
        #endif
    }

    public func add(_ image: LinearImage) throws {
        try image.pixels.withUnsafeBufferPointer { try add($0) }
    }

    /// Adds one frame given as interleaved RGBA Float32 in the working space.
    public func add(_ frame: UnsafeBufferPointer<Float>) throws {
        guard frame.count == sums.count else {
            throw CompositingError.dimensionMismatch(expected: sums.count, actual: frame.count)
        }
        guard let src = frame.baseAddress else { return }
        let total = frame.count
        sums.withUnsafeMutableBufferPointer { accBuffer in
            let acc = accBuffer.baseAddress!
            #if canImport(Accelerate)
            scratch.withUnsafeMutableBufferPointer { scratchBuffer in
                let tmp = scratchBuffer.baseAddress!
                var offset = 0
                while offset < total {
                    let n = min(Self.chunkSize, total - offset)
                    vDSP_vspdp(src + offset, 1, tmp, 1, vDSP_Length(n))
                    vDSP_vaddD(acc + offset, 1, tmp, 1, acc + offset, 1, vDSP_Length(n))
                    offset += n
                }
            }
            #else
            for i in 0..<total {
                acc[i] += Double(src[i])
            }
            #endif
        }
        count += 1
    }

    /// The mean of all added frames. The accumulator stays usable.
    public func result() throws -> LinearImage {
        guard count > 0 else { throw CompositingError.noFrames }
        var out = [Float](repeating: 0, count: sums.count)
        var divisor = Double(count)
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
                        vDSP_vsdivD(acc + offset, 1, &divisor, tmp, 1, vDSP_Length(n))
                        vDSP_vdpsp(tmp, 1, dst + offset, 1, vDSP_Length(n))
                        offset += n
                    }
                }
                #else
                for i in 0..<total {
                    dst[i] = Float(acc[i] / divisor)
                }
                #endif
            }
        }
        return LinearImage(width: width, height: height, pixels: out)
    }
}
