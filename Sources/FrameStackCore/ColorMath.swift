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
        // NaN is treated as 0 so a bad sample can never trap the encoder.
        let value = linear.isNaN ? 0 : Double(linear)
        let clamped = min(max(value, 0), 1)
        let encoded = min(max(SRGBTransfer.encode(clamped), 0), 1)
        return Int((encoded * Double(maxValue)).rounded())
    }

    public static func encodeSRGB8(_ image: LinearImage) -> [UInt8] {
        let pixelCount = image.width * image.height
        var out = [UInt8](repeating: 0, count: pixelCount * 3)
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for p in 0..<pixelCount {
                    let s = p * LinearImage.channelCount
                    let d = p * 3
                    dst[d] = UInt8(quantize(linear: src[s], maxValue: 255))
                    dst[d + 1] = UInt8(quantize(linear: src[s + 1], maxValue: 255))
                    dst[d + 2] = UInt8(quantize(linear: src[s + 2], maxValue: 255))
                }
            }
        }
        return out
    }

    public static func encodeSRGB16(_ image: LinearImage) -> [UInt16] {
        let pixelCount = image.width * image.height
        var out = [UInt16](repeating: 0, count: pixelCount * 3)
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for p in 0..<pixelCount {
                    let s = p * LinearImage.channelCount
                    let d = p * 3
                    dst[d] = UInt16(quantize(linear: src[s], maxValue: 65_535))
                    dst[d + 1] = UInt16(quantize(linear: src[s + 1], maxValue: 65_535))
                    dst[d + 2] = UInt16(quantize(linear: src[s + 2], maxValue: 65_535))
                }
            }
        }
        return out
    }
}
