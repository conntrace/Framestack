import Foundation

/// The IEC 61966-2-1 (sRGB) transfer function, piecewise exact form.
///
/// Used to encode FrameStack's linear working space for export and preview.
/// Source decoding/linearization is done by Core Image from the source's own
/// color tags (see DECISIONS.md D-004), not by these functions.
public enum SRGBTransfer {
    /// Linear light → sRGB-encoded value. Defined for 0…1; values outside
    /// are clamped by the encoders below, not here.
    public static func encode(_ linear: Double) -> Double {
        if linear <= 0.003_130_8 {
            return 12.92 * linear
        }
        return 1.055 * pow(linear, 1.0 / 2.4) - 0.055
    }

    /// sRGB-encoded value → linear light.
    public static func decode(_ encoded: Double) -> Double {
        if encoded <= 0.040_45 {
            return encoded / 12.92
        }
        return pow((encoded + 0.055) / 1.055, 2.4)
    }
}

public enum ExportBitDepth: Int, Sendable, Codable, CaseIterable, Identifiable {
    case eight = 8
    case sixteen = 16

    public var id: Int { rawValue }
    public var maxValue: Int { (1 << rawValue) - 1 }
    public var displayName: String { "\(rawValue)-bit" }
}

/// Converts working-space images to integer sRGB samples for output.
///
/// Policy (documented in DECISIONS.md D-005):
/// 1. Alpha is ignored; callers must ensure the image is opaque (M1 sources
///    are always opaque video). Premultiplied RGB of an opaque pixel equals
///    its color.
/// 2. Each linear channel is clamped to [0, 1] (out-of-gamut and super-white
///    values are clipped per channel — no tone mapping in M1).
/// 3. The sRGB transfer function is applied in Float64.
/// 4. The result is scaled to the integer range and rounded to nearest
///    (ties away from zero). No dithering.
/// Output is RGB interleaved, 3 samples per pixel, rows top to bottom.
public enum PixelEncoder {
    @inline(__always)
    public static func quantize(linear: Float, maxValue: Int) -> Int {
        quantizeDouble(linear.isNaN ? 0 : Double(linear), maxValue: maxValue)
    }

    @inline(__always)
    static func quantizeDouble(_ linear: Double, maxValue: Int) -> Int {
        // NaN is treated as 0 so a bad sample can never trap the encoder.
        let value = linear.isNaN ? 0 : linear
        let clamped = min(max(value, 0), 1)
        let encoded = min(max(SRGBTransfer.encode(clamped), 0), 1)
        return Int((encoded * Double(maxValue)).rounded())
    }

    public static func encodeSRGB8(_ image: LinearImage) -> [UInt8] {
        encode8(image, colorSpace: .sRGB)
    }

    public static func encodeSRGB16(_ image: LinearImage) -> [UInt16] {
        encode16(image, colorSpace: .sRGB)
    }

    /// 8-bit RGB samples in `colorSpace`. Display P3 output first converts
    /// the linear sRGB working values to linear P3 (3×3 matrix, Float64),
    /// then applies the same transfer curve, clamp and rounding.
    public static func encode8(_ image: LinearImage, colorSpace: OutputColorSpace) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 3)
        encode(image, colorSpace: colorSpace, maxValue: 255) { i, v in out[i] = UInt8(v) }
        return out
    }

    public static func encode16(_ image: LinearImage, colorSpace: OutputColorSpace) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: image.width * image.height * 3)
        encode(image, colorSpace: colorSpace, maxValue: 65_535) { i, v in out[i] = UInt16(v) }
        return out
    }

    @inline(__always)
    private static func encode(_ image: LinearImage, colorSpace: OutputColorSpace, maxValue: Int,
                               store: (Int, Int) -> Void) {
        let pixelCount = image.width * image.height
        let matrix = ColorPrimaries.matrix(fromSRGBTo: colorSpace)
        image.pixels.withUnsafeBufferPointer { src in
            for p in 0..<pixelCount {
                let s = p * LinearImage.channelCount
                let d = p * 3
                if let m = matrix {
                    let r = Double(src[s]), g = Double(src[s + 1]), b = Double(src[s + 2])
                    store(d, quantizeDouble(m[0] * r + m[1] * g + m[2] * b, maxValue: maxValue))
                    store(d + 1, quantizeDouble(m[3] * r + m[4] * g + m[5] * b, maxValue: maxValue))
                    store(d + 2, quantizeDouble(m[6] * r + m[7] * g + m[8] * b, maxValue: maxValue))
                } else {
                    store(d, quantize(linear: src[s], maxValue: maxValue))
                    store(d + 1, quantize(linear: src[s + 1], maxValue: maxValue))
                    store(d + 2, quantize(linear: src[s + 2], maxValue: maxValue))
                }
            }
        }
    }
}

/// RGB primaries and the matrices between them, derived from the CIE xy
/// chromaticities (not hard-coded tables), so sRGB ↔ Display P3 conversion
/// is exact to Float64 precision. Both spaces use the D65 white point, so
/// no chromatic adaptation is involved.
public enum ColorPrimaries {
    public struct Chromaticities: Sendable, Equatable {
        public var red: (x: Double, y: Double)
        public var green: (x: Double, y: Double)
        public var blue: (x: Double, y: Double)
        public var white: (x: Double, y: Double)

        public static func == (lhs: Chromaticities, rhs: Chromaticities) -> Bool {
            lhs.red == rhs.red && lhs.green == rhs.green && lhs.blue == rhs.blue && lhs.white == rhs.white
        }
    }

    public static let d65 = (x: 0.3127, y: 0.3290)
    /// IEC 61966-2-1.
    public static let sRGB = Chromaticities(red: (0.64, 0.33), green: (0.30, 0.60), blue: (0.15, 0.06), white: d65)
    /// SMPTE EG 432-1 (DCI-P3) primaries with a D65 white point.
    public static let displayP3 = Chromaticities(red: (0.680, 0.320), green: (0.265, 0.690), blue: (0.150, 0.060), white: d65)

    /// Row-major 3×3 matrix taking linear RGB in `space` to CIE XYZ (Y = 1 for white).
    public static func rgbToXYZ(_ space: Chromaticities) -> [Double] {
        func xyz(_ c: (x: Double, y: Double)) -> [Double] { [c.x / c.y, 1, (1 - c.x - c.y) / c.y] }
        let r = xyz(space.red), g = xyz(space.green), b = xyz(space.blue), w = xyz(space.white)
        let p = [r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]]
        let s = apply(invert(p), to: w)
        return [r[0] * s[0], g[0] * s[1], b[0] * s[2],
                r[1] * s[0], g[1] * s[1], b[1] * s[2],
                r[2] * s[0], g[2] * s[1], b[2] * s[2]]
    }

    /// Row-major matrix from linear `from` RGB to linear `to` RGB.
    public static func matrix(from: Chromaticities, to: Chromaticities) -> [Double] {
        multiply(invert(rgbToXYZ(to)), rgbToXYZ(from))
    }

    /// `nil` when no conversion is needed (the working primaries are sRGB).
    public static func matrix(fromSRGBTo space: OutputColorSpace) -> [Double]? {
        switch space {
        case .sRGB: return nil
        case .displayP3: return sRGBToDisplayP3
        }
    }

    public static let sRGBToDisplayP3: [Double] = matrix(from: sRGB, to: displayP3)
    public static let displayP3ToSRGB: [Double] = matrix(from: displayP3, to: sRGB)

    public static func apply(_ m: [Double], to v: [Double]) -> [Double] {
        [m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
         m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
         m[6] * v[0] + m[7] * v[1] + m[8] * v[2]]
    }

    public static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                out[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j]
            }
        }
        return out
    }

    public static func invert(_ m: [Double]) -> [Double] {
        let (a, b, c, d, e, f, g, h, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        precondition(abs(det) > 1e-12, "singular primaries matrix")
        return [
            (e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
            (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
            (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det,
        ]
    }
}
