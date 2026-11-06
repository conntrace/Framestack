import Foundation

/// Integer pixel dimensions.
public struct PixelSize: Sendable, Codable, Equatable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var longEdge: Int { max(width, height) }
    public var pixelCount: Int { width * height }
    public var description: String { "\(width)×\(height)" }

    /// Size after uniformly scaling down so the long edge is at most
    /// `maxLongEdge` (never scales up). `nil` means native size.
    /// Each dimension is rounded to the nearest pixel and is at least 1.
    public func fitting(maxLongEdge: Int?) -> PixelSize {
        guard let maxLongEdge, maxLongEdge > 0, longEdge > maxLongEdge else { return self }
        let scale = Double(maxLongEdge) / Double(longEdge)
        return PixelSize(
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }
}

/// A floating-point RGBA image in FrameStack's working space.
///
/// Working space (see DECISIONS.md D-004):
/// - **Linear light** with **sRGB / Rec.709 primaries** and D65 white
///   ("extended linear sRGB": values may be < 0 or > 1 for wide-gamut or
///   super-white sources and are preserved until export).
/// - Channels interleaved R, G, B, A; 32-bit float.
/// - **Premultiplied alpha.** Video frames are opaque (A = 1).
/// - Row 0 is the top row of the upright (orientation-corrected) image.
public struct LinearImage: Sendable, Equatable {
    public static let channelCount = 4

    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(width > 0 && height > 0, "LinearImage dimensions must be positive")
        precondition(pixels.count == width * height * Self.channelCount, "LinearImage pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A solid-color image (premultiplied RGBA).
    public init(width: Int, height: Int, fill rgba: SIMD4<Float>) {
        var pixels = [Float](repeating: 0, count: width * height * Self.channelCount)
        for i in stride(from: 0, to: pixels.count, by: Self.channelCount) {
            pixels[i] = rgba.x
            pixels[i + 1] = rgba.y
            pixels[i + 2] = rgba.z
            pixels[i + 3] = rgba.w
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    public var size: PixelSize { PixelSize(width: width, height: height) }

    public func pixel(x: Int, y: Int) -> SIMD4<Float> {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel out of bounds")
        let i = (y * width + x) * Self.channelCount
        return SIMD4(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    /// Mean of a rectangular region (inclusive-exclusive), useful for tests
    /// and diagnostics that must tolerate codec noise.
    public func mean(x: Range<Int>, y: Range<Int>) -> SIMD4<Float> {
        var sum = SIMD4<Double>(repeating: 0)
        for yy in y {
            for xx in x {
                let p = pixel(x: xx, y: yy)
                sum += SIMD4<Double>(Double(p.x), Double(p.y), Double(p.z), Double(p.w))
            }
        }
        let n = Double(x.count * y.count)
        return SIMD4<Float>(Float(sum.x / n), Float(sum.y / n), Float(sum.z / n), Float(sum.w / n))
    }

    /// Smallest and largest alpha value in the image.
    public var alphaRange: ClosedRange<Float> {
        var lo = Float.infinity
        var hi = -Float.infinity
        for i in stride(from: 3, to: pixels.count, by: Self.channelCount) {
            lo = min(lo, pixels[i])
            hi = max(hi, pixels[i])
        }
        return lo...hi
    }
}
