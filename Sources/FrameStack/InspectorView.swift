import FrameStackCore
import FrameStackMedia
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let source = model.source {
                    SourceSection(source: source)
                    if model.timeline != nil {
                        TimeRangeSection(source: source)
                        SamplingSection()
                        BlendSection()
                        ExportSection()
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

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
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

// MARK: Source

private struct SourceSection: View {
    @EnvironmentObject private var model: AppModel
    let source: VideoSourceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Source")
            Text(source.fileName).font(.headline).lineLimit(2).help(source.url.path)
            InfoRow(label: "Pixels", value: pixelsDescription)
            InfoRow(label: "Duration", value: Format.duration(source.duration.seconds))
            InfoRow(label: "Frame rate", value: Format.fps(source.nominalFrameRate))
            InfoRow(label: "Frames", value: framesDescription)
            InfoRow(label: "Codec", value: source.codec)
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

// MARK: Time range

private struct TimeRangeSection: View {
    @EnvironmentObject private var model: AppModel
    let source: VideoSourceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Time Range")
            HStack {
                SecondsField(label: "Start", time: $model.rangeStart)
                SecondsField(label: "End", time: $model.rangeEnd)
            }
            HStack {
                Text("Start inclusive, end exclusive [start, end) · \(Format.seconds(max(0, model.range.durationSeconds)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Full Clip") { model.resetRange() }
                    .controlSize(.small)
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
            SectionHeader(title: "Sampling")
            Picker("Sampling", selection: $model.samplingKind) {
                ForEach(SamplingKind.allCases) { Text($0.rawValue).tag($0) }
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
            SectionHeader(title: "Blend")
            // Average is the only M1 mode; this becomes a picker when M2 adds
            // Lighten/Darken/Screen/Multiply/Additive/Difference/Normal.
            Text(model.blendMode.displayName).font(.headline)
            Text(model.blendMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Export

private struct ExportSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Export")
            Picker("Depth", selection: $model.exportBitDepth) {
                ForEach(ExportBitDepth.allCases) { Text("\($0.displayName) PNG").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Full resolution (\(model.source?.displaySize.description ?? "")), sRGB. 16-bit avoids banding in smooth averages.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.presentExportPanel()
            } label: {
                Label("Export PNG…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!model.canExport)

            switch model.exportActivity {
            case let .finished(report, missing):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Saved \(report.width)×\(report.height), \(report.bitDepth)-bit, \(report.colorProfileName ?? "untagged")",
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    if missing > 0 {
                        Label("\(missing) selected frames could not be decoded and were left out.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
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
}
