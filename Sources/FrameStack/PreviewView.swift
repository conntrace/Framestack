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

    var body: some View {
        GeometryReader { geometry in
            let viewport = geometry.size
            let scale = zoom.scale(for: fullSize, in: viewport)
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
