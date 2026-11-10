import CoreGraphics
import Foundation

/// The part of the crop rectangle a drag on the preview moves.
public enum CropHandle: String, Sendable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    /// The inside of the rectangle: the whole crop moves, its size kept.
    case body

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    public var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
}

/// The shape the crop is held to while it is edited. This is a tool
/// setting, not part of the document: the crop rectangle itself is what is
/// saved, and it never stretches the image (PRD §6.2).
public enum CropAspect: Sendable, Hashable, Identifiable {
    /// Any shape.
    case free
    /// The canvas's own width : height.
    case original
    /// `width : height` in whole numbers, e.g. 16 : 9.
    case ratio(Int, Int)

    /// Landscape presets; `flipped` gives the portrait ones.
    public static let presets: [CropAspect] = [.ratio(1, 1), .ratio(5, 4), .ratio(4, 3), .ratio(3, 2), .ratio(16, 9), .ratio(2, 1)]

    public var id: String {
        switch self {
        case .free: return "free"
        case .original: return "original"
        case let .ratio(w, h): return "\(w):\(h)"
        }
    }

    public var displayName: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case let .ratio(w, h): return "\(w) : \(h)"
        }
    }

    public var isLocked: Bool { self != .free }

    /// Width ÷ height, or nil when the shape is free.
    public func value(canvas: PixelSize) -> Double? {
        switch self {
        case .free: return nil
        case .original:
            guard canvas.width > 0, canvas.height > 0 else { return nil }
            return Double(canvas.width) / Double(canvas.height)
        case let .ratio(w, h):
            guard w > 0, h > 0 else { return nil }
            return Double(w) / Double(h)
        }
    }

    /// The same shape turned on its side (16 : 9 ↔ 9 : 16). Free and square
    /// stay as they are; Original becomes the canvas's ratio turned.
    public func flipped(canvas: PixelSize) -> CropAspect {
        switch self {
        case .free: return .free
        case let .ratio(w, h): return .ratio(h, w)
        case .original:
            guard canvas.width > 0, canvas.height > 0, canvas.width != canvas.height else { return .original }
            let g = Self.gcd(canvas.width, canvas.height)
            return .ratio(canvas.height / g, canvas.width / g)
        }
    }

    public func canFlip(canvas: PixelSize) -> Bool { flipped(canvas: canvas) != self }

    /// The preset (either way up) a pixel size has to the nearest pixel, for
    /// the read-out next to the output size; nil when it is none of them.
    public static func name(for size: PixelSize) -> String? {
        guard size.width > 0, size.height > 0 else { return nil }
        let w = Double(size.width), h = Double(size.height)
        for preset in presets {
            guard case let .ratio(a, b) = preset else { continue }
            for (rw, rh) in a == b ? [(a, b)] : [(a, b), (b, a)] {
                let r = Double(rw) / Double(rh)
                if abs(w - h * r) <= 1 || abs(h - w / r) <= 1 { return "\(rw) : \(rh)" }
            }
        }
        return nil
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (abs(a), abs(b))
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }
}

/// Pure crop-rectangle arithmetic for the handles on the preview. Every
/// rectangle is in canvas pixels with the origin at the top left, and every
/// result is whole pixels inside the canvas, so what is dragged is exactly
/// what `GeometrySettings.crop` then stores and the exporter cuts.
public enum CropEditing {
    /// Smallest side a drag can make (the number fields can still go to 1 px).
    public static func minimumSide(for canvas: PixelSize) -> Double {
        Double(max(1, min(16, canvas.width, canvas.height)))
    }

    /// The crop after `handle` of `start` has been dragged by `delta`
    /// (canvas pixels, from where the drag began). With `aspect` (width ÷
    /// height) a corner keeps the opposite corner fixed and an edge keeps the
    /// opposite edge fixed and stays centred on the other axis.
    public static func drag(_ start: CGRect, handle: CropHandle, by delta: CGSize, canvas: PixelSize, aspect: Double? = nil) -> CGRect {
        let W = Double(canvas.width), H = Double(canvas.height)
        let rect = clamped(start, canvas: canvas)
        let minSide = minimumSide(for: canvas)
        if handle == .body {
            let x = min(max((rect.minX + delta.width).rounded(), 0), W - rect.width)
            let y = min(max((rect.minY + delta.height).rounded(), 0), H - rect.height)
            return CGRect(x: x, y: y, width: rect.width, height: rect.height)
        }
        guard let aspect, aspect > 0 else {
            var x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
            if handle.movesLeft { x0 = min(max((x0 + delta.width).rounded(), 0), x1 - min(minSide, rect.width)) }
            if handle.movesRight { x1 = max(min((x1 + delta.width).rounded(), W), x0 + min(minSide, rect.width)) }
            if handle.movesTop { y0 = min(max((y0 + delta.height).rounded(), 0), y1 - min(minSide, rect.height)) }
            if handle.movesBottom { y1 = max(min((y1 + delta.height).rounded(), H), y0 + min(minSide, rect.height)) }
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        // Smallest width that keeps both sides at least `minSide`.
        let minWidth = max(minSide, minSide * aspect)
        if handle.isCorner {
            // The opposite corner stays where it is.
            let anchorX = handle.movesLeft ? rect.maxX : rect.minX
            let anchorY = handle.movesTop ? rect.maxY : rect.minY
            let wantW = handle.movesLeft ? rect.width - delta.width : rect.width + delta.width
            let wantH = handle.movesTop ? rect.height - delta.height : rect.height + delta.height
            let availW = handle.movesLeft ? anchorX : W - anchorX
            let availH = handle.movesTop ? anchorY : H - anchorY
            // Follow the pointer on whichever axis it has gone furthest.
            let (w, h) = snappedSize(width: max(wantW, wantH * aspect, minWidth), aspect: aspect, maxWidth: availW, maxHeight: availH)
            return CGRect(x: handle.movesLeft ? anchorX - w : anchorX, y: handle.movesTop ? anchorY - h : anchorY, width: w, height: h)
        }
        if handle == .left || handle == .right {
            let anchorX = handle == .left ? rect.maxX : rect.minX
            let wantW = handle == .left ? rect.width - delta.width : rect.width + delta.width
            let availW = handle == .left ? anchorX : W - anchorX
            let centreY = rect.midY
            let availH = 2 * min(centreY, H - centreY)
            let (w, h) = snappedSize(width: max(wantW, minWidth), aspect: aspect, maxWidth: availW, maxHeight: availH)
            let y = min(max((centreY - h / 2).rounded(), 0), H - h)
            return CGRect(x: handle == .left ? anchorX - w : anchorX, y: y, width: w, height: h)
        }
        let anchorY = handle == .top ? rect.maxY : rect.minY
        let wantH = handle == .top ? rect.height - delta.height : rect.height + delta.height
        let availH = handle == .top ? anchorY : H - anchorY
        let centreX = rect.midX
        let availW = 2 * min(centreX, W - centreX)
        let (w, h) = snappedSize(width: max(wantH * aspect, minWidth), aspect: aspect, maxWidth: availW, maxHeight: availH)
        let x = min(max((centreX - w / 2).rounded(), 0), W - w)
        return CGRect(x: x, y: handle == .top ? anchorY - h : anchorY, width: w, height: h)
    }

    /// A new crop dragged out from `anchor` to `point` (both clamped to the
    /// canvas); nil while it is still smaller than the minimum side, so a
    /// stray click does not replace the crop.
    public static func drawn(from anchor: CGPoint, to point: CGPoint, canvas: PixelSize, aspect: Double? = nil) -> CGRect? {
        let W = Double(canvas.width), H = Double(canvas.height)
        let minSide = minimumSide(for: canvas)
        let a = CGPoint(x: min(max(anchor.x.rounded(), 0), W), y: min(max(anchor.y.rounded(), 0), H))
        let p = CGPoint(x: min(max(point.x.rounded(), 0), W), y: min(max(point.y.rounded(), 0), H))
        guard let aspect, aspect > 0 else {
            let rect = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
            return rect.width >= minSide && rect.height >= minSide ? rect : nil
        }
        let goesLeft = p.x < a.x, goesUp = p.y < a.y
        let wantW = max(abs(p.x - a.x), abs(p.y - a.y) * aspect)
        guard wantW >= max(minSide, minSide * aspect) else { return nil }
        let (w, h) = snappedSize(width: wantW, aspect: aspect, maxWidth: goesLeft ? a.x : W - a.x, maxHeight: goesUp ? a.y : H - a.y)
        guard w >= 1, h >= 1 else { return nil }
        return CGRect(x: goesLeft ? a.x - w : a.x, y: goesUp ? a.y - h : a.y, width: w, height: h)
    }

    /// `rect` reshaped to `aspect`: same centre and same area where the
    /// canvas allows (so switching between shapes does not keep shrinking the
    /// crop), smaller only when that does not fit, moved only to stay inside.
    public static func fit(_ rect: CGRect, toAspect aspect: Double, canvas: PixelSize) -> CGRect {
        let W = Double(canvas.width), H = Double(canvas.height)
        let r = clamped(rect, canvas: canvas)
        guard aspect > 0 else { return r }
        let (w, h) = snappedSize(width: (r.width * r.height * aspect).squareRoot(), aspect: aspect, maxWidth: W, maxHeight: H)
        return CGRect(x: min(max((r.midX - w / 2).rounded(), 0), W - w), y: min(max((r.midY - h / 2).rounded(), 0), H - h), width: w, height: h)
    }

    /// The largest rectangle of `aspect` inside `rect`, centred in it (the
    /// safe area held to a locked shape).
    public static func inscribed(aspect: Double, in rect: CGRect, canvas: PixelSize) -> CGRect {
        let r = clamped(rect, canvas: canvas)
        guard aspect > 0 else { return r }
        let (w, h) = snappedSize(width: r.width, aspect: aspect, maxWidth: r.width, maxHeight: r.height)
        return CGRect(x: r.minX + ((r.width - w) / 2).rounded(.down), y: r.minY + ((r.height - h) / 2).rounded(.down), width: w, height: h)
    }

    /// Whole pixels inside the canvas, never empty.
    public static func clamped(_ rect: CGRect, canvas: PixelSize) -> CGRect {
        let W = Double(max(canvas.width, 1)), H = Double(max(canvas.height, 1))
        let w = min(max(rect.width.rounded(), 1), W), h = min(max(rect.height.rounded(), 1), H)
        return CGRect(x: min(max(rect.minX.rounded(), 0), W - w), y: min(max(rect.minY.rounded(), 0), H - h), width: w, height: h)
    }

    /// Whole-pixel width and height of `aspect` as close to `width` as the
    /// limits allow. The longer side is the one rounded and the other follows
    /// from it, so the result is the ratio to the nearest pixel and never
    /// leaves the limits.
    static func snappedSize(width: Double, aspect: Double, maxWidth: Double, maxHeight: Double) -> (Double, Double) {
        let limitW = max(1, maxWidth.rounded(.down)), limitH = max(1, maxHeight.rounded(.down))
        let w = min(max(width, 1), limitW, limitH * aspect)
        if aspect >= 1 {
            var wi = max(1, w.rounded()), hi = max(1, (wi / aspect).rounded())
            while (wi > limitW || hi > limitH) && wi > 1 { wi -= 1; hi = max(1, (wi / aspect).rounded()) }
            return (wi, min(hi, limitH))
        }
        var hi = max(1, (w / aspect).rounded()), wi = max(1, (hi * aspect).rounded())
        while (wi > limitW || hi > limitH) && hi > 1 { hi -= 1; wi = max(1, (hi * aspect).rounded()) }
        return (min(wi, limitW), hi)
    }
}
