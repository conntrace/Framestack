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

/// Every user-editable, non-destructive compositing setting — one value
/// that undo/redo and (later) project files can snapshot.
struct CompositeSettings: Equatable {
    var rangeStart: FrameTime
    var rangeEnd: FrameTime
    var samplingKind: SamplingKind
    var nth: Int
    var exactCount: Int
    var blendMode: BlendMode
    var opacity: Double
}

/// All UI state. Settings are plain values (non-destructive); every change
/// bumps `settingsRevision`, recomputes the frame selection synchronously
/// (cheap), registers an undo step, and schedules a debounced, cancellable
/// preview render.
@MainActor
final class AppModel: ObservableObject {
    // Source
    @Published private(set) var sourceState: SourceState = .empty
    @Published private(set) var source: VideoSourceInfo?
    @Published private(set) var timeline: FrameTimeline?
    @Published private(set) var scanResult: FrameScanResult?
    @Published private(set) var scanned: Int = 0
    @Published private(set) var thumbnails: [TimelineThumbnail] = []

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
    /// Not part of `CompositeSettings`, so changing it re-renders (new
    /// revision) without an undo step.
    @Published var previewQuality: PreviewQuality = .draft { didSet { settingsChanged() } }
    @Published var exportBitDepth: ExportBitDepth = .sixteen

    // Playhead and viewing (not compositing settings; not undoable)
    /// Index into `timeline.frames` of the frame under the playhead.
    @Published var scrubIndex: Int? {
        didSet {
            if let timeline, let i = scrubIndex, !(0..<timeline.count).contains(i) {
                scrubIndex = min(max(i, 0), timeline.count - 1)
            }
            scheduleSourceFrame()
        }
    }
    @Published var viewMode: PreviewViewMode = .composite {
        didSet {
            if viewMode != .composite, scrubIndex == nil { scrubIndex = frameRange?.lowerBound ?? 0 }
            scheduleSourceFrame()
        }
    }
    @Published var zoom: ZoomMode = .fit
    /// The source frame under the playhead (Original / Side-by-side views).
    @Published private(set) var sourceFrame: SourceFrameSnapshot?
    @Published private(set) var sourceFrameError: String?

    // Derived / results
    @Published private(set) var selection: Result<SamplingResult, SamplingError>?
    @Published private(set) var settingsRevision = 0
    @Published private(set) var preview: PreviewSnapshot?
    @Published private(set) var renderActivity: RenderActivity = .idle
    @Published private(set) var exportActivity: ExportActivity = .idle

    /// The window's undo manager, handed in by the view. Settings changes
    /// register undo steps on it.
    weak var undoManager: UndoManager? {
        didSet { if undoManager !== oldValue { lastSettings = settings } }
    }

    private let renderer = CompositeRenderer()
    private var loadTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var sourceFrameTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var suppressChanges = false
    private var lastSettings: CompositeSettings?
    private var interactiveEditDepth = 0

    static let thumbnailCount = 32
    static let thumbnailHeight = 44

    // MARK: Derived values

    var samplingMode: SamplingMode {
        switch samplingKind {
        case .all: return .all
        case .everyNth: return .everyNth(nth)
        case .exactCount: return .exactCount(exactCount)
        }
    }

    var range: FrameTimeRange { FrameTimeRange(start: rangeStart, end: rangeEnd) }

    var settings: CompositeSettings {
        CompositeSettings(rangeStart: rangeStart, rangeEnd: rangeEnd, samplingKind: samplingKind,
                          nth: nth, exactCount: exactCount, blendMode: blendMode, opacity: opacity)
    }

    var selectedTimes: [FrameTime] {
        guard let timeline, case let .success(result)? = selection else { return [] }
        return result.selectedTimes(in: timeline)
    }

    /// Inclusive indices of the frames inside the current range (nil if none).
    var frameRange: ClosedRange<Int>? {
        timeline?.frameIndices(in: range)
    }

    var scrubTime: FrameTime? {
        guard let timeline, let i = scrubIndex, i < timeline.count else { return nil }
        return timeline.frames[i]
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
        thumbnailTask?.cancel()
        sourceFrameTask?.cancel()
        previewTask?.cancel()
        exportTask?.cancel()
        source = nil
        timeline = nil
        scanResult = nil
        thumbnails = []
        preview = nil
        sourceFrame = nil
        sourceFrameError = nil
        selection = nil
        scanned = 0
        scrubIndex = nil
        zoom = .fit
        renderActivity = .idle
        exportActivity = .idle
        undoManager?.removeAllActions(withTarget: self)
        lastSettings = nil
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
                self.lastSettings = self.settings
                self.settingsChanged(debounce: false)
                self.loadThumbnails(for: info, timeline: scan.timeline)
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

    private func loadThumbnails(for source: VideoSourceInfo, timeline: FrameTimeline) {
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            let images = (try? await SourceFrames.thumbnails(
                for: source, timeline: timeline, count: min(Self.thumbnailCount, timeline.count),
                maxHeight: Self.thumbnailHeight * 2
            )) ?? []
            guard let self, !Task.isCancelled, self.source == source else { return }
            self.thumbnails = images
        }
    }

    /// Decodes the exact frame under the playhead for the Original and
    /// Side-by-side views (debounced; stale results are dropped).
    private func scheduleSourceFrame() {
        sourceFrameTask?.cancel()
        guard viewMode != .composite, let source, let timeline, let index = scrubIndex, index < timeline.count else { return }
        if sourceFrame?.index == index, sourceFrame != nil { return }
        let time = timeline.frames[index]
        let maxLongEdge = previewQuality.maxLongEdge
        sourceFrameTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            do {
                let image = try await SourceFrames.frame(for: source, at: time, maxLongEdge: maxLongEdge)
                guard let self, !Task.isCancelled, self.scrubIndex == index, self.source == source else { return }
                self.sourceFrame = SourceFrameSnapshot(image: image, index: index, time: time)
                self.sourceFrameError = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.scrubIndex == index else { return }
                self.sourceFrameError = error.localizedDescription
            }
        }
    }

    // MARK: Zoom

    /// Current numeric scale given the viewport (the view passes its size).
    func zoomScale(in viewport: CGSize) -> Double {
        zoom.scale(for: source?.displaySize ?? PixelSize(width: 1, height: 1), in: viewport)
    }

    func zoomIn(viewport: CGSize) { zoom = .scale(ZoomMode.stepIn(from: zoomScale(in: viewport))) }
    func zoomOut(viewport: CGSize) { zoom = .scale(ZoomMode.stepOut(from: zoomScale(in: viewport))) }
    func zoomToFit() { zoom = .fit }
    func zoomActualSize() { zoom = .scale(1) }

    // MARK: Settings, undo, preview

    func resetRange() {
        guard let source else { return }
        withUndoGroup {
            rangeStart = .zero
            rangeEnd = source.duration
        }
    }

    /// Sets the range to frames `first…last` inclusive (clamped, ordered).
    func setFrameRange(first: Int, last: Int) {
        guard let timeline, let source, timeline.count > 0 else { return }
        let new = timeline.range(firstFrame: first, lastFrame: last, end: source.duration)
        withUndoGroup {
            rangeStart = new.start
            rangeEnd = new.end
        }
    }

    func setFirstFrame(_ index: Int) {
        guard let current = frameRange else { return setFrameRange(first: index, last: index) }
        setFrameRange(first: index, last: max(index, current.upperBound))
    }

    func setLastFrame(_ index: Int) {
        guard let current = frameRange else { return setFrameRange(first: index, last: index) }
        setFrameRange(first: min(index, current.lowerBound), last: index)
    }

    /// Moves the in point to the nearest frame boundary at `time`, keeping
    /// the range non-empty (drag handle).
    func setRangeStartSnapped(to time: FrameTime) {
        guard let timeline, let source, let i = timeline.nearestIndex(to: time) else { return }
        let start = timeline.frames[i]
        let end = start < rangeEnd ? rangeEnd : timeline.boundary(after: i, end: source.duration)
        withUndoGroup {
            rangeStart = start
            if end != rangeEnd { rangeEnd = end }
        }
    }

    /// Moves the out point to the nearest frame boundary at `time`, keeping
    /// the range non-empty (drag handle).
    func setRangeEndSnapped(to time: FrameTime) {
        guard let timeline, let source, timeline.count > 0 else { return }
        var end = timeline.nearestBoundary(to: time, end: source.duration)
        if !(rangeStart < end), let i = timeline.index(atOrBefore: rangeStart) {
            end = timeline.boundary(after: i, end: source.duration)
        }
        withUndoGroup {
            if !(rangeStart < end), let j = timeline.nearestIndex(to: end), j > 0 { rangeStart = timeline.frames[j - 1] }
            rangeEnd = end
        }
    }

    // Playhead

    func stepScrub(by delta: Int) {
        guard let timeline, timeline.count > 0 else { return }
        let base = scrubIndex ?? frameRange?.lowerBound ?? 0
        scrubIndex = min(max(base + delta, 0), timeline.count - 1)
    }

    func scrub(to time: FrameTime) {
        guard let timeline else { return }
        scrubIndex = timeline.nearestIndex(to: time)
    }

    func setInPointAtPlayhead() {
        guard let i = scrubIndex else { return }
        let last = frameRange.map { max($0.upperBound, i) } ?? i
        setFrameRange(first: i, last: last)
    }

    func setOutPointAtPlayhead() {
        guard let i = scrubIndex else { return }
        let first = frameRange.map { min($0.lowerBound, i) } ?? i
        setFrameRange(first: first, last: i)
    }

    /// Groups the settings changes made inside into one undo step; nests.
    func withUndoGroup(_ body: () -> Void) {
        beginInteractiveEdit()
        body()
        endInteractiveEdit()
    }

    /// Call around a drag or slider gesture so every intermediate value
    /// collapses into a single undo step.
    func beginInteractiveEdit() {
        if interactiveEditDepth == 0 { undoManager?.beginUndoGrouping() }
        interactiveEditDepth += 1
    }

    func endInteractiveEdit() {
        guard interactiveEditDepth > 0 else { return }
        interactiveEditDepth -= 1
        if interactiveEditDepth == 0 { undoManager?.endUndoGrouping() }
    }

    /// Restores a settings snapshot as one change (undo/redo).
    func apply(_ s: CompositeSettings) {
        suppressChanges = true
        rangeStart = s.rangeStart
        rangeEnd = s.rangeEnd
        samplingKind = s.samplingKind
        nth = s.nth
        exactCount = s.exactCount
        blendMode = s.blendMode
        opacity = s.opacity
        suppressChanges = false
        settingsChanged()
    }

    private func settingsChanged(debounce: Bool = true) {
        guard !suppressChanges else { return }
        let new = settings
        if let old = lastSettings, old != new, let undoManager {
            // A manager that does not group by event needs an explicit
            // group around every registration (the window's manager groups
            // by event; tests use an explicit one).
            let needsGroup = !undoManager.groupsByEvent && undoManager.groupingLevel == 0
            if needsGroup { undoManager.beginUndoGrouping() }
            undoManager.registerUndo(withTarget: self) { model in
                // Called on the main thread by the undo manager; apply
                // synchronously so the redo registration lands while
                // `isUndoing` is still true.
                MainActor.assumeIsolated { model.apply(old) }
            }
            if !undoManager.isUndoing, !undoManager.isRedoing {
                undoManager.setActionName(Self.actionName(from: old, to: new))
            }
            if needsGroup { undoManager.endUndoGrouping() }
        }
        lastSettings = new
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

    private static func actionName(from old: CompositeSettings, to new: CompositeSettings) -> String {
        if old.rangeStart != new.rangeStart || old.rangeEnd != new.rangeEnd { return "Change Time Range" }
        if old.samplingKind != new.samplingKind || old.nth != new.nth || old.exactCount != new.exactCount { return "Change Sampling" }
        if old.blendMode != new.blendMode { return "Change Blend Mode" }
        if old.opacity != new.opacity { return "Change Opacity" }
        return "Change Settings"
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
