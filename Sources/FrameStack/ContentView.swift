import FrameStackCore
import FrameStackMedia
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.undoManager) private var undoManager

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
            ToolbarItemGroup(placement: .principal) {
                Picker("View", selection: $model.viewMode) {
                    ForEach(PreviewViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(model.timeline == nil)
                .help("Composite, the original frame under the playhead, or both")
            }
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
                .help("Export the composite as an image (⌘E)")
            }
        }
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(model.windowSubtitle)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
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
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { AppDelegate.previewViewport = geometry.size }
                    .onChange(of: geometry.size) { _, size in AppDelegate.previewViewport = size }
            }
        )
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
        case let .relink(request):
            RelinkView(request: request)
        case .ready:
            switch model.viewMode {
            case .composite:
                composite
            case .original:
                original
            case .sideBySide:
                HStack(spacing: 1) {
                    original
                    Divider()
                    composite
                }
            }
        }
    }

    private var fullSize: PixelSize { model.source?.displaySize ?? PixelSize(width: 1, height: 1) }

    @ViewBuilder
    private var composite: some View {
        if let preview = model.preview {
            ZoomableImageView(
                image: preview.image,
                fullSize: fullSize,
                zoom: model.zoom,
                onZoomChange: { model.zoom = $0 },
                caption: "Composite · \(preview.framesComposited) frames"
            )
            .opacity(model.isPreviewCurrent ? 1 : 0.55)
            .overlay(alignment: .topLeading) {
                if !model.isPreviewCurrent {
                    Label("Preview outdated", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(12)
                }
            }
        } else if case let .failed(message) = model.renderActivity {
            Text(message).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Rendering preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var original: some View {
        if let frame = model.sourceFrame {
            ZoomableImageView(
                image: frame.image,
                fullSize: fullSize,
                zoom: model.zoom,
                onZoomChange: { model.zoom = $0 },
                caption: "Original · frame \(frame.index) · \(Format.seconds(frame.time.seconds))"
            )
            .opacity(frame.index == model.scrubIndex ? 1 : 0.55)
        } else if let message = model.sourceFrameError {
            Text(message).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.scrubIndex == nil {
            Text("Click the timeline or press ⌥→ to choose a frame.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Decoding frame…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Shown when a project's media is missing or is not the saved file. The
/// user must locate the media, explicitly accept a changed file, or cancel.
private struct RelinkView: View {
    @EnvironmentObject private var model: AppModel
    let request: RelinkRequest

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: request.candidate == nil ? "questionmark.folder" : "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)
            Text(request.candidate == nil ? "Video not found" : "Video has changed").font(.title2)
            Text("Project “\(request.projectURL.deletingPathExtension().lastPathComponent)” was saved with “\(request.savedFileName)” (\(request.project.source.frameCount) frames, \(request.project.source.displaySize)).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(request.message)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack {
                Button("Cancel") { model.cancelRelink() }
                    .keyboardShortcut(.cancelAction)
                if request.candidate != nil {
                    Button("Use This File Anyway") { model.useRelinkCandidateAnyway() }
                }
                Button("Locate…") { model.presentRelinkPanel() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 480)
        .padding()
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
            if model.source != nil, model.timeline != nil {
                TimelineStrip()
            }
            HStack(spacing: 12) {
                selectionSummary
                if model.timeline != nil {
                    Divider().frame(height: 14)
                    PlayheadControls()
                }
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
            Text("Writing \(model.exportSettings.format.displayName)…")
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

