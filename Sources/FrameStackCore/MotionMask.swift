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
public enum MaskOps {
    /// Euclidean RGB distance in linear light between two premultiplied
    /// RGBA buffers, one value per pixel.
    public static func difference(_ frame: UnsafeBufferPointer<Float>, _ background: UnsafeBufferPointer<Float>, pixels: Int) -> [Float] {
        var out = [Float](repeating: 0, count: pixels)
        let f = frame.baseAddress!, b = background.baseAddress!
        out.withUnsafeMutableBufferPointer { o in
            let d = o.baseAddress!
            for p in 0..<pixels {
                let i = p * LinearImage.channelCount
                let dr = f[i] - b[i], dg = f[i + 1] - b[i + 1], db = f[i + 2] - b[i + 2]
                d[p] = (dr * dr + dg * dg + db * db).squareRoot()
            }
        }
        return out
    }

    /// 1 where `value > threshold`, else 0.
    public static func threshold(_ values: inout [Float], _ threshold: Float) {
        values.withUnsafeMutableBufferPointer { v in
            for i in 0..<v.count { v[i] = v[i] > threshold ? 1 : 0 }
        }
    }

    /// Separable running minimum (erode) or maximum (dilate) over a
    /// (2r+1)² square, edges clamped.
    public static func morph(_ mask: inout [Float], width: Int, height: Int, radius: Int, dilate: Bool) {
        guard radius > 0 else { return }
        var tmp = [Float](repeating: 0, count: mask.count)
        // Horizontal
        for y in 0..<height {
            for x in 0..<width {
                var best: Float = dilate ? -.infinity : .infinity
                for dx in -radius...radius {
                    let xx = min(max(x + dx, 0), width - 1)
                    let v = mask[y * width + xx]
                    best = dilate ? max(best, v) : min(best, v)
                }
                tmp[y * width + x] = best
            }
        }
        // Vertical
        for y in 0..<height {
            for x in 0..<width {
                var best: Float = dilate ? -.infinity : .infinity
                for dy in -radius...radius {
                    let yy = min(max(y + dy, 0), height - 1)
                    let v = tmp[yy * width + x]
                    best = dilate ? max(best, v) : min(best, v)
                }
                mask[y * width + x] = best
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
        guard radius > 0 else { return }
        var tmp = [Float](repeating: 0, count: mask.count)
        let window = Float(2 * radius + 1)
        for _ in 0..<3 {
            for y in 0..<height {
                var sum: Float = 0
                for dx in -radius...radius { sum += mask[y * width + min(max(dx, 0), width - 1)] }
                for x in 0..<width {
                    tmp[y * width + x] = sum / window
                    let leaving = min(max(x - radius, 0), width - 1)
                    let entering = min(max(x + radius + 1, 0), width - 1)
                    sum += mask[y * width + entering] - mask[y * width + leaving]
                }
            }
            for x in 0..<width {
                var sum: Float = 0
                for dy in -radius...radius { sum += tmp[min(max(dy, 0), height - 1) * width + x] }
                for y in 0..<height {
                    mask[y * width + x] = sum / window
                    let leaving = min(max(y - radius, 0), height - 1)
                    let entering = min(max(y + radius + 1, 0), height - 1)
                    sum += tmp[entering * width + x] - tmp[leaving * width + x]
                }
            }
            // Running sums leave ±1e-7 residues where the mask is really 0 or 1;
            // snap them so "no coverage" stays exactly zero.
            mask.withUnsafeMutableBufferPointer { v in
                for i in 0..<v.count {
                    if v[i] < 1e-5 { v[i] = 0 } else if v[i] > 1 - 1e-5 { v[i] = 1 }
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
            for p in 0..<m.count {
                let i = p * LinearImage.channelCount
                let w = m[p]
                f[i] *= w; f[i + 1] *= w; f[i + 2] *= w; f[i + 3] *= w
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
