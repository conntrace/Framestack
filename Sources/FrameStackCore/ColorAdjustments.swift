import Foundation

/// Post-composite colour (PRD §7, M6e). Applied once to the finished
/// composite, before straighten/crop/edge fill, never per frame, so
/// changing a slider re-processes a cached image rather than re-decoding.
///
/// Order and spaces (documented, see DECISIONS.md D-029):
/// 1. exposure: linear × 2^EV
/// 2. white balance: linear per-channel gains from temperature/tint
/// 3. saturation: linear, lerp from Rec. 709 luminance
/// 4. contrast: in sRGB-encoded space around mid-gray 0.5, then back to linear
/// Pixels with partial alpha are adjusted as straight colour (un-premultiplied
/// first, re-multiplied after).
public struct ColorAdjustments: Sendable, Codable, Equatable {
    /// Stops, −3…3.
    public var exposure: Double
    /// −1…1 (0 = unchanged); −1 flattens to mid-gray, 1 doubles the encoded distance from 0.5.
    public var contrast: Double
    /// −1…1 (0 = unchanged, −1 = gray).
    public var saturation: Double
    /// −1…1: negative = cooler (more blue), positive = warmer (more red).
    public var temperature: Double
    /// −1…1: negative = greener, positive = more magenta.
    public var tint: Double

    public init(exposure: Double = 0, contrast: Double = 0, saturation: Double = 0, temperature: Double = 0, tint: Double = 0) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
    }

    public static let identity = ColorAdjustments()
    public var isIdentity: Bool { self == .identity }

    /// Linear RGB gains for the white balance sliders: ±1 moves red and
    /// blue by ±30 % in opposite directions (temperature) and green by
    /// ∓20 % (tint). Deliberately simple and documented; not a CCT model.
    public var whiteBalanceGains: SIMD3<Double> {
        let t = min(max(temperature, -1), 1), g = min(max(tint, -1), 1)
        return SIMD3(1 + 0.3 * t, 1 - 0.2 * g, 1 - 0.3 * t)
    }
}

public enum ColorProcessor {
    public static let luminance = SIMD3<Double>(0.2126, 0.7152, 0.0722)

    /// Adjusts one straight (non-premultiplied) linear RGB colour.
    @inline(__always)
    public static func adjust(_ c: SIMD3<Double>, _ a: ColorAdjustments) -> SIMD3<Double> {
        var v = c
        if a.exposure != 0 { v *= pow(2, min(max(a.exposure, -10), 10)) }
        if a.temperature != 0 || a.tint != 0 { v *= a.whiteBalanceGains }
        if a.saturation != 0 {
            let y = (v * luminance).sum()
            let s = 1 + min(max(a.saturation, -1), 1)
            v = SIMD3(repeating: y) + (v - SIMD3(repeating: y)) * s
        }
        if a.contrast != 0 {
            let k = 1 + min(max(a.contrast, -1), 1)
            for i in 0..<3 {
                let encoded = SRGBTransfer.encode(min(max(v[i], 0), 1))
                let stretched = min(max(0.5 + (encoded - 0.5) * k, 0), 1)
                v[i] = SRGBTransfer.decode(stretched)
            }
        }
        return v
    }

    public static func apply(_ adjustments: ColorAdjustments, to image: LinearImage) -> LinearImage {
        guard !adjustments.isIdentity else { return image }
        var pixels = image.pixels
        let n = image.width * image.height
        pixels.withUnsafeMutableBufferPointer { p in
            for i in 0..<n {
                let o = i * LinearImage.channelCount
                let alpha = Double(p[o + 3])
                guard alpha > 0 else { continue }
                let straight = alpha < 1
                    ? SIMD3(Double(p[o]) / alpha, Double(p[o + 1]) / alpha, Double(p[o + 2]) / alpha)
                    : SIMD3(Double(p[o]), Double(p[o + 1]), Double(p[o + 2]))
                let out = adjust(straight, adjustments)
                let k = alpha < 1 ? alpha : 1
                p[o] = Float(out.x * k); p[o + 1] = Float(out.y * k); p[o + 2] = Float(out.z * k)
            }
        }
        return LinearImage(width: image.width, height: image.height, pixels: pixels)
    }
}
