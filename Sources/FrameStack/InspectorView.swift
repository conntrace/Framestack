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
                        InspectorSection(title: "Alignment", key: "alignment") { AlignmentSection() }
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
        }
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
                        Text("Safe area \(Int(report.validArea.width))×\(Int(report.validArea.height)) of \(model.preview?.size.description ?? "") preview px; outside it some frames are missing and the alpha channel records coverage.")
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
