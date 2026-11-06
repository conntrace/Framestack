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

    @State private var pinchBase: Double?

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
