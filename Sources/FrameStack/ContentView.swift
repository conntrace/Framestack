import FrameStackCore
import FrameStackMedia
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PreviewArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                InspectorView()
                    .frame(width: 320)
            }
            Divider()
            BottomBar()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open a video (⌘O)")
                Picker("Preview", selection: $model.previewQuality) {
                    ForEach(PreviewQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Preview resolution. Export is always full resolution.")
                Button {
                    model.presentExportPanel()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.canExport)
                .help("Export the composite as a full-resolution PNG (⌘E)")
            }
        }
        .navigationTitle(model.source?.fileName ?? "FrameStack")
    }
}

// MARK: - Preview

private struct PreviewArea: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.sourceState {
        case .empty:
            DropHint()
        case let .loading(fileName, step):
            VStack(spacing: 10) {
                ProgressView()
                Text(fileName).font(.headline)
                Text(step).foregroundStyle(.secondary)
                if model.scanned > 0 {
                    Text("\(model.scanned) frames found").monospacedDigit().foregroundStyle(.secondary)
                }
                Button("Cancel") { model.cancelLoading() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        case let .failed(message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Open Another Video…") { model.presentOpenPanel() }
            }
            .padding()
        case .ready:
            if let preview = model.preview {
                Image(decorative: preview.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
                    .opacity(model.isPreviewCurrent ? 1 : 0.55)
                    .overlay(alignment: .topLeading) {
                        if !model.isPreviewCurrent {
                            Label("Preview outdated", systemImage: "clock.arrow.circlepath")
                                .font(.caption)
                                .padding(6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                .padding(24)
                        }
                    }
            } else if case let .failed(message) = model.renderActivity {
                Text(message).foregroundStyle(.secondary).padding()
            } else {
                ProgressView("Rendering preview…")
            }
        }
    }
}

private struct DropHint: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a video here").font(.title2)
            Text("MOV or MP4 — anything this Mac can decode").foregroundStyle(.secondary)
            Button("Open Video…") { model.presentOpenPanel() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            if let source = model.source, model.timeline != nil {
                TimelineStrip(
                    duration: source.duration.seconds,
                    rangeStart: model.rangeStart.seconds,
                    rangeEnd: model.rangeEnd.seconds,
                    selected: model.selectedTimes.map(\.seconds)
                )
                .frame(height: 28)
            }
            HStack(spacing: 12) {
                selectionSummary
                Spacer()
                activity
            }
            .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var selectionSummary: some View {
        switch model.selection {
        case let .success(result)?:
            Text("\(result.eligibleCount) frames in range → \(result.selectedCount) selected")
                .monospacedDigit()
        case let .failure(error)?:
            Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        case nil:
            Text(model.source == nil ? "No source" : "–").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var activity: some View {
        switch model.exportActivity {
        case let .rendering(done, total):
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(width: 160)
            Text("Exporting \(done)/\(total)").monospacedDigit()
            Button("Cancel") { model.cancelRendering() }
        case .writing:
            ProgressView().controlSize(.small)
            Text("Writing PNG…")
        default:
            previewActivity
        }
    }

    @ViewBuilder
    private var previewActivity: some View {
        switch model.renderActivity {
        case .idle:
            if let preview = model.preview, model.isPreviewCurrent {
                Text("Preview \(preview.size.description) · \(preview.framesComposited) frames · \(String(format: "%.2f s", preview.elapsedSeconds))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if preview.missingFrames > 0 {
                    Label("\(preview.missingFrames) selected frames could not be decoded" + (preview.decodeFailure.map { ": \($0)" } ?? ""),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help("The composite uses the \(preview.framesComposited) frames that did decode; no frame was substituted.")
                }
            }
        case .waiting:
            Text("Preview pending…").foregroundStyle(.secondary)
        case let .rendering(done, total):
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(width: 160)
            Text("Rendering \(done)/\(total)").monospacedDigit()
            Button("Cancel") { model.cancelRendering() }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
            Button("Retry") { model.renderPreviewNow() }
        }
    }
}

/// Source duration with the selected range highlighted and a tick for every
/// selected frame (at its real timestamp).
struct TimelineStrip: View {
    let duration: Double
    let rangeStart: Double
    let rangeEnd: Double
    let selected: [Double]

    var body: some View {
        Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
            context.fill(track, with: .color(.secondary.opacity(0.15)))
            guard duration > 0 else { return }
            func x(_ t: Double) -> CGFloat { CGFloat(min(max(t / duration, 0), 1)) * size.width }

            let rangeRect = CGRect(x: x(rangeStart), y: 0, width: max(1, x(rangeEnd) - x(rangeStart)), height: size.height)
            context.fill(Path(roundedRect: rangeRect, cornerRadius: 4), with: .color(.accentColor.opacity(0.25)))

            var ticks = Path()
            for t in selected {
                let px = x(t)
                ticks.move(to: CGPoint(x: px, y: 4))
                ticks.addLine(to: CGPoint(x: px, y: size.height - 4))
            }
            context.stroke(ticks, with: .color(.accentColor), lineWidth: selected.count > Int(size.width / 2) ? 0.5 : 1)
        }
        .accessibilityLabel("Timeline: \(selected.count) frames selected between \(Format.seconds(rangeStart)) and \(Format.seconds(rangeEnd))")
    }
}
