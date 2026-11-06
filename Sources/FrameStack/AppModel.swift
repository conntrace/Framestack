import AppKit
import CoreGraphics
import Foundation
import FrameStackCore
import FrameStackMedia
import UniformTypeIdentifiers

enum SamplingKind: String, CaseIterable, Identifiable {
    case all = "All"
    case everyNth = "Every Nth"
    case exactCount = "Exact Count"
    var id: String { rawValue }
}

enum PreviewQuality: String, CaseIterable, Identifiable {
    case draft = "1080 px"
    case high = "2160 px"
    case full = "Full"
    var id: String { rawValue }

    /// Long-edge cap for preview renders. Preview and export use the same
    /// algorithm; only the resampling differs.
    var maxLongEdge: Int? {
        switch self {
        case .draft: return 1080
        case .high: return 2160
        case .full: return nil
        }
    }
}

/// An immutable rendered preview, tagged with the settings revision it shows.
struct PreviewSnapshot {
    let image: CGImage
    let revision: Int
    let size: PixelSize
    let framesComposited: Int
    let missingFrames: Int
    /// Why frames are missing (decoder failure), if any.
    let decodeFailure: String?
    let elapsedSeconds: Double
}

enum SourceState {
    case empty
    case loading(fileName: String, step: String)
    case ready
    case failed(String)
}

enum RenderActivity: Equatable {
    case idle
    case waiting
    case rendering(done: Int, total: Int)
    case failed(String)
}

enum ExportActivity: Equatable {
    case idle
    case rendering(done: Int, total: Int)
    case writing
    case finished(ExportReport, missingFrames: Int, decodeFailure: String?)
    case cancelled
    case failed(String)
}

/// All UI state. Settings are plain values (non-destructive); every change
/// bumps `settingsRevision`, recomputes the frame selection synchronously
/// (cheap), and schedules a debounced, cancellable preview render.
@MainActor
final class AppModel: ObservableObject {
    // Source
    @Published private(set) var sourceState: SourceState = .empty
    @Published private(set) var source: VideoSourceInfo?
    @Published private(set) var timeline: FrameTimeline?
    @Published private(set) var scanResult: FrameScanResult?
    @Published private(set) var scanned: Int = 0

    // Settings
    @Published var rangeStart: FrameTime = .zero { didSet { settingsChanged() } }
    @Published var rangeEnd: FrameTime = .zero { didSet { settingsChanged() } }
    @Published var samplingKind: SamplingKind = .all { didSet { settingsChanged() } }
    @Published var nth: Int = 2 { didSet { settingsChanged() } }
    @Published var exactCount: Int = 20 { didSet { settingsChanged() } }
    @Published var blendMode: BlendMode = .average { didSet { settingsChanged() } }
    /// 0…1; only modes with `usesOpacity` re-render when it changes.
    @Published var opacity: Double = 1 {
        didSet { if blendMode.usesOpacity, opacity != oldValue { settingsChanged() } }
    }
    @Published var previewQuality: PreviewQuality = .draft { didSet { settingsChanged() } }
    @Published var exportBitDepth: ExportBitDepth = .sixteen

    // Derived / results
    @Published private(set) var selection: Result<SamplingResult, SamplingError>?
    @Published private(set) var settingsRevision = 0
    @Published private(set) var preview: PreviewSnapshot?
    @Published private(set) var renderActivity: RenderActivity = .idle
    @Published private(set) var exportActivity: ExportActivity = .idle

    private let renderer = CompositeRenderer()
    private var loadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var suppressChanges = false

    // MARK: Derived values

    var samplingMode: SamplingMode {
        switch samplingKind {
        case .all: return .all
        case .everyNth: return .everyNth(nth)
        case .exactCount: return .exactCount(exactCount)
        }
    }

    var range: FrameTimeRange { FrameTimeRange(start: rangeStart, end: rangeEnd) }

    var selectedTimes: [FrameTime] {
        guard let timeline, case let .success(result)? = selection else { return [] }
        return result.selectedTimes(in: timeline)
    }

    var isPreviewCurrent: Bool { preview?.revision == settingsRevision }

    var isExporting: Bool {
        switch exportActivity {
        case .rendering, .writing: return true
        default: return false
        }
    }

    var canExport: Bool {
        if case .success? = selection, source != nil, !isExporting { return true }
        return false
    }

    // MARK: Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a video to stack"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        loadTask?.cancel()
        previewTask?.cancel()
        exportTask?.cancel()
        source = nil
        timeline = nil
        scanResult = nil
        preview = nil
        selection = nil
        scanned = 0
        renderActivity = .idle
        exportActivity = .idle
        sourceState = .loading(fileName: url.lastPathComponent, step: "Reading metadata…")

        loadTask = Task { [weak self] in
            do {
                let info = try await VideoSourceLoader.load(url: url)
                guard let self, !Task.isCancelled else { return }
                self.source = info
                self.sourceState = .loading(fileName: info.fileName, step: "Scanning frame timestamps…")
                let scan = try await FrameScanner.scan(info) { [weak self] count in
                    self?.reportScanProgress(count)
                }
                guard !Task.isCancelled else { return }
                self.timeline = scan.timeline
                self.scanResult = scan
                self.scanned = scan.timeline.count
                self.suppressChanges = true
                self.rangeStart = .zero
                self.rangeEnd = info.duration
                self.suppressChanges = false
                self.sourceState = .ready
                self.settingsChanged(debounce: false)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.source = nil
                self.sourceState = .failed(error.localizedDescription)
            }
        }
    }

    /// Abandons an import that is still reading metadata or scanning (for
    /// example a file iCloud has not finished downloading).
    func cancelLoading() {
        guard case .loading = sourceState else { return }
        loadTask?.cancel()
        loadTask = nil
        source = nil
        scanned = 0
        sourceState = .empty
    }

    // MARK: Settings & preview

    func resetRange() {
        guard let source else { return }
        suppressChanges = true
        rangeStart = .zero
        suppressChanges = false
        rangeEnd = source.duration
    }

    private func settingsChanged(debounce: Bool = true) {
        guard !suppressChanges else { return }
        settingsRevision += 1
        if let timeline {
            do {
                selection = .success(try FrameSampler.select(from: timeline, range: range, mode: samplingMode))
            } catch let error as SamplingError {
                selection = .failure(error)
            } catch {
                selection = nil
            }
        }
        schedulePreview(debounce: debounce)
    }

    func renderPreviewNow() {
        schedulePreview(debounce: false)
    }

    private func schedulePreview(debounce: Bool) {
        previewTask?.cancel()
        guard let source, case .ready = sourceState else { return }
        guard case let .success(result)? = selection, let timeline else {
            renderActivity = .idle
            return
        }
        let request = CompositeRequest(
            source: source,
            frames: result.selectedTimes(in: timeline),
            blendMode: blendMode,
            opacity: Float(opacity),
            maxLongEdge: previewQuality.maxLongEdge
        )
        let revision = settingsRevision
        renderActivity = .waiting
        let renderer = renderer

        previewTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.renderActivity = .rendering(done: 0, total: request.frames.count)
            do {
                let result = try await renderer.render(request) { [weak self] progress in
                    self?.reportPreviewProgress(progress, revision: revision)
                }
                let image = try await Task.detached(priority: .userInitiated) {
                    try ImageExporter.makeCGImage(result.image, bitDepth: .eight)
                }.value
                guard let self, !Task.isCancelled, revision == self.settingsRevision else { return }
                self.preview = PreviewSnapshot(
                    image: image,
                    revision: revision,
                    size: result.image.size,
                    framesComposited: result.framesComposited,
                    missingFrames: result.missingFrames.count,
                    decodeFailure: result.decodeFailureSummary,
                    elapsedSeconds: result.elapsedSeconds
                )
                self.renderActivity = .idle
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.renderActivity = .failed(error.localizedDescription)
            }
        }
    }

    func cancelRendering() {
        if isExporting {
            exportTask?.cancel()
        } else {
            previewTask?.cancel()
            if case .rendering = renderActivity { renderActivity = .idle }
            if case .waiting = renderActivity { renderActivity = .idle }
        }
    }

    // MARK: Export

    var suggestedExportName: String {
        guard let source else { return "FrameStack.png" }
        let base = (source.fileName as NSString).deletingPathExtension
        let count = (try? selection?.get().selectedCount) ?? 0
        let mode = blendMode == .normal ? "Normal" : blendMode.displayName
        let opacityPart = blendMode.usesOpacity && opacity < 1 ? " \(Int((opacity * 100).rounded()))%" : ""
        return "\(base) \(mode)\(opacityPart) \(count)f.png"
    }

    func presentExportPanel() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedExportName
        panel.message = "Export the composite at full resolution (\(source?.displaySize.description ?? ""))"
        if panel.runModal() == .OK, let url = panel.url {
            export(to: url)
        }
    }

    func export(to url: URL) {
        guard let source, let timeline, case let .success(result)? = selection else { return }
        let request = CompositeRequest(
            source: source,
            frames: result.selectedTimes(in: timeline),
            blendMode: blendMode,
            opacity: Float(opacity),
            maxLongEdge: nil
        )
        let depth = exportBitDepth
        let renderer = renderer
        // Keep resource use bounded: one full-resolution render at a time.
        previewTask?.cancel()
        exportActivity = .rendering(done: 0, total: request.frames.count)

        exportTask = Task { [weak self] in
            do {
                let composite = try await renderer.render(request) { [weak self] progress in
                    self?.reportExportProgress(progress)
                }
                try Task.checkCancellation()
                self?.exportActivity = .writing
                let report = try await Task.detached(priority: .userInitiated) {
                    try ImageExporter.writePNG(composite.image, to: url, bitDepth: depth)
                }.value
                self?.exportActivity = .finished(
                    report, missingFrames: composite.missingFrames.count, decodeFailure: composite.decodeFailureSummary
                )
            } catch is CancellationError {
                self?.exportActivity = .cancelled
            } catch {
                self?.exportActivity = .failed(error.localizedDescription)
            }
            if let self, !self.isPreviewCurrent {
                self.schedulePreview(debounce: false)
            }
        }
    }

    // MARK: Progress hops (called from render threads)

    nonisolated private func reportScanProgress(_ count: Int) {
        Task { @MainActor [weak self] in self?.scanned = count }
    }

    nonisolated private func reportPreviewProgress(_ progress: CompositeProgress, revision: Int) {
        Task { @MainActor [weak self] in
            guard let self, self.settingsRevision == revision, !self.isPreviewCurrent else { return }
            if case .rendering = self.renderActivity {
                self.renderActivity = .rendering(done: progress.framesComposited, total: progress.framesTotal)
            }
        }
    }

    nonisolated private func reportExportProgress(_ progress: CompositeProgress) {
        Task { @MainActor [weak self] in
            guard let self, case .rendering = self.exportActivity else { return }
            self.exportActivity = .rendering(done: progress.framesComposited, total: progress.framesTotal)
        }
    }

    func revealExport() {
        if case let .finished(report, _, _) = exportActivity {
            NSWorkspace.shared.activateFileViewerSelecting([report.url])
        }
    }
}
