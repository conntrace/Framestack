import Foundation

/// One brush stroke on the canvas, in canvas-normalised units (x, y in
/// 0…1 of the canvas width/height; radius in units of the canvas long
/// edge) so it is resolution-independent and survives any output size.
public struct MaskStroke: Sendable, Codable, Equatable {
    public struct Point: Sendable, Codable, Equatable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public var points: [Point]
    /// Brush radius as a fraction of the canvas long edge.
    public var radius: Double
    /// 0 = hard disc, 1 = fully soft (linear falloff from the centre).
    public var softness: Double
    /// Erase instead of paint.
    public var erase: Bool

    public init(points: [Point], radius: Double, softness: Double = 0.5, erase: Bool = false) {
        self.points = points
        self.radius = radius
        self.softness = softness
        self.erase = erase
    }
}

/// A hand-painted mask (PRD §6.4): where frames are allowed to blend;
/// elsewhere the background shows (the same background as the motion mask).
public struct PaintedMaskSettings: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var strokes: [MaskStroke]
    /// Painted regions exclude instead of include.
    public var invert: Bool

    public init(enabled: Bool = false, strokes: [MaskStroke] = [], invert: Bool = false) {
        self.enabled = enabled
        self.strokes = strokes
        self.invert = invert
    }

    public static let off = PaintedMaskSettings()
    public var isEmpty: Bool { strokes.isEmpty }
}

public enum PaintedMaskRasterizer {
    /// Rasterises the strokes into one value per pixel (0…1) for an output
    /// of `size`. Paint strokes take the maximum, erase strokes the minimum
    /// with the inverted brush, in stroke order. Stamps are placed along
    /// each polyline every quarter radius, so the result is continuous.
    public static func raster(_ settings: PaintedMaskSettings, size: PixelSize) -> [Float] {
        var mask = [Float](repeating: 0, count: size.pixelCount)
        let longEdge = Double(size.longEdge)
        for stroke in settings.strokes {
            let r = max(stroke.radius * longEdge, 0.5)
            let soft = min(max(stroke.softness, 0), 1)
            let pts = stroke.points.map { (x: $0.x * Double(size.width), y: $0.y * Double(size.height)) }
            guard let first = pts.first else { continue }
            var stamps = [first]
            if pts.count > 1 {
                let spacing = max(r / 4, 0.5)
                for i in 1..<pts.count {
                    let a = pts[i - 1], b = pts[i]
                    let d = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
                    let n = max(1, Int((d / spacing).rounded(.up)))
                    for k in 1...n {
                        let f = Double(k) / Double(n)
                        stamps.append((x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                    }
                }
            }
            for s in stamps {
                stamp(&mask, size: size, cx: s.x, cy: s.y, radius: r, softness: soft, erase: stroke.erase)
            }
        }
        if settings.invert {
            for i in 0..<mask.count { mask[i] = 1 - mask[i] }
        }
        return mask
    }

    /// Brush falloff: 1 inside the hard core, linear to 0 at the radius.
    static func falloff(distance: Double, radius: Double, softness: Double) -> Float {
        guard distance < radius else { return 0 }
        let core = radius * (1 - softness)
        if distance <= core { return 1 }
        return Float((radius - distance) / max(radius - core, 1e-9))
    }

    private static func stamp(_ mask: inout [Float], size: PixelSize, cx: Double, cy: Double, radius: Double, softness: Double, erase: Bool) {
        let x0 = max(0, Int((cx - radius).rounded(.down))), x1 = min(size.width - 1, Int((cx + radius).rounded(.up)))
        let y0 = max(0, Int((cy - radius).rounded(.down))), y1 = min(size.height - 1, Int((cy + radius).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let v = falloff(distance: (dx * dx + dy * dy).squareRoot(), radius: radius, softness: softness)
                guard v > 0 else { continue }
                let i = y * size.width + x
                mask[i] = erase ? min(mask[i], 1 - v) : max(mask[i], v)
            }
        }
    }
}
