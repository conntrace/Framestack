import FrameStackCore
import FrameStackMedia
import SwiftUI

/// Choose variants → pick a folder → watch each output finish (PRD §9.3).
struct BatchSheetView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Batch Export")
                .font(.title2.weight(.semibold))
            if let batch = model.batch {
                BatchProgressView(batch: batch)
            } else {
                BatchChoiceView()
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct BatchChoiceView: View {
    @EnvironmentObject private var model: AppModel

    private var variants: [BatchVariant] { model.batchVariants(for: model.batchChoice) }

    var body: some View {
        Text("Export several versions of the same range to one folder. Each file is named after the project, its variant and the frame count; a name that is already taken gets a number.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        Toggle(isOn: $model.batchChoice.includeCurrent) {
            Text("Current settings") + Text(" — \(currentLabel)").foregroundStyle(.secondary)
        }

        GroupBox("Other blend modes over the current settings") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(FrameStackCore.BlendMode.allCases) { mode in
                    Toggle(mode.displayName, isOn: binding(for: mode))
                        .disabled(mode == model.blendMode && model.batchChoice.includeCurrent)
                        .help(mode == model.blendMode && model.batchChoice.includeCurrent ? "Already covered by the current settings" : mode.explanation)
                }
            }
            .padding(.vertical, 2)
            HStack {
                Button("All") { model.batchChoice.blendModes = Set(FrameStackCore.BlendMode.allCases) }
                Button("None") { model.batchChoice.blendModes = [] }
            }
            .controlSize(.small)
        }

        GroupBox("Starters over the current settings") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(model.starterPresets) { starter in
                    Toggle(starter.name, isOn: binding(forStarter: starter.id))
                        .help(starter.summary)
                }
            }
            .padding(.vertical, 2)
        }

        GroupBox("Saved presets (each with its own export settings)") {
            if model.presets.isEmpty {
                Text("No presets saved. Save one from the Presets section of the inspector.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // A long list scrolls so the sheet stays on a small display.
                let list = VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.presets) { stored in
                        Toggle(stored.preset.name, isOn: binding(for: stored.url))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                if model.presets.count > 5 {
                    ScrollView { list }.frame(height: 112)
                } else {
                    list
                }
            }
        }

        GroupBox("Split the range") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Toggle("One file per part, for each version", isOn: $model.batchChoice.splitsRange)
                    Spacer()
                    Stepper(value: $model.batchChoice.segmentCount, in: 2...max(2, model.maximumBatchSegments)) {
                        Text("\(min(model.batchChoice.segmentCount, max(2, model.maximumBatchSegments))) parts").monospacedDigit()
                    }
                    .disabled(!model.batchChoice.splitsRange || model.maximumBatchSegments < 2)
                    .accessibilityLabel("Parts")
                }
                if model.batchChoice.splitsRange {
                    Toggle("Also export the whole range", isOn: $model.batchChoice.includesWholeRange)
                    Text(segmentCaption)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("batchSegments")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }

        Text(summary)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("batchSummary")

        HStack {
            Spacer()
            Button("Cancel") { model.isBatchSheetPresented = false }
                .keyboardShortcut(.cancelAction)
            Button("Choose Folder…") { model.presentBatchFolderPanel() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStartBatch)
        }
    }

    private var currentLabel: String {
        let opacityPart = model.blendMode.usesOpacity && model.opacity < 1 ? " \(Int((model.opacity * 100).rounded()))%" : ""
        return "\(model.blendMode.displayName)\(opacityPart), \(model.exportSettings.format.displayName)"
    }

    private var summary: String {
        let v = variants
        guard !v.isEmpty else { return "Nothing selected." }
        let count = model.timeline.flatMap { try? v[0].settings.selection(in: $0).selectedCount } ?? 0
        let renders = model.source.map { BatchExporter.renderPassCount(for: v, native: $0.displaySize) } ?? v.count
        let example = BatchNaming.fileName(base: model.batchBaseName, variant: v[0].name, frameCount: count, longEdge: nil, format: v[0].export.format)
        return "\(v.count) output\(v.count == 1 ? "" : "s"), \(renders) render pass\(renders == 1 ? "" : "es") — e.g. “\(example)”."
    }

    /// How the range divides: equal frame counts, each part sampled, weighted and masked on its own.
    private var segmentCaption: String {
        let segments = model.batchSegments(for: model.batchChoice)
        guard segments.count > 1 else { return "The range holds a single frame; there is nothing to split." }
        let seconds = segments.map(\.range.durationSeconds)
        let length = (seconds.max() ?? 0) - (seconds.min() ?? 0) < 0.0005
            ? "\(Format.seconds(seconds[0])) each"
            : "\(Format.seconds(seconds.min() ?? 0)) to \(Format.seconds(seconds.max() ?? 0))"
        return "\(RangeSegmenter.summary(of: segments)) (\(length)), in time order. Sampling, weighting and masks apply inside each part."
    }

    private func binding(for mode: FrameStackCore.BlendMode) -> Binding<Bool> {
        Binding(get: { model.batchChoice.blendModes.contains(mode) },
                set: { on in if on { model.batchChoice.blendModes.insert(mode) } else { model.batchChoice.blendModes.remove(mode) } })
    }

    private func binding(forStarter id: String) -> Binding<Bool> {
        Binding(get: { model.batchChoice.starterIDs.contains(id) },
                set: { on in if on { model.batchChoice.starterIDs.insert(id) } else { model.batchChoice.starterIDs.remove(id) } })
    }

    private func binding(for url: URL) -> Binding<Bool> {
        Binding(get: { model.batchChoice.presetURLs.contains(url) },
                set: { on in if on { model.batchChoice.presetURLs.insert(url) } else { model.batchChoice.presetURLs.remove(url) } })
    }
}

private struct BatchProgressView: View {
    @EnvironmentObject private var model: AppModel
    let batch: BatchState

    var body: some View {
        Text(batch.folder.path(percentEncoded: false))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        // A split batch can have hundreds of outputs: the list scrolls and the sheet stays on screen.
        let rows = VStack(alignment: .leading, spacing: 6) {
            ForEach(batch.outputs) { output in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(for: output.status))
                        .foregroundStyle(color(for: output.status))
                        .frame(width: 16)
                    Text(output.url.lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(statusText(output))
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(output.url.lastPathComponent): \(statusText(output))")
            }
        }
        if batch.outputs.count > 12 {
            ScrollView { rows.padding(.trailing, 12) }.frame(height: 300)
        } else {
            rows
        }
        ProgressView(value: Double(batch.outputs.filter(\.status.isFinal).count), total: Double(max(batch.outputs.count, 1)))
        if let summary = batch.summary {
            Text(summaryText(summary))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let note = batch.note {
            Label(note, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("batchNote")
        }
        HStack {
            Spacer()
            if batch.isRunning {
                Button("Cancel Batch") { model.cancelBatch() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Show in Finder") { model.revealBatchFolder() }
                Button("Done") {
                    model.dismissBatch()
                    model.isBatchSheetPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func icon(for status: BatchOutputStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .rendering, .writing: return "circle.dotted"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private func color(for status: BatchOutputStatus) -> Color {
        switch status {
        case .pending, .cancelled: return .secondary
        case .rendering, .writing: return .accentColor
        case .finished: return .green
        case .failed: return .red
        }
    }

    private func statusText(_ output: BatchOutput) -> String {
        switch output.status {
        case .pending: return "Waiting"
        case let .rendering(done, total):
            let shared = output.sharesRenderWith.isEmpty ? "" : " (shared render)"
            return "Rendering \(done) of \(total)\(shared)"
        case .writing: return "Writing…"
        case let .finished(report, missing):
            let base = "\(report.width)×\(report.height), \(report.bitDepth)-bit, \(report.colorProfileName ?? "untagged")"
            return missing > 0 ? "\(base); \(missing) frames missing" : base
        case let .failed(message): return "Failed: \(message)"
        case .cancelled: return "Cancelled"
        }
    }

    private func summaryText(_ summary: BatchSummary) -> String {
        var parts = ["\(summary.finishedCount) of \(summary.outputs.count) written in \(String(format: "%.1f", summary.elapsedSeconds)) s with \(summary.rendersPerformed) render pass\(summary.rendersPerformed == 1 ? "" : "es")"]
        if summary.failedCount > 0 { parts.append("\(summary.failedCount) failed") }
        if summary.cancelledCount > 0 { parts.append("\(summary.cancelledCount) cancelled") }
        return parts.joined(separator: ", ") + "."
    }
}
