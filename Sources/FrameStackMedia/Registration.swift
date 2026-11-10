import CoreGraphics
import CoreImage
import Foundation
import FrameStackCore
import Vision
import simd

/// A per-frame transform (source pixels, Core Image coordinates: origin
/// bottom-left) that moves the frame onto the reference frame.
public enum AlignmentTransform: Sendable, Equatable {
    case identity
    case translation(dx: Double, dy: Double)
    /// Row-major 3×3 homography (maps frame points to reference points).
    case homography([Double])

    /// Largest corner displacement in source pixels for a frame of `size`.
    public func maxDisplacement(for size: PixelSize) -> Double {
        switch self {
        case .identity:
            return 0
        case let .translation(dx, dy):
            return (dx * dx + dy * dy).squareRoot()
        case .homography:
            let corners = corners(of: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            let originals = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
            return zip(corners, originals).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
        }
    }

    /// Where the rectangle's corners land: bottom-left, bottom-right, top-right, top-left.
    public func corners(of rect: CGRect) -> [CGPoint] {
        let pts = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                   CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        switch self {
        case .identity:
            return pts
        case let .translation(dx, dy):
            return pts.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        case let .homography(h):
            return pts.map { p in
                let w = h[6] * p.x + h[7] * p.y + h[8]
                return CGPoint(x: (h[0] * p.x + h[1] * p.y + h[2]) / w, y: (h[3] * p.x + h[4] * p.y + h[5]) / w)
            }
        }
    }

    /// Axis-aligned rectangle guaranteed to lie inside the transformed frame
    /// (conservative for a warped quad).
    public func innerRect(of rect: CGRect) -> CGRect {
        let c = corners(of: rect)
        let minX = max(c[0].x, c[3].x), maxX = min(c[1].x, c[2].x)
        let minY = max(c[0].y, c[1].y), maxY = min(c[2].y, c[3].y)
        guard maxX > minX, maxY > minY else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The same transform expressed for a frame scaled by `factor`.
    func scaled(by factor: Double) -> AlignmentTransform {
        switch self {
        case .identity:
            return .identity
        case let .translation(dx, dy):
            return .translation(dx: dx * factor, dy: dy * factor)
        case let .homography(h):
            // S · H · S⁻¹ with S = diag(f, f, 1).
            return .homography([h[0], h[1], h[2] * factor,
                                h[3], h[4], h[5] * factor,
                                h[6] / factor, h[7] / factor, h[8]])
        }
    }

    func apply(to image: CIImage) -> CIImage {
        switch self {
        case .identity:
            return image
        case let .translation(dx, dy):
            return image.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        case .homography:
            let c = corners(of: image.extent)
            return image.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputBottomLeft": CIVector(cgPoint: c[0]),
                "inputBottomRight": CIVector(cgPoint: c[1]),
                "inputTopRight": CIVector(cgPoint: c[2]),
                "inputTopLeft": CIVector(cgPoint: c[3]),
            ])
        }
    }
}

/// What alignment did during a render (PRD §6.1: report failures, never
/// claim perfection).
public struct AlignmentReport: Sendable, Equatable {
    public let mode: AlignmentMode
    public let referenceTime: FrameTime
    /// Long edge of the images handed to Vision (source pixels if smaller).
    public let analysisLongEdge: Int
    /// Frames (other than the reference) that received a transform.
    public let alignedFrames: Int
    /// Frames Vision could not register (or whose shift was implausible);
    /// they were **left out** of the composite rather than stacked misaligned.
    public let failedFrames: [FrameTime]
    /// Perspective mode only: frames whose homography disagreed with the
    /// plain shift and were aligned by the shift instead.
    public let fallbackFrames: [FrameTime]
    /// Largest corner displacement applied, in source pixels.
    public let maxShiftPixels: Double
    /// Intersection of all transformed frames in *output* pixels (origin
    /// top-left, like the image) — the "safe crop" with no empty edges.
    public let validArea: CGRect
    /// Transforms were reused from an earlier render of the same frames.
    public let fromCache: Bool
    /// The transform applied to each composited frame (source pixels).
    public let transforms: [FrameTime: AlignmentTransform]

    public var summary: String {
        var parts = ["\(alignedFrames) aligned to frame at \(String(format: "%.3f s", referenceTime.seconds))"]
        parts.append(String(format: "max shift %.1f px", maxShiftPixels))
        if !failedFrames.isEmpty { parts.append("\(failedFrames.count) could not be aligned and were left out") }
        if !fallbackFrames.isEmpty { parts.append("\(fallbackFrames.count) used a plain shift (perspective warp not trusted)") }
        return parts.joined(separator: " · ")
    }
}

/// Vision-based registration of frames to a reference, computed at a fixed
/// analysis size so preview and export apply identical transforms, and
/// cached per source/reference/mode so an export reuses the preview's work.
/// A cached registration result, including the outcome flags so a reused
/// result reports the same failures and fallbacks as the original run.
struct RegistrationOutcome: Sendable, Equatable {
    var transform: AlignmentTransform
    var failed = false
    var fellBack = false
}

final class RegistrationEngine: @unchecked Sendable {
    /// Long edge handed to Vision. Precision is about one analysis pixel:
    /// ≤ 1.9 source px for 4K, 2.8 px for a 24-megapixel still.
    static let analysisLongEdge = 2048

    struct Key: Hashable {
        let sourcePath: String
        let sourceStamp: String
        let reference: FrameTime
        let mode: AlignmentMode
    }

    private let lock = NSLock()
    private var cache: [Key: [FrameTime: RegistrationOutcome]] = [:]

    func cached(_ key: Key) -> [FrameTime: RegistrationOutcome] {
        lock.lock(); defer { lock.unlock() }
        return cache[key] ?? [:]
    }

    func store(_ outcomes: [FrameTime: RegistrationOutcome], for key: Key) {
        lock.lock(); defer { lock.unlock() }
        cache[key, default: [:]].merge(outcomes) { _, new in new }
        // Bound the memory: keep the most recent few sources/references.
        if cache.count > 8, let victim = cache.keys.first(where: { $0 != key }) { cache.removeValue(forKey: victim) }
    }

    /// A transform is only used when the moved frame still overlaps at least
    /// `minimumOverlap` of the canvas in each direction; beyond that the
    /// registration is almost certainly wrong (or the scene genuinely moved
    /// away, in which case stacking it makes no sense either).
    static let minimumOverlap = 0.5

    static func plausible(_ transform: AlignmentTransform, in rect: CGRect) -> Bool {
        let inner = transform.innerRect(of: rect).intersection(rect)
        guard !inner.isNull else { return false }
        return inner.width >= rect.width * minimumOverlap && inner.height >= rect.height * minimumOverlap
    }

    /// True when every corner of `rect` lands within `tolerance` pixels of
    /// where the other transform puts it.
    static func agree(_ a: AlignmentTransform, _ b: AlignmentTransform, in rect: CGRect, tolerance: Double) -> Bool {
        zip(a.corners(of: rect), b.corners(of: rect)).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) <= tolerance }
    }

    /// Registers `target` (a frame) onto `reference`; both at analysis size.
    /// Returns nil when Vision produces no usable result.
    static func register(target: CGImage, reference: CGImage, mode: AlignmentMode) -> AlignmentTransform? {
        do {
            switch mode {
            case .translation:
                let request = VNTranslationalImageRegistrationRequest(targetedCGImage: target, options: [:])
                try VNImageRequestHandler(cgImage: reference, options: [:]).perform([request])
                guard let result = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
                let t = result.alignmentTransform
                guard t.tx.isFinite, t.ty.isFinite else { return nil }
                return .translation(dx: Double(t.tx), dy: Double(t.ty))
            case .perspective:
                let request = VNHomographicImageRegistrationRequest(targetedCGImage: target, options: [:])
                try VNImageRequestHandler(cgImage: reference, options: [:]).perform([request])
                guard let result = request.results?.first as? VNImageHomographicAlignmentObservation else { return nil }
                let m = result.warpTransform   // column-major simd: m[column][row]
                let h: [Double] = [Double(m[0][0]), Double(m[1][0]), Double(m[2][0]),
                                   Double(m[0][1]), Double(m[1][1]), Double(m[2][1]),
                                   Double(m[0][2]), Double(m[1][2]), Double(m[2][2])]
                guard h.allSatisfy(\.isFinite), abs(h[8]) > 1e-6 else { return nil }
                return .homography(h.map { $0 / h[8] })
            }
        } catch {
            return nil
        }
    }
}
