import Foundation

/// Display orientation of encoded pixels, using EXIF / `CGImagePropertyOrientation`
/// raw values so it maps 1:1 onto Core Image's `oriented(_:)`.
public enum ImageOrientation: Int, Sendable, Codable, CaseIterable {
    case up = 1
    case upMirrored = 2
    case down = 3
    case downMirrored = 4
    case leftMirrored = 5
    case right = 6
    case rightMirrored = 7
    case left = 8

    /// True when width and height are exchanged for display.
    public var swapsDimensions: Bool { rawValue >= 5 }

    public func displaySize(forEncoded size: PixelSize) -> PixelSize {
        swapsDimensions ? PixelSize(width: size.height, height: size.width) : size
    }

    public var displayName: String {
        switch self {
        case .up: return "Upright"
        case .upMirrored: return "Mirrored"
        case .down: return "Rotated 180°"
        case .downMirrored: return "Rotated 180°, mirrored"
        case .leftMirrored: return "Transposed"
        case .right: return "Rotated 90° clockwise"
        case .rightMirrored: return "Transversed"
        case .left: return "Rotated 90° counter-clockwise"
        }
    }

    /// Maps a video track's `preferredTransform` matrix entries (a, b, c, d;
    /// translation ignored) to an orientation. AVFoundation transforms use a
    /// y-down coordinate system: display = (a·x + c·y + tx, b·x + d·y + ty).
    /// Returns nil for anything that is not a multiple of 90° (with optional
    /// mirroring) — such transforms are reported as unsupported rather than
    /// silently ignored.
    public static func fromVideoTransform(a: Double, b: Double, c: Double, d: Double) -> ImageOrientation? {
        func snap(_ v: Double) -> Int? {
            let r = v.rounded()
            guard abs(v - r) < 1e-6, r == 0 || r == 1 || r == -1 else { return nil }
            return Int(r)
        }
        guard let a = snap(a), let b = snap(b), let c = snap(c), let d = snap(d) else { return nil }
        switch (a, b, c, d) {
        case (1, 0, 0, 1): return .up
        case (-1, 0, 0, -1): return .down
        case (0, 1, -1, 0): return .right        // iPhone portrait
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        case (0, 1, 1, 0): return .leftMirrored  // transpose
        case (0, -1, -1, 0): return .rightMirrored // transverse
        default: return nil
        }
    }
}
