import AppKit
import FrameStackCore
import SwiftUI

enum PreviewViewMode: String, CaseIterable, Identifiable {
    case composite = "Composite"
    case original = "Original"
    case sideBySide = "Side by Side"
    var id: String { rawValue }
}

/// How the image is scaled in the preview area. Scales are relative to the
/// source's full display resolution, so "100 %" means one source pixel per
/// point whatever the preview quality (a 1080 px preview of a 1920 px
/// source is upsampled at 100 %; use Full quality for a true pixel view).
enum ZoomMode: Equatable {
    case fit
    case scale(Double)

    static let steps: [Double] = [0.1, 0.125, 0.25, 0.333, 0.5, 0.667, 1, 1.5, 2, 3, 4, 8]

    /// Scale that fits `size` inside `viewport` (never larger than needed
    /// to fill; may exceed 1 for small sources).
    static func fitScale(for size: PixelSize, in viewport: CGSize) -> Double {
        guard size.width > 0, size.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / CGFloat(size.width), viewport.height / CGFloat(size.height))
    }

    func scale(for size: PixelSize, in viewport: CGSize) -> Double {
        switch self {
        case .fit: return Self.fitScale(for: size, in: viewport)
        case let .scale(s): return s
        }
    }

    /// Next step above `current` (or the same if already at the top).
    static func stepIn(from current: Double) -> Double {
        steps.first { $0 > current * 1.001 } ?? steps.last!
    }

    static func stepOut(from current: Double) -> Double {
        steps.last { $0 < current * 0.999 } ?? steps.first!
    }

    static func clamped(_ s: Double) -> Double { min(max(s, steps.first!), steps.last!) }
}

/// A source frame shown in the Original / Side-by-side views.
struct SourceFrameSnapshot {
    let image: CGImage
    let index: Int
    let time: FrameTime
}

/// Scrollable, zoomable image with a checkerboard behind it (visible only
/// where the image is transparent). Pinch to zoom; scroll to pan.
struct ZoomableImageView: View {
    let image: CGImage
    /// Full-resolution size the zoom percentages refer to.
    let fullSize: PixelSize
    let zoom: ZoomMode
    let onZoomChange: (ZoomMode) -> Void
    let caption: String
    /// Rectangle in full-resolution pixels (origin top-left) outlined over
    /// the image — the alignment safe area.
    var safeArea: CGRect? = nil
    /// Painting: when set, drags on the image are reported as normalised
    /// (0…1 of the displayed image) points; `nil` disables painting.
    var paint: PaintHandlers? = nil
    /// Crop editing: when set, the crop rectangle is drawn over the image
    /// with handles and drags on the image edit it; `nil` hides it.
    var crop: CropHandlers? = nil

    @State private var pinchBase: Double?
    @State private var strokeInProgress: [CGPoint] = []

    struct PaintHandlers {
        /// Strokes already painted, in displayed-image-normalised coordinates, with radius as a fraction of the long edge.
        let strokes: [(points: [CGPoint], radius: Double, erase: Bool)]
        let brushRadius: Double
        let erasing: Bool
        let showOverlay: Bool
        let onStrokeEnd: ([CGPoint]) -> Void
    }

    static let cropFitMargin: CGFloat = 44

    struct CropHandlers {
        /// The crop in full-resolution canvas pixels (origin top-left).
        let rect: CGRect
        let canvas: PixelSize
        /// A handle (or the inside) dragged: the crop when the drag began, the handle, the movement in canvas pixels.
        let onDrag: (CGRect, CropHandle, CGSize) -> Void
        /// A new crop dragged out between two canvas points.
        let onDraw: (CGPoint, CGPoint) -> Void
        let onEnd: () -> Void
    }

    var body: some View {
        GeometryReader { geometry in
            let viewport = geometry.size
            // While the crop is edited "fit" leaves a margin, so the handles on the
            // canvas edge are clear of the window edge and of the Done bar.
            let margin: CGFloat = crop == nil ? 0 : Self.cropFitMargin
            let scale = zoom.scale(for: fullSize, in: CGSize(width: max(1, viewport.width - 2 * margin), height: max(1, viewport.height - 2 * margin)))
            let width = max(1, CGFloat(fullSize.width) * scale)
            let height = max(1, CGFloat(fullSize.height) * scale)

            ScrollView([.horizontal, .vertical]) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(scale >= 2 ? .none : .high)
                    .frame(width: width, height: height)
                    .background(Checkerboard())
                    .overlay {
                        if let paint, paint.showOverlay || !strokeInProgress.isEmpty {
                            PaintOverlay(strokes: paint.strokes, inProgress: strokeInProgress, inProgressRadius: paint.brushRadius,
                                         inProgressErase: paint.erasing, size: CGSize(width: width, height: height))
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if paint != nil {
                            Color.clear.contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            let p = CGPoint(x: value.location.x / width, y: value.location.y / height)
                                            strokeInProgress.append(CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)))
                                        }
                                        .onEnded { _ in
                                            paint?.onStrokeEnd(strokeInProgress)
                                            strokeInProgress = []
                                        }
                                )
                        }
                    }
                    .overlay {
                        if let crop {
                            CropOverlay(crop: crop, scale: scale)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let safeArea, !safeArea.isNull {
                            Rectangle()
                                .strokeBorder(Color.yellow.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                                .frame(width: max(1, safeArea.width * scale), height: max(1, safeArea.height * scale))
                                .offset(x: safeArea.minX * scale, y: safeArea.minY * scale)
                                .allowsHitTesting(false)
                                .accessibilityLabel("Safe area \(Int(safeArea.width))×\(Int(safeArea.height))")
                        }
                    }
                    .frame(minWidth: viewport.width, minHeight: viewport.height)
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchBase == nil { pinchBase = scale }
                        onZoomChange(.scale(ZoomMode.clamped((pinchBase ?? scale) * value.magnification)))
                    }
                    .onEnded { _ in pinchBase = nil }
            )
            .overlay(alignment: .bottomTrailing) {
                Text("\(caption) · \(Int((scale * 100).rounded())) %")
                    .font(.caption)
                    .monospacedDigit()
                    .padding(5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .padding(8)
                    .accessibilityIdentifier("zoomCaption")
            }
        }
    }
}

/// The crop rectangle over the whole canvas: everything outside it dimmed, a
/// thirds grid inside, and eight handles. Dragging a handle resizes, dragging
/// inside moves, dragging outside (or anywhere while the crop is the whole
/// canvas) draws a new crop. All positions are reported in canvas pixels.
struct CropOverlay: View {
    let crop: ZoomableImageView.CropHandlers
    /// View points per canvas pixel.
    let scale: Double

    @State private var drag: DragKind?

    private enum DragKind {
        case handle(CropHandle, start: CGRect)
        case draw(anchor: CGPoint)
    }

    /// How close (in points) the pointer must be to an edge or corner to grab it.
    static let grabDistance: CGFloat = 10

    /// What a press at `point` (view points) would grab: a handle, the
    /// inside, or nil for "draw a new crop". `rect` is the crop in view points.
    static func handle(at point: CGPoint, rect: CGRect, isWholeCanvas: Bool, tolerance: CGFloat = grabDistance) -> CropHandle? {
        // Small crops keep a grabbable middle: the tolerance shrinks to a third of the side.
        let tx = min(tolerance, max(2, rect.width / 3)), ty = min(tolerance, max(2, rect.height / 3))
        let nearLeft = abs(point.x - rect.minX) <= tx, nearRight = abs(point.x - rect.maxX) <= tx
        let nearTop = abs(point.y - rect.minY) <= ty, nearBottom = abs(point.y - rect.maxY) <= ty
        let inX = point.x >= rect.minX - tx && point.x <= rect.maxX + tx
        let inY = point.y >= rect.minY - ty && point.y <= rect.maxY + ty
        guard inX, inY else { return nil }
        if nearLeft, nearTop { return .topLeft }
        if nearRight, nearTop { return .topRight }
        if nearLeft, nearBottom { return .bottomLeft }
        if nearRight, nearBottom { return .bottomRight }
        if nearLeft { return .left }
        if nearRight { return .right }
        if nearTop { return .top }
        if nearBottom { return .bottom }
        // Moving a crop that already covers the canvas does nothing: draw a new one instead.
        return isWholeCanvas ? nil : .body
    }

    private var isWholeCanvas: Bool {
        crop.rect.minX <= 0 && crop.rect.minY <= 0
            && crop.rect.width >= CGFloat(crop.canvas.width) && crop.rect.height >= CGFloat(crop.canvas.height)
    }

    private var viewRect: CGRect {
        CGRect(x: crop.rect.minX * scale, y: crop.rect.minY * scale, width: crop.rect.width * scale, height: crop.rect.height * scale)
    }

    var body: some View {
        let rect = viewRect
        Canvas { context, size in
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addRect(rect)
            context.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
            // Thirds.
            var grid = Path()
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3, y = rect.minY + rect.height * CGFloat(i) / 3
                grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x, y: rect.maxY))
                grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            // Border: white on a dark hairline so it reads over any picture.
            context.stroke(Path(rect.insetBy(dx: -0.5, dy: -0.5)), with: .color(.black.opacity(0.6)), lineWidth: 2)
            context.stroke(Path(rect), with: .color(.white), lineWidth: 1)
            // Handles: corner brackets and edge bars, inside the rectangle so they stay on the image.
            let arm = min(16, rect.width / 3, rect.height / 3)
            var handles = Path()
            for (cx, sx) in [(rect.minX, CGFloat(1)), (rect.maxX, CGFloat(-1))] {
                for (cy, sy) in [(rect.minY, CGFloat(1)), (rect.maxY, CGFloat(-1))] {
                    handles.move(to: CGPoint(x: cx + sx * arm, y: cy + sy * 1.5))
                    handles.addLine(to: CGPoint(x: cx + sx * 1.5, y: cy + sy * 1.5))
                    handles.addLine(to: CGPoint(x: cx + sx * 1.5, y: cy + sy * arm))
                }
            }
            if rect.width > 60 {
                for y in [rect.minY + 1.5, rect.maxY - 1.5] {
                    handles.move(to: CGPoint(x: rect.midX - arm / 2, y: y)); handles.addLine(to: CGPoint(x: rect.midX + arm / 2, y: y))
                }
            }
            if rect.height > 60 {
                for x in [rect.minX + 1.5, rect.maxX - 1.5] {
                    handles.move(to: CGPoint(x: x, y: rect.midY - arm / 2)); handles.addLine(to: CGPoint(x: x, y: rect.midY + arm / 2))
                }
            }
            context.stroke(handles, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .square, lineJoin: .miter))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if drag == nil {
                        if let handle = Self.handle(at: value.startLocation, rect: rect, isWholeCanvas: isWholeCanvas) {
                            drag = .handle(handle, start: crop.rect)
                        } else {
                            drag = .draw(anchor: CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale))
                        }
                    }
                    switch drag {
                    case let .handle(handle, start)?:
                        crop.onDrag(start, handle, CGSize(width: value.translation.width / scale, height: value.translation.height / scale))
                    case let .draw(anchor)?:
                        crop.onDraw(anchor, CGPoint(x: value.location.x / scale, y: value.location.y / scale))
                    case nil:
                        break
                    }
                }
                .onEnded { _ in
                    drag = nil
                    crop.onEnd()
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case let .active(point):
                Self.cursor(for: Self.handle(at: point, rect: rect, isWholeCanvas: isWholeCanvas)).set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
        // An element the size of the crop itself, so assistive tools (and tests) can find where it is.
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Crop rectangle")
                .accessibilityValue("Left \(Int(crop.rect.minX)), top \(Int(crop.rect.minY)), \(Int(crop.rect.width)) by \(Int(crop.rect.height)) pixels")
                .accessibilityIdentifier("cropRectangle")
        }
    }

    static func cursor(for handle: CropHandle?) -> NSCursor {
        guard let handle else { return .crosshair }
        switch handle {
        case .body: return .openHand
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight:
            if #available(macOS 15.0, *) { return .frameResize(position: .topLeft, directions: .all) }
            return .crosshair
        case .topRight, .bottomLeft:
            if #available(macOS 15.0, *) { return .frameResize(position: .topRight, directions: .all) }
            return .crosshair
        }
    }
}

/// Painted strokes drawn over the image: existing strokes translucent, the
/// stroke being drawn brighter; erase strokes in a different hue.
struct PaintOverlay: View {
    let strokes: [(points: [CGPoint], radius: Double, erase: Bool)]
    let inProgress: [CGPoint]
    let inProgressRadius: Double
    let inProgressErase: Bool
    let size: CGSize

    var body: some View {
        Canvas { context, _ in
            let longEdge = max(size.width, size.height)
            func draw(_ pts: [CGPoint], radius: Double, erase: Bool, opacity: Double) {
                guard let first = pts.first else { return }
                var path = Path()
                let p0 = CGPoint(x: first.x * size.width, y: first.y * size.height)
                path.move(to: p0)
                if pts.count == 1 { path.addLine(to: p0) }
                for p in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height)) }
                let color: Color = erase ? .blue : .red
                context.stroke(path, with: .color(color.opacity(opacity)),
                               style: StrokeStyle(lineWidth: max(1, radius * longEdge * 2), lineCap: .round, lineJoin: .round))
            }
            for s in strokes { draw(s.points, radius: s.radius, erase: s.erase, opacity: 0.35) }
            draw(inProgress, radius: inProgressRadius, erase: inProgressErase, opacity: 0.6)
        }
        .accessibilityHidden(true)
    }
}

/// 8-point gray checkerboard, the conventional "transparent" backdrop.
struct Checkerboard: View {
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let cell: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.78)))
            var dark = Path()
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    dark.addRect(CGRect(x: x, y: y, width: cell, height: cell))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
            context.fill(dark, with: .color(Color(white: 0.62)))
        }
        .accessibilityHidden(true)
    }
}
