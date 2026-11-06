import FrameStackCore
import FrameStackMedia
import SwiftUI

/// Filmstrip + range track: thumbnails across the clip, the selected
/// `[start, end)` range with draggable in/out handles, a tick for every
/// selected frame, and the playhead.
///
/// Interaction: drag a handle to move the in/out point (snapped to frame
/// boundaries; one undo step per drag); click or drag elsewhere to move the
/// playhead to the nearest frame. With keyboard focus: ← → step one frame
/// (⇧ ten), I / O set the in/out point at the playhead.
struct TimelineStrip: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool
    @State private var drag: DragTarget?

    static let height: CGFloat = 72
    private let handleWidth: CGFloat = 8
    private let hitSlop: CGFloat = 7

    private enum DragTarget { case start, end, playhead }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let duration = model.source?.duration.seconds ?? 0

            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: false) { context, size in
                    draw(context: context, size: size, duration: duration)
                }
                .accessibilityHidden(true)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        if drag == nil {
                            drag = target(at: value.startLocation.x, width: width, duration: duration)
                            if drag != .playhead { model.beginInteractiveEdit() }
                            focused = true
                        }
                        let t = time(atX: value.location.x, width: width, duration: duration)
                        switch drag {
                        case .start?: model.setRangeStartSnapped(to: t)
                        case .end?: model.setRangeEndSnapped(to: t)
                        case .playhead?: model.scrub(to: t)
                        case nil: break
                        }
                    }
                    .onEnded { _ in
                        if drag != .playhead { model.endInteractiveEdit() }
                        drag = nil
                    }
            )
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress { press in handleKey(press) }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor.opacity(focused ? 0.6 : 0), lineWidth: 1)
            )
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        let count = model.selectedTimes.count
        let start = Format.seconds(model.rangeStart.seconds)
        let end = Format.seconds(model.rangeEnd.seconds)
        let playhead = model.scrubIndex.map { "playhead at frame \($0)" } ?? "no playhead"
        return "Timeline: \(count) frames selected between \(start) and \(end); \(playhead)"
    }

    // MARK: Geometry

    private func x(_ seconds: Double, width: CGFloat, duration: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / duration, 0), 1)) * width
    }

    private func time(atX px: CGFloat, width: CGFloat, duration: Double) -> FrameTime {
        let fraction = Double(min(max(px / max(width, 1), 0), 1))
        return FrameTime(seconds: fraction * duration)
    }

    private func target(at px: CGFloat, width: CGFloat, duration: Double) -> DragTarget {
        let startX = x(model.rangeStart.seconds, width: width, duration: duration)
        let endX = x(model.rangeEnd.seconds, width: width, duration: duration)
        let dStart = abs(px - startX)
        let dEnd = abs(px - endX)
        if dStart <= hitSlop || dEnd <= hitSlop {
            return dStart <= dEnd ? .start : .end
        }
        return .playhead
    }

    // MARK: Keys

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let step = press.modifiers.contains(.shift) ? 10 : 1
        switch press.key {
        case .leftArrow: model.stepScrub(by: -step); return .handled
        case .rightArrow: model.stepScrub(by: step); return .handled
        case .home: model.scrubIndex = 0; return .handled
        case .end: model.scrubIndex = (model.timeline?.count ?? 1) - 1; return .handled
        default: break
        }
        switch press.characters.lowercased() {
        case "i": model.setInPointAtPlayhead(); return .handled
        case "o": model.setOutPointAtPlayhead(); return .handled
        default: return .ignored
        }
    }

    // MARK: Drawing

    private func draw(context: GraphicsContext, size: CGSize, duration: Double) {
        let width = size.width
        let filmHeight = CGFloat(AppModel.thumbnailHeight)
        let trackRect = CGRect(x: 0, y: filmHeight + 4, width: width, height: size.height - filmHeight - 4)

        // Filmstrip
        let filmRect = CGRect(x: 0, y: 0, width: width, height: filmHeight)
        context.fill(Path(roundedRect: filmRect, cornerRadius: 4), with: .color(.black.opacity(0.35)))
        let thumbnails = model.thumbnails
        if !thumbnails.isEmpty {
            let cell = width / CGFloat(thumbnails.count)
            for (i, thumb) in thumbnails.enumerated() {
                let aspect = CGFloat(thumb.image.width) / CGFloat(max(thumb.image.height, 1))
                let h = filmHeight
                let w = min(cell, h * aspect)
                let rect = CGRect(x: CGFloat(i) * cell + (cell - w) / 2, y: 0, width: w, height: h)
                context.draw(Image(decorative: thumb.image, scale: 1), in: rect)
            }
        }
        guard duration > 0 else { return }

        // Dim outside the range on the filmstrip
        let startX = x(model.rangeStart.seconds, width: width, duration: duration)
        let endX = x(model.rangeEnd.seconds, width: width, duration: duration)
        context.fill(Path(CGRect(x: 0, y: 0, width: startX, height: filmHeight)), with: .color(.black.opacity(0.55)))
        context.fill(Path(CGRect(x: endX, y: 0, width: width - endX, height: filmHeight)), with: .color(.black.opacity(0.55)))

        // Track + range
        context.fill(Path(roundedRect: trackRect, cornerRadius: 4), with: .color(.secondary.opacity(0.15)))
        let rangeRect = CGRect(x: startX, y: trackRect.minY, width: max(1, endX - startX), height: trackRect.height)
        context.fill(Path(roundedRect: rangeRect, cornerRadius: 4), with: .color(.accentColor.opacity(0.25)))

        // Sample ticks
        let selected = model.selectedTimes
        var ticks = Path()
        for t in selected {
            let px = x(t.seconds, width: width, duration: duration)
            ticks.move(to: CGPoint(x: px, y: trackRect.minY + 4))
            ticks.addLine(to: CGPoint(x: px, y: trackRect.maxY - 4))
        }
        context.stroke(ticks, with: .color(.accentColor), lineWidth: selected.count > Int(width / 2) ? 0.5 : 1)

        // In/out handles spanning filmstrip + track
        for hx in [startX, endX] {
            let rect = CGRect(x: hx - handleWidth / 2, y: 0, width: handleWidth, height: size.height)
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.accentColor))
            let grip = Path { p in
                p.move(to: CGPoint(x: hx, y: size.height / 2 - 6))
                p.addLine(to: CGPoint(x: hx, y: size.height / 2 + 6))
            }
            context.stroke(grip, with: .color(.white.opacity(0.8)), lineWidth: 1.5)
        }

        // Playhead
        if let t = model.scrubTime {
            let px = x(t.seconds, width: width, duration: duration)
            var line = Path()
            line.move(to: CGPoint(x: px, y: 0))
            line.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(line, with: .color(.white), lineWidth: 1.5)
            context.stroke(line, with: .color(.black.opacity(0.5)), lineWidth: 3.5)
            context.stroke(line, with: .color(.white), lineWidth: 1.5)
            var head = Path()
            head.move(to: CGPoint(x: px - 6, y: 0))
            head.addLine(to: CGPoint(x: px + 6, y: 0))
            head.addLine(to: CGPoint(x: px, y: 7))
            head.closeSubpath()
            context.fill(head, with: .color(.white))
        }
    }
}

/// Playhead readout and frame stepping for the bottom bar.
struct PlayheadControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Button { model.stepScrub(by: -1) } label: { Image(systemName: "chevron.left") }
                .help("Previous frame (⌥←)")
            TextField("Frame", value: frameBinding, format: .number, prompt: Text("–"))
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 64)
                .labelsHidden()
                .help("Frame under the playhead (0-based)")
            Button { model.stepScrub(by: 1) } label: { Image(systemName: "chevron.right") }
                .help("Next frame (⌥→)")
            Text(readout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .controlSize(.small)
        .disabled(model.timeline == nil)
    }

    private var frameBinding: Binding<Int?> {
        Binding(
            get: { model.scrubIndex },
            set: { model.scrubIndex = $0.map { max($0, 0) } }
        )
    }

    private var readout: String {
        guard let timeline = model.timeline else { return "" }
        guard let t = model.scrubTime else { return "of \(timeline.count)" }
        return "of \(timeline.count) · \(Format.seconds(t.seconds))"
    }
}
