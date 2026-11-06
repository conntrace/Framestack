import FrameStackCore
import FrameStackMedia
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let source = model.source {
                    if model.timeline != nil {
                        InspectorSection(title: "Project", key: "project") { ProjectSection() }
                    }
                    InspectorSection(title: "Source", key: "source") {
                        switch source {
                        case let .video(video): SourceSection(source: video)
                        case let .imageSequence(sequence): SequenceSourceSection(sequence: sequence)
                        }
                    }
                    if model.timeline != nil {
                        InspectorSection(title: "Time Range", key: "range") { TimeRangeSection(source: source) }
                        InspectorSection(title: "Sampling", key: "sampling") { SamplingSection() }
                        InspectorSection(title: "Blend", key: "blend") { BlendSection() }
                        InspectorSection(title: "Weighting", key: "weighting") { WeightingSection() }
                        InspectorSection(title: "Alignment", key: "alignment") { AlignmentSection() }
                        InspectorSection(title: "Motion Mask", key: "motionMask") { MotionMaskSection() }
                        InspectorSection(title: "Painted Mask", key: "paintedMask") { PaintedMaskSection() }
                        InspectorSection(title: "Crop & Straighten", key: "geometry") { GeometrySection() }
                        InspectorSection(title: "Export", key: "export") { ExportSection() }
                    }
                } else {
                    Text("Open or drop a video to begin.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A collapsible inspector section whose open/closed state is remembered
/// per section (progressive disclosure, PRD §8.2).
private struct InspectorSection<Content: View>: View {
    let title: String
    @AppStorage private var expanded: Bool
    private let content: Content

    init(title: String, key: String, @ViewBuilder content: () -> Content) {
        self.title = title
        _expanded = AppStorage(wrappedValue: true, "inspector.\(key).expanded")
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content
                .padding(.top, 6)
        } label: {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .disclosureGroupStyle(.automatic)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}

// MARK: Project

private struct ProjectSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = model.projectURL {
                Text(url.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(2).help(url.path)
                InfoRow(label: "Status", value: model.hasUnsavedChanges ? "Unsaved changes" : "Saved")
            } else {
                Text("Not saved as a project").font(.callout).foregroundStyle(.secondary)
                Text("A project stores the settings and a reference to the video, not a copy of it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Save") { model.saveProject() }
                    .disabled(!model.canSaveProject || (model.projectURL != nil && !model.hasUnsavedChanges))
                Button("Save As…") { model.saveProjectAs() }
                    .disabled(!model.canSaveProject)
            }
            .controlSize(.small)
            if let notice = model.sourceNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch model.projectActivity {
            case let .saved(url, date):
                Label("Saved \(url.lastPathComponent) at \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case let .failed(message):
                Label(message, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
        }
    }
}

// MARK: Source

private struct SourceSection: View {
    @EnvironmentObject private var model: AppModel
    let source: VideoSourceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(source.fileName).font(.headline).lineLimit(2).help(source.url.path)
            InfoRow(label: "Pixels", value: pixelsDescription)
            InfoRow(label: "Duration", value: Format.duration(source.duration.seconds))
            InfoRow(label: "Frame rate", value: Format.fps(source.nominalFrameRate))
            InfoRow(label: "Frames", value: framesDescription)
            InfoRow(label: "Codec", value: source.bitsPerComponent.map { "\(source.codec) · \($0)-bit" } ?? source.codec)
            InfoRow(label: "File size", value: Format.bytes(source.fileSizeBytes))
            Text(source.colorDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ForEach(source.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let scan = model.scanResult {
                if scan.samplesOutsideEdits > 0 {
                    Label("\(scan.samplesOutsideEdits) stored frames lie outside the clip's edit list (trimmed) and are not used.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let reason = scan.fallbackReason {
                    Label("Frames were counted by decoding: \(reason)", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let timeline = model.timeline, timeline.duplicateTimestampsDropped > 0 {
                Label("\(timeline.duplicateTimestampsDropped) samples shared a timestamp with another and were ignored.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pixelsDescription: String {
        if source.orientation == .up {
            return source.displaySize.description
        }
        return "\(source.displaySize.description)\n(\(source.orientation.displayName))"
    }

    private var framesDescription: String {
        if let timeline = model.timeline {
            let how = model.scanResult?.method == .decode ? "decoded" : "scanned"
            return "\(timeline.count) (\(how))"
        }
        if let estimate = source.estimatedFrameCount {
            return "≈ \(estimate) (estimate)"
        }
        return "unknown"
    }
}

// MARK: Image sequence source

private struct SequenceSourceSection: View {
    @EnvironmentObject private var model: AppModel
    let sequence: ImageSequenceInfo
    /// Draft of the rate field; committed on Return or when focus leaves
    /// (a `TextField(value:format:)` bound straight to the model dropped
    /// commits whenever the commit replaced the source).
    @State private var rateDraft: Double = ImageSequenceInfo.defaultFramesPerSecond
    @FocusState private var rateFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sequence.fileName).font(.headline).lineLimit(2).help(sequence.folderURL.path)
            InfoRow(label: "Images", value: "\(sequence.count) (\(sequence.formatSummary))")
            InfoRow(label: "Pixels", value: sequence.displaySize.description)
            InfoRow(label: "Depth", value: "\(sequence.bitsPerComponent)-bit" + (sequence.hasAlpha ? ", with alpha" : ""))
            InfoRow(label: "Total size", value: Format.bytes(sequence.totalFileSizeBytes))
            HStack {
                Text("Sequence rate").foregroundStyle(.secondary)
                Spacer()
                TextField("Rate", value: $rateDraft, format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 72).labelsHidden()
                    .focused($rateFocused)
                    .onSubmit(commitRate)
                    .onChange(of: rateFocused) { _, focused in if !focused { commitRate() } }
                    .onAppear { rateDraft = sequence.framesPerSecond }
                    .onChange(of: sequence.framesPerSecond) { _, new in rateDraft = new }
                Text("fps").foregroundStyle(.secondary)
            }
            .font(.callout)
            Toggle("Reverse order", isOn: reversedBinding)
                .font(.callout)
            HStack {
                Text("Canvas").foregroundStyle(.secondary)
                Spacer()
                Picker("Canvas", selection: policyBinding) {
                    ForEach(CanvasPolicy.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)
            }
            .font(.callout)
            .help("How stills that are not the first image's size are placed: refused, scaled to fit (transparent bars) or scaled to fill (overflow cropped).")
            Text("Stills have no recorded timestamps: times are **sequence time** (image index ÷ rate), \(Format.duration(sequence.duration.seconds)) for \(sequence.count) images.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(sequence.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commitRate() {
        guard rateDraft > 0, rateDraft.isFinite, rateDraft <= 10_000 else {
            rateDraft = sequence.framesPerSecond
            return
        }
        if abs(rateDraft - sequence.framesPerSecond) > 1e-9 { model.setSequence(framesPerSecond: rateDraft) }
    }

    private var reversedBinding: Binding<Bool> {
        Binding(get: { sequence.reversed }, set: { model.setSequence(reversed: $0) })
    }

    private var policyBinding: Binding<CanvasPolicy> {
        Binding(get: { sequence.canvasPolicy }, set: { model.setSequence(canvasPolicy: $0) })
    }
}

// MARK: Time range

private struct TimeRangeSection: View {
    @EnvironmentObject private var model: AppModel
    let source: MediaSource

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SecondsField(label: "Start", time: $model.rangeStart)
                SecondsField(label: "End", time: $model.rangeEnd)
            }
            HStack {
                FrameIndexField(label: "First frame", value: firstFrameBinding, maximum: maxIndex)
                FrameIndexField(label: "Last frame", value: lastFrameBinding, maximum: maxIndex)
            }
            HStack {
                Text("Start inclusive, end exclusive [start, end) · \(Format.seconds(max(0, model.range.durationSeconds)))\(source.isImageSequence ? " sequence time" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Full Clip") { model.resetRange() }
                    .controlSize(.small)
            }
        }
    }
}

private extension TimeRangeSection {
    var maxIndex: Int { max((model.timeline?.count ?? 1) - 1, 0) }

    /// 0-based index of the first selected frame; empty ranges show −1.
    var firstFrameBinding: Binding<Int> {
        Binding(
            get: { model.frameRange?.lowerBound ?? -1 },
            set: { model.setFirstFrame($0) }
        )
    }

    var lastFrameBinding: Binding<Int> {
        Binding(
            get: { model.frameRange?.upperBound ?? -1 },
            set: { model.setLastFrame($0) }
        )
    }
}

/// Frame-accurate range entry: 0-based frame index with a stepper. The
/// "last frame" is inclusive; the model converts it to the exclusive end.
private struct FrameIndexField: View {
    let label: String
    @Binding var value: Int
    let maximum: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                TextField(label, value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .labelsHidden()
                Stepper(label, value: $value, in: 0...max(maximum, 0))
                    .labelsHidden()
            }
        }
    }
}

/// Edits an exact `FrameTime` as decimal seconds (microsecond precision).
private struct SecondsField: View {
    let label: String
    @Binding var time: FrameTime

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: secondsBinding, format: .number.precision(.fractionLength(0...6)))
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .labelsHidden()
        }
    }

    private var secondsBinding: Binding<Double> {
        Binding(
            get: { time.seconds },
            set: { newValue in
                // The field shows at most 6 decimals, so re-committing the
                // displayed text of an exact time (e.g. 6242/600 shown as
                // 10.403333) must not count as a change; otherwise pressing
                // Return in an untouched field re-renders the same selection.
                guard abs(newValue - time.seconds) >= 1e-6 else { return }
                let candidate = FrameTime(seconds: max(0, newValue))
                if candidate != time { time = candidate }
            }
        )
    }
}

// MARK: Sampling

private struct SamplingSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Sampling", selection: $model.samplingKind) {
                ForEach(SamplingKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.samplingKind {
            case .all:
                Text("Every frame in the range.")
                    .font(.caption).foregroundStyle(.secondary)
            case .everyNth:
                IntegerStepper(label: "Take every", suffix: "frame(s), starting with the first", value: $model.nth)
            case .exactCount:
                IntegerStepper(label: "Frames", suffix: "evenly spaced, first and last included", value: $model.exactCount)
            }

            if case let .success(result)? = model.selection {
                ForEach(Array(result.notices.enumerated()), id: \.offset) { item in
                    Label(item.element.description, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct IntegerStepper: View {
    let label: String
    let suffix: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                TextField(label, value: clamped, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 80)
                    .labelsHidden()
                Stepper(label, value: clamped, in: 1...1_000_000)
                    .labelsHidden()
            }
            Text(suffix).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var clamped: Binding<Int> {
        Binding(get: { value }, set: { value = max(1, $0) })
    }
}

// MARK: Blend

private struct BlendSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Blend mode", selection: $model.blendMode) {
                ForEach(BlendMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            if model.blendMode.usesOpacity {
                HStack {
                    Text("Opacity").font(.callout)
                    Slider(value: $model.opacity, in: 0...1) { editing in
                        // One undo step per drag, not one per pixel.
                        editing ? model.beginInteractiveEdit() : model.endInteractiveEdit()
                    }
                    Text("\(Int((model.opacity * 100).rounded())) %")
                        .font(.callout)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Opacity")
            }
            Text(model.blendMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.blendMode.isOrderDependent {
                Label("Frames are combined oldest to newest.", systemImage: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.blendMode == .median {
                if let plan = model.medianPlan(for: model.source?.displaySize.fitting(maxLongEdge: model.previewQuality.maxLongEdge)),
                   let exportPlan = model.medianPlan(for: model.exportOutputSize) {
                    Label(medianEstimate(preview: plan, export: exportPlan), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(plan.passes > 8 || exportPlan.passes > 8 ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let report = model.preview?.median, model.isPreviewCurrent {
                    Text(report.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func medianEstimate(preview: MedianPlan, export: MedianPlan) -> String {
        let budget = ByteCountFormatter.string(fromByteCount: Int64(preview.memoryBudgetBytes), countStyle: .memory)
        return "Exact median needs the whole frame history: this preview decodes the clip \(preview.passes) time\(preview.passes == 1 ? "" : "s"), the export \(export.passes) time\(export.passes == 1 ? "" : "s") (bands within \(budget)). Fewer frames or a smaller output mean fewer passes."
    }
}

// MARK: Weighting

private struct WeightingSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Weighting", selection: presetBinding) {
                ForEach(WeightPreset.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            WeightCurveView(curve: model.weighting, samples: model.currentWeights, editable: model.weighting.preset == .custom) { points in
                model.weighting.points = points
            } onEditingChanged: { editing in
                editing ? model.beginInteractiveEdit() : model.endInteractiveEdit()
            }
            .frame(height: 96)
            Text(model.weighting.explanation)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.weighting.isFlat {
                if model.weighting.preset == .custom {
                    Button("Reset Curve") { model.weighting.points = WeightCurve.defaultCustomPoints }
                        .controlSize(.small)
                }
                if let w = model.currentWeights {
                    Text(summary(w))
                        .font(.caption).foregroundStyle(w.usedFlatFallback ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(modeNote)
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var presetBinding: Binding<WeightPreset> {
        Binding(get: { model.weighting.preset }, set: { model.weighting.preset = $0 })
    }

    private func summary(_ w: WeightedSelection) -> String {
        if w.usedFlatFallback { return "Every weight is zero — Flat is used instead." }
        return String(format: "Weights %.2f…%.2f over %d frames by timestamp · worth %.1f equal frames", w.rawRange.lowerBound,
                      w.rawRange.upperBound, w.raw.count, w.effectiveFrameCount)
    }

    private var modeNote: String {
        switch model.blendMode {
        case .average: return "Average: the weighted mean Σw·frame ÷ Σw (weights normalised, so brightness is unchanged)."
        case .additive: return "Additive: each frame is added × its raw weight (exposure accumulation, not normalised)."
        case .lighten, .darken: return "Lighten/Darken keep per-channel extremes and have no weights; the curve is ignored."
        default: return "\(model.blendMode.displayName): each frame's opacity is multiplied by its raw weight; the first frame still initialises the composite."
        }
    }
}

/// The weight function over the selection's normalised time, with one tick
/// per selected frame at its real timestamp (PRD §5.3 "preview visualizes
/// weighting distribution/selected samples"). In Custom mode the control
/// points can be dragged vertically.
private struct WeightCurveView: View {
    let curve: WeightCurve
    let samples: WeightedSelection?
    let editable: Bool
    let onPointsChange: ([WeightPoint]) -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var dragging: Int?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Canvas { context, size in
                    let inset: CGFloat = 4
                    let plot = CGRect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
                    func point(_ t: Double, _ w: Double) -> CGPoint {
                        CGPoint(x: plot.minX + plot.width * t, y: plot.maxY - plot.height * min(max(w, 0), 1))
                    }
                    context.fill(Path(roundedRect: plot.insetBy(dx: -inset, dy: -inset), cornerRadius: 6), with: .color(.black.opacity(0.18)))
                    // Sample ticks at the selected frames' timestamps.
                    if let samples {
                        let step = max(1, samples.times.count / 400)
                        var ticks = Path()
                        for i in stride(from: 0, to: samples.times.count, by: step) {
                            let p = point(samples.times[i], samples.raw[i])
                            ticks.move(to: CGPoint(x: p.x, y: plot.maxY))
                            ticks.addLine(to: p)
                        }
                        context.stroke(ticks, with: .color(.accentColor.opacity(0.35)), lineWidth: 1)
                    }
                    // The curve.
                    var path = Path()
                    let steps = 96
                    for i in 0...steps {
                        let t = Double(i) / Double(steps)
                        let p = point(t, curve.weight(at: t))
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    context.stroke(path, with: .color(.primary), lineWidth: 1.5)
                    if editable {
                        for cp in curve.points {
                            let p = point(cp.time, cp.weight)
                            context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.accentColor))
                        }
                    }
                }
                if editable {
                    Color.clear.contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let inset: CGFloat = 4
                                    let plotWidth = size.width - 2 * inset, plotHeight = size.height - 2 * inset
                                    var points = curve.points
                                    if dragging == nil {
                                        onEditingChanged(true)
                                        let t = Double((value.startLocation.x - inset) / plotWidth)
                                        dragging = points.indices.min { abs(points[$0].time - t) < abs(points[$1].time - t) }
                                    }
                                    guard let i = dragging, points.indices.contains(i) else { return }
                                    let w = 1 - Double((value.location.y - inset) / plotHeight)
                                    points[i].weight = min(max(w, 0), 1)
                                    onPointsChange(points)
                                }
                                .onEnded { _ in
                                    dragging = nil
                                    onEditingChanged(false)
                                }
                        )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weight curve")
        .accessibilityValue(curve.preset.displayName)
    }
}

// MARK: Alignment

private struct AlignmentSection: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("preview.showSafeArea") private var showSafeArea = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Align frames before blending", isOn: $model.alignment.enabled)
                .font(.callout)
            if model.alignment.enabled {
                Picker("Mode", selection: $model.alignment.mode) {
                    ForEach(AlignmentMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(model.alignment.mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Reference").foregroundStyle(.secondary)
                    Spacer()
                    Text(referenceDescription).monospacedDigit()
                }
                .font(.callout)
                HStack {
                    Button("Use Playhead Frame") { model.useReferenceAtPlayhead() }
                        .disabled(model.scrubIndex == nil)
                    Button("Use Middle Frame") { model.useMiddleReference() }
                        .disabled(model.alignment.reference == .middle)
                }
                .controlSize(.small)
                Toggle("Show safe area in the preview", isOn: $showSafeArea)
                    .font(.callout)
                if let report = model.preview?.alignment, model.isPreviewCurrent {
                    Label(report.summary, systemImage: report.failedFrames.isEmpty ? "scope" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(report.failedFrames.isEmpty ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if !report.validArea.isNull {
                        Text("Safe area \(Int(report.validArea.width))×\(Int(report.validArea.height)) of the \(model.preview?.canvasSize.description ?? "") preview canvas; outside it some frames are missing and the alpha channel records coverage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Vision registers every frame to the reference at up to 2048 px (about one pixel of precision at that size) before blending. Parallax, moving subjects and rolling shutter cannot be aligned; the frames that fail are used unmoved and counted here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Off: frames are stacked exactly as recorded. Turn on for handheld footage so a drifting camera does not blur the background (PRD §6.1).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var referenceDescription: String {
        switch model.alignment.reference {
        case .middle:
            if let time = model.alignmentReferenceTime, let index = model.timeline?.nearestIndex(to: time) {
                return "middle frame \(index) · \(Format.seconds(time.seconds))"
            }
            return "middle frame"
        case let .frame(time):
            let resolved = model.alignmentReferenceTime
            let index = resolved.flatMap { model.timeline?.nearestIndex(to: $0) }
            if resolved != time { return "frame at \(Format.seconds(time.seconds)) (not selected → middle)" }
            return "frame \(index.map(String.init) ?? "?") · \(Format.seconds(time.seconds))"
        }
    }
}

// MARK: Motion mask

private struct MotionMaskSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Keep only what moves", isOn: $model.motionMask.enabled)
                .font(.callout)
            if model.motionMask.enabled {
                HStack {
                    Text("Background").foregroundStyle(.secondary)
                    Spacer()
                    Text(backgroundDescription).monospacedDigit()
                }
                .font(.callout)
                HStack {
                    Button("Use Playhead Frame") { model.useMaskBackgroundAtPlayhead() }
                        .disabled(model.scrubIndex == nil)
                    Button("Use Median") { model.useMedianMaskBackground() }
                        .disabled(model.motionMask.background == .median)
                }
                .controlSize(.small)
                HStack {
                    Text("Threshold").font(.callout)
                    Slider(value: $model.motionMask.threshold, in: 0.01...0.5) { editing in
                        editing ? model.beginInteractiveEdit() : model.endInteractiveEdit()
                    }
                    Text(String(format: "%.2f", model.motionMask.threshold)).font(.callout).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("Feather").font(.callout)
                    Stepper(value: $model.motionMask.feather, in: 0...MotionMaskSettings.maximumRadius) {
                        Text("\(model.motionMask.feather) px").font(.callout).monospacedDigit()
                    }
                    Spacer()
                    Text("Clean up").font(.callout)
                    Stepper(value: $model.motionMask.cleanup, in: 0...MotionMaskSettings.maximumRadius) {
                        Text("\(model.motionMask.cleanup) px").font(.callout).monospacedDigit()
                    }
                }
                Toggle("Invert (keep only what stays still)", isOn: $model.motionMask.invert).font(.callout)
                Toggle("Show mask coverage instead of the composite", isOn: $model.showMaskCoverage).font(.callout)
                if let report = model.preview?.motionMask, model.isPreviewCurrent {
                    Text(report.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(recipe)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Each frame's linear-light RGB distance from the background is thresholded, cleaned (open/close), feathered and used as that frame's alpha before the blend; the composite is laid over the background. Moving shadows, lighting changes and camera motion count as motion — align first for handheld clips.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Off. Turn on to blend only the pixels that differ from a background — the median of the selection or a chosen frame — for chronophotography (use the Normal or Lighten blend) or ghosted motion (Average).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var backgroundDescription: String {
        switch model.motionMask.background {
        case .median: return "median of the selection"
        case let .frame(t):
            if model.motionMask.background.frameTime(in: model.selectedTimes) == nil { return "frame at \(Format.seconds(t.seconds)) (not selected → median)" }
            let index = model.timeline?.nearestIndex(to: t)
            return "frame \(index.map(String.init) ?? "?") · \(Format.seconds(t.seconds))"
        }
    }

    private var recipe: String {
        switch model.blendMode {
        case .normal: return "Normal + mask: each moving region is laid over the previous ones in time order — chronophotography."
        case .lighten, .maxLuminance: return "\(model.blendMode.displayName) + mask: the brightest moving pixels win over the background."
        case .average: return "Average + mask: a moving subject appears as a ghost proportional to how often it was there; background where it never was."
        case .median: return "Median + mask: a pixel must have moved in more than half the frames to show at all."
        default: return "\(model.blendMode.displayName) + mask: the masked frames feed the blend; uncovered pixels show the background."
        }
    }
}

// MARK: Painted mask

private struct PaintedMaskSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Blend only where painted", isOn: $model.paintedMask.enabled)
                .font(.callout)
            Toggle("Paint on the preview (drag)", isOn: $model.isPainting)
                .font(.callout)
                .disabled(!model.canPaint)
            if !model.canPaint, model.source != nil {
                Text("Set Straighten to 0° to paint; the mask lives on the unrotated canvas.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Picker("Brush", selection: $model.brushErases) {
                Text("Paint").tag(false)
                Text("Erase").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Text("Size").font(.callout)
                Slider(value: $model.brushRadius, in: 0.005...0.25)
                Text("\(Int((model.brushRadius * 100).rounded())) %").font(.callout).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            HStack {
                Text("Softness").font(.callout)
                Slider(value: $model.brushSoftness, in: 0...1)
                Text("\(Int((model.brushSoftness * 100).rounded())) %").font(.callout).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            Toggle("Invert (painted areas excluded)", isOn: $model.paintedMask.invert).font(.callout)
            Toggle("Show strokes on the preview", isOn: $model.showPaintedMaskOverlay).font(.callout)
            HStack {
                Text("\(model.paintedMask.strokes.count) stroke\(model.paintedMask.strokes.count == 1 ? "" : "s")")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clearStrokes() }
                    .controlSize(.small)
                    .disabled(model.paintedMask.strokes.isEmpty)
            }
            if model.paintedMask.enabled, !model.motionMask.enabled, let report = model.preview?.motionMask, model.isPreviewCurrent {
                Text(report.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.paintedMask.enabled
                 ? "Frames blend only inside the painted strokes (times the motion mask if that is on); elsewhere the background shows — the median of the selection or the playhead frame chosen in Motion Mask. Brush size is a fraction of the canvas, so strokes are resolution-independent and saved with the project. Each stroke is one undo step."
                 : "Off. Turn on and paint on the preview to limit the blend to the painted region; everything else shows the background.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Crop & straighten

private struct GeometrySection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Straighten").font(.callout)
                Slider(value: $model.geometry.rotationDegrees, in: -15...15, step: 0.1) { editing in
                    editing ? model.beginInteractiveEdit() : model.endInteractiveEdit()
                }
                Text(String(format: "%.1f°", model.geometry.rotationDegrees))
                    .font(.callout).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            Text("Rotates the finished composite about its centre (counter-clockwise is positive); the corners it uncovers are transparent until you crop.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Crop (canvas pixels)").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                CropField(label: "Left", value: cropBinding(\.origin.x))
                CropField(label: "Top", value: cropBinding(\.origin.y))
                CropField(label: "Width", value: cropBinding(\.size.width))
                CropField(label: "Height", value: cropBinding(\.size.height))
            }
            HStack {
                Button("Crop to Safe Area") { model.cropToSafeArea() }
                    .disabled(!model.canCropToSafeArea)
                    .help("The largest rectangle every aligned frame covers, after the straighten angle")
                Button("Reset") { model.resetGeometry() }
                    .disabled(model.geometry.isIdentity)
            }
            .controlSize(.small)
            Picker("Edges", selection: $model.geometry.edgeFill) {
                ForEach(EdgeFill.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(edgeExplanation)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let canvas = model.canvasSize {
                Text("Output \(model.geometry.outputSize(for: canvas)) of the \(canvas) canvas" + (model.geometry.hasTransform ? "" : " (uncropped)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var edgeExplanation: String {
        switch model.geometry.edgeFill {
        case .transparent: return "Uncovered pixels (moved frames, letterboxed stills, straighten corners) stay transparent: PNG/TIFF keep them, JPEG flattens onto black."
        case .black: return "Uncovered pixels are filled with black before export, in every format."
        case .white: return "Uncovered pixels are filled with white before export, in every format."
        }
    }

    private func cropBinding(_ keyPath: WritableKeyPath<CGRect, CGFloat>) -> Binding<Int> {
        Binding(
            get: { Int(model.cropPixels[keyPath: keyPath].rounded()) },
            set: { new in
                var rect = model.cropPixels
                rect[keyPath: keyPath] = CGFloat(new)
                model.setCropPixels(rect)
            }
        )
    }
}

private struct CropField: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, value: $value, format: .number)
                .textFieldStyle(.roundedBorder).monospacedDigit().labelsHidden()
        }
    }
}

// MARK: Export

private struct ExportSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Format", selection: $model.exportSettings.format) {
                ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Picker("Depth", selection: $model.exportSettings.bitDepth) {
                ForEach(ExportBitDepth.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.exportSettings.format.supportsSixteenBit)
            .help(model.exportSettings.format.supportsSixteenBit ? "16-bit avoids banding in smooth averages." : "JPEG is always 8-bit.")
            if model.exportSettings.format == .jpeg {
                HStack {
                    Text("Quality")
                    Slider(value: $model.exportSettings.jpegQuality, in: 0.5...1)
                    Text("\(Int((model.exportSettings.jpegQuality * 100).rounded())) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .font(.callout)
            }
            SizingControl()
            Picker("Color", selection: $model.exportSettings.colorSpace) {
                ForEach(OutputColorSpace.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Display P3 keeps saturated colors the sRGB gamut would clip; sRGB is the safe default for sharing.")
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.presentExportPanel()
            } label: {
                Label("Export \(model.exportSettings.format.displayName)…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!model.canExport)

            switch model.exportActivity {
            case let .finished(report, missing, decodeFailure):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Saved \(report.width)×\(report.height), \(report.bitDepth)-bit \(report.format?.displayName ?? "")\(report.hasAlpha ? " with alpha" : ""), \(report.colorProfileName ?? "untagged")",
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    if report.alphaFlattened {
                        Label("The composite has transparent pixels; JPEG cannot store them, so they were composited over black.",
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if missing > 0 {
                        Label("\(missing) selected frames could not be decoded and were left out" + (decodeFailure.map { " (\($0))" } ?? "") + ".",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Show in Finder") { model.revealExport() }
                        .controlSize(.small)
                }
                .font(.caption)
            case .cancelled:
                Text("Export cancelled.").font(.caption).foregroundStyle(.secondary)
            case let .failed(message):
                Label(message, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }

    private var summary: String {
        let s = model.exportSettings
        let size = model.exportOutputSize?.description ?? ""
        let native = model.source?.displaySize
        let sizeText = s.sizing == .native ? "Full resolution \(size)" : "\(size) (downscaled from \(native?.description ?? ""), Lanczos in linear light)"
        return "\(sizeText), \(s.effectiveBitDepth.displayName) \(s.format.displayName), \(s.colorSpace.displayName)."
    }
}

/// Native / long-edge / percent output size with a number field.
private struct SizingControl: View {
    @EnvironmentObject private var model: AppModel

    private enum Kind: String, CaseIterable, Identifiable {
        case native = "Native size"
        case longEdge = "Long edge"
        case percent = "Percent"
        var id: String { rawValue }
    }

    var body: some View {
        HStack {
            Picker("Size", selection: kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            switch model.exportSettings.sizing {
            case .native:
                EmptyView()
            case .longEdge:
                TextField("Pixels", value: longEdge, format: .number)
                    .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 72).labelsHidden()
                Text("px").font(.callout).foregroundStyle(.secondary)
            case .percent:
                TextField("Percent", value: percent, format: .number)
                    .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 56).labelsHidden()
                Text("%").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch model.exportSettings.sizing {
                case .native: return .native
                case .longEdge: return .longEdge
                case .percent: return .percent
                }
            },
            set: { new in
                let native = model.source?.displaySize.longEdge ?? 1920
                switch new {
                case .native: model.exportSettings.sizing = .native
                case .longEdge: model.exportSettings.sizing = .longEdge(min(native, 2048))
                case .percent: model.exportSettings.sizing = .percent(50)
                }
            }
        )
    }

    private var longEdge: Binding<Int> {
        Binding(
            get: { if case let .longEdge(v) = model.exportSettings.sizing { return v } else { return 0 } },
            set: { model.exportSettings.sizing = .longEdge(max(1, $0)) }
        )
    }

    private var percent: Binding<Int> {
        Binding(
            get: { if case let .percent(v) = model.exportSettings.sizing { return v } else { return 100 } },
            set: { model.exportSettings.sizing = .percent(min(max($0, 1), 100)) }
        )
    }
}
