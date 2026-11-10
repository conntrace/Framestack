import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// What the mask compares each frame against (PRD §6.3).
public enum MaskBackground: Sendable, Codable, Equatable {
    /// The exact temporal median of the selected frames (static scene).
    case median
    /// One selected frame; falls back to the median if it is not selected.
    case frame(FrameTime)

    private enum CodingKeys: String, CodingKey { case kind, time }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "median": self = .median
        case "frame": self = .frame(try c.decode(FrameTime.self, forKey: .time))
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown background \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .median: try c.encode("median", forKey: .kind)
        case let .frame(t): try c.encode("frame", forKey: .kind); try c.encode(t, forKey: .time)
        }
    }

    /// The frame to use, if this is a frame reference that is still selected.
    public func frameTime(in selected: [FrameTime]) -> FrameTime? {
        if case let .frame(t) = self, selected.contains(t) { return t }
        return nil
    }
}

/// Motion mask (PRD §6.3): per-pixel linear-light difference from a
/// background, threshold, morphological clean-up, feather, invert. Each
/// frame is multiplied by its mask before blending and the composite is
/// laid over the background. Non-destructive; part of the saved settings.
public struct MotionMaskSettings: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var background: MaskBackground
    /// Linear-light RGB distance above which a pixel counts as moving (0…1).
    public var threshold: Double
    /// Box-blur radius (output pixels) softening the mask edge; 0 = hard.
    public var feather: Int
    /// Morphological open-then-close radius (output pixels) removing specks
    /// and filling pinholes; 0 = none.
    public var cleanup: Int
    /// Keep the static parts instead of the moving ones.
    public var invert: Bool

    public init(enabled: Bool = false, background: MaskBackground = .median, threshold: Double = 0.08, feather: Int = 2,
                cleanup: Int = 1, invert: Bool = false) {
        self.enabled = enabled
        self.background = background
        self.threshold = threshold
        self.feather = feather
        self.cleanup = cleanup
        self.invert = invert
    }

    public static let off = MotionMaskSettings()
    public static let maximumRadius = 32
}

/// Mask arithmetic on output-sized Float buffers (one value per pixel,
/// 0…1). Pure functions; the renderer calls them per frame.
///
/// The per-pixel work runs on all cores in contiguous chunks of rows or
/// columns (D-038). Every value is computed by the same arithmetic in the
/// same order as a plain serial loop, so the result does not depend on the
/// number of cores (`MaskOpsReferenceTests` compares against serial code).
public enum MaskOps {
    /// Calls `body` with contiguous ranges covering `0..<count`, in parallel
    /// when there is enough work; each index belongs to exactly one range.
    static func parallel(_ count: Int, minimumChunk: Int, _ body: (Range<Int>) -> Void) {
        guard count > 0 else { return }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let chunks = max(1, min(cores, count / max(1, minimumChunk)))
        if chunks == 1 { return body(0..<count) }
        let size = (count + chunks - 1) / chunks
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let lo = c * size, hi = min(lo + size, count)
            if lo < hi { body(lo..<hi) }
        }
    }

    /// Rows per chunk so that a chunk is at least about 32k values.
    private static func rowChunk(width: Int) -> Int { max(1, 32768 / max(1, width)) }

    /// `dst[i] = max(dst[i], src[i])` (or min) for `count` values.
    @inline(__always)
    private static func extreme(_ dst: UnsafeMutablePointer<Float>, _ src: UnsafePointer<Float>, count: Int, dilate: Bool) {
        #if canImport(Accelerate)
        if dilate { vDSP_vmax(src, 1, dst, 1, dst, 1, vDSP_Length(count)) } else { vDSP_vmin(src, 1, dst, 1, dst, 1, vDSP_Length(count)) }
        #else
        if dilate { for i in 0..<count where src[i] > dst[i] { dst[i] = src[i] } } else { for i in 0..<count where src[i] < dst[i] { dst[i] = src[i] } }
        #endif
    }

    /// Euclidean RGB distance in linear light between two premultiplied
    /// RGBA buffers, one value per pixel.
    public static func difference(_ frame: UnsafeBufferPointer<Float>, _ background: UnsafeBufferPointer<Float>, pixels: Int) -> [Float] {
        var out = [Float](repeating: 0, count: pixels)
        let f = frame.baseAddress!, b = background.baseAddress!
        out.withUnsafeMutableBufferPointer { o in
            let d = o.baseAddress!
            parallel(pixels, minimumChunk: 32768) { range in
                for p in range {
                    let i = p * LinearImage.channelCount
                    let dr = f[i] - b[i], dg = f[i + 1] - b[i + 1], db = f[i + 2] - b[i + 2]
                    d[p] = (dr * dr + dg * dg + db * db).squareRoot()
                }
            }
        }
        return out
    }

    /// 1 where `value > threshold`, else 0.
    public static func threshold(_ values: inout [Float], _ threshold: Float) {
        values.withUnsafeMutableBufferPointer { v in
            let p = v.baseAddress!
            parallel(v.count, minimumChunk: 65536) { range in
                for i in range { p[i] = p[i] > threshold ? 1 : 0 }
            }
        }
    }

    /// Separable running minimum (erode) or maximum (dilate) over a
    /// (2r+1)² square, edges clamped.
    public static func morph(_ mask: inout [Float], width: Int, height: Int, radius: Int, dilate: Bool) {
        guard radius > 0, width > 0, height > 0 else { return }
        var tmp = [Float](repeating: 0, count: mask.count)
        let interior = width - 2 * radius
        mask.withUnsafeMutableBufferPointer { m in
            tmp.withUnsafeMutableBufferPointer { t in
                let src = m.baseAddress!, mid = t.baseAddress!
                // Horizontal: mask → tmp. Away from the edges the window is
                // the same 2r+1 shifted copies of the row for every pixel.
                parallel(height, minimumChunk: rowChunk(width: width)) { rows in
                    for y in rows {
                        let s = UnsafePointer(src + y * width), d = mid + y * width
                        if interior > 0 {
                            (d + radius).update(from: s, count: interior)
                            for k in 1...(2 * radius) { extreme(d + radius, s + k, count: interior, dilate: dilate) }
                        }
                        let edge = interior > 0 ? radius : width
                        for x in Array(0..<edge) + (interior > 0 ? Array((width - radius)..<width) : []) {
                            var best: Float = dilate ? -.infinity : .infinity
                            for dx in -radius...radius {
                                let v = s[min(max(x + dx, 0), width - 1)]
                                best = dilate ? max(best, v) : min(best, v)
                            }
                            d[x] = best
                        }
                    }
                }
                // Vertical: tmp → mask, whole rows at a time.
                parallel(height, minimumChunk: rowChunk(width: width)) { rows in
                    for y in rows {
                        let d = src + y * width
                        d.update(from: mid + min(max(y - radius, 0), height - 1) * width, count: width)
                        for dy in (1 - radius)...radius {
                            extreme(d, mid + min(max(y + dy, 0), height - 1) * width, count: width, dilate: dilate)
                        }
                    }
                }
            }
        }
    }

    /// Opening (erode then dilate) removes specks smaller than the radius;
    /// closing (dilate then erode) fills holes. Applied in that order.
    public static func cleanup(_ mask: inout [Float], width: Int, height: Int, radius: Int) {
        guard radius > 0 else { return }
        morph(&mask, width: width, height: height, radius: radius, dilate: false)
        morph(&mask, width: width, height: height, radius: radius, dilate: true)
        morph(&mask, width: width, height: height, radius: radius, dilate: true)
        morph(&mask, width: width, height: height, radius: radius, dilate: false)
    }

    /// Separable box blur of radius r, applied three times (≈ Gaussian),
    /// edges clamped. Keeps values in 0…1.
    public static func feather(_ mask: inout [Float], width: Int, height: Int, radius: Int) {
        guard radius > 0, width > 0, height > 0 else { return }
        var tmp = [Float](repeating: 0, count: mask.count)
        let window = Float(2 * radius + 1)
        mask.withUnsafeMutableBufferPointer { m in
            tmp.withUnsafeMutableBufferPointer { t in
                let a = m.baseAddress!, b = t.baseAddress!
                for _ in 0..<3 {
                    // Horizontal running sum, one row at a time: mask → tmp.
                    parallel(height, minimumChunk: rowChunk(width: width)) { rows in
                        for y in rows {
                            let s = a + y * width, d = b + y * width
                            var sum: Float = 0
                            for dx in -radius...radius { sum += s[min(max(dx, 0), width - 1)] }
                            for x in 0..<width {
                                d[x] = sum / window
                                let leaving = min(max(x - radius, 0), width - 1)
                                let entering = min(max(x + radius + 1, 0), width - 1)
                                sum += s[entering] - s[leaving]
                            }
                        }
                    }
                    // Vertical running sums, one per column, swept row by row
                    // (the same additions per column as a column-by-column
                    // loop, but in memory order): tmp → mask.
                    parallel(width, minimumChunk: max(64, 32768 / height)) { columns in
                        let n = columns.count, x0 = columns.lowerBound
                        var sums = [Float](repeating: 0, count: n)
                        sums.withUnsafeMutableBufferPointer { sumBuffer in
                            let sum = sumBuffer.baseAddress!
                            for dy in -radius...radius {
                                let row = b + min(max(dy, 0), height - 1) * width + x0
                                for i in 0..<n { sum[i] += row[i] }
                            }
                            for y in 0..<height {
                                let d = a + y * width + x0
                                let leaving = b + min(max(y - radius, 0), height - 1) * width + x0
                                let entering = b + min(max(y + radius + 1, 0), height - 1) * width + x0
                                for i in 0..<n {
                                    d[i] = sum[i] / window
                                    sum[i] += entering[i] - leaving[i]
                                }
                            }
                        }
                    }
                    // Running sums leave ±1e-7 residues where the mask is really 0 or 1;
                    // snap them so "no coverage" stays exactly zero.
                    parallel(m.count, minimumChunk: 65536) { range in
                        for i in range {
                            if a[i] < 1e-5 { a[i] = 0 } else if a[i] > 1 - 1e-5 { a[i] = 1 }
                        }
                    }
                }
            }
        }
    }

    public static func invert(_ mask: inout [Float]) {
        mask.withUnsafeMutableBufferPointer { v in for i in 0..<v.count { v[i] = 1 - v[i] } }
    }

    /// Multiplies every channel of a premultiplied RGBA buffer by the mask.
    public static func apply(_ mask: [Float], to frame: UnsafeMutableBufferPointer<Float>) {
        let f = frame.baseAddress!
        mask.withUnsafeBufferPointer { m in
            let w = m.baseAddress!
            parallel(m.count, minimumChunk: 32768) { range in
                for p in range {
                    let i = p * LinearImage.channelCount
                    let v = w[p]
                    f[i] *= v; f[i + 1] *= v; f[i + 2] *= v; f[i + 3] *= v
                }
            }
        }
    }

    /// Builds the mask for one frame: distance → threshold → clean-up →
    /// feather → invert.
    public static func mask(frame: UnsafeBufferPointer<Float>, background: UnsafeBufferPointer<Float>, width: Int, height: Int,
                            settings: MotionMaskSettings) -> [Float] {
        var m = difference(frame, background, pixels: width * height)
        threshold(&m, Float(settings.threshold))
        cleanup(&m, width: width, height: height, radius: min(max(settings.cleanup, 0), MotionMaskSettings.maximumRadius))
        feather(&m, width: width, height: height, radius: min(max(settings.feather, 0), MotionMaskSettings.maximumRadius))
        if settings.invert { invert(&m) }
        return m
    }

    /// `composite` (premultiplied) laid over an opaque `background`.
    public static func over(_ composite: LinearImage, background: LinearImage) -> LinearImage {
        precondition(composite.size == background.size)
        var out = composite.pixels
        let n = composite.width * composite.height
        out.withUnsafeMutableBufferPointer { o in
            background.pixels.withUnsafeBufferPointer { b in
                for p in 0..<n {
                    let i = p * LinearImage.channelCount
                    let k = 1 - min(max(o[i + 3], 0), 1)
                    o[i] += b[i] * k; o[i + 1] += b[i + 1] * k; o[i + 2] += b[i + 2] * k
                    o[i + 3] += b[i + 3] * k
                }
            }
        }
        return LinearImage(width: composite.width, height: composite.height, pixels: out)
    }
}
