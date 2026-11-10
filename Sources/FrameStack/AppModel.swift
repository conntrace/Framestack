import AppKit
import CoreGraphics
import Foundation
import FrameStackCore
import FrameStackMedia
import UniformTypeIdentifiers

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
    /// What alignment did, when it was on.
    let alignment: AlignmentReport?
    /// What temporal weighting did, when it was not flat.
    let weighting: WeightingReport?
    /// How the Median was computed, for that mode.
    let median: MedianReport?
    /// What the motion mask did, and where motion contributed (grayscale), when it was on.
    let motionMask: MotionMaskReport?
    let coverageImage: CGImage?
    /// Size of the rendered canvas before straighten/crop (`size` is after).
    let canvasSize: PixelSize
    /// The frames were stacked newest first (an order-dependent mode with Reverse on).
    let stackedInReverse: Bool
    /// How a video was decoded back to front, when it was.
    let reverseDecode: ReverseDecodeReport?
}

enum SourceState {
    case empty
    case loading(fileName: String, step: String)
    case ready
    case failed(String)
    /// A project's media must be located or confirmed before it is used.
    case relink(RelinkRequest)
}

/// A project whose media could not be found, or was found changed. Nothing
/// is loaded until the user locates the file or explicitly accepts the
/// candidate (PRD §9.1: never silently use different media).
struct RelinkRequest {
    let project: ProjectFile
    let projectURL: URL
    /// A file at a remembered location whose fingerprint does not match.
    let candidate: URL?
    let differences: [String]

    var savedFileName: String { project.source.identity.fileName }
    var isSequence: Bool { project.source.kind == .imageSequence }
    var mediaWord: String { isSequence ? "image folder" : "video" }

    var message: String {
        if let candidate {
            let what = differences.isEmpty ? "" : " (\(differences.joined(separator: ", ")))"
            return "“\(candidate.lastPathComponent)” is not the \(mediaWord) this project was saved with\(what). Using it would change the result."
        }
        return "The \(mediaWord) “\(savedFileName)” could not be found at \(project.source.absolutePath)."
    }
}

enum ProjectActivity: Equatable {
    case idle
    case saved(URL, Date)
    case failed(String)
}

enum PresetActivity: Equatable {
    case idle
    case saved(String)
    case applied(String, notices: [String])
    case deleted(String)
    case failed(String)
}

/// A running or finished batch export (PRD §9.3).
struct BatchState: Equatable {
    var folder: URL
    var outputs: [BatchOutput]
    var summary: BatchSummary?
    var isRunning: Bool { summary == nil }
    var finishedCount: Int { outputs.filter { if case .finished = $0.status { return true } else { return false } }.count }
}

/// What the batch sheet exports: the current settings, other blend modes
/// over the current settings, and saved presets.
struct BatchChoice: Equatable {
    var includeCurrent = true
    var blendModes: Set<BlendMode> = []
    var presetURLs: Set<URL> = []
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
/// (cheap), registers an undo step, and schedules a debounced, cancellable
/// preview render.
@MainActor
final class AppModel: ObservableObject {
    // Source
    @Published private(set) var sourceState: SourceState = .empty
    @Published private(set) var source: MediaSource?

    var video: VideoSourceInfo? { source?.video }
    var imageSequence: ImageSequenceInfo? { source?.imageSequence }
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
    /// Take/skip counts of the Pattern sampling (M6h); undoable and saved.
    @Published var samplingPattern: SamplingPattern = .default { didSet { if samplingPattern != oldValue { settingsChanged() } } }
    /// Per-frame include/exclude decisions (M6h); undoable and saved; they belong to one source.
    @Published var frameOverrides: FrameOverrides = .none { didSet { if frameOverrides != oldValue { settingsChanged() } } }
    /// Stack last to first (M6h); only order-dependent modes re-render.
    @Published var reverseOrder: Bool = false { didSet { if reverseOrder != oldValue { settingsChanged() } } }
    @Published var blendMode: BlendMode = .average { didSet { settingsChanged() } }
    /// 0…1; only modes with `usesOpacity` re-render when it changes.
    @Published var opacity: Double = 1 {
        didSet { if blendMode.usesOpacity, opacity != oldValue { settingsChanged() } }
    }
    /// Pre-blend registration (M5b); undoable and saved.
    @Published var alignment: AlignmentSettings = .off { didSet { if alignment != oldValue { settingsChanged() } } }
    /// Post-composite straighten / crop / edge fill (M5c); undoable and saved.
    @Published var geometry: GeometrySettings = .identity { didSet { if geometry != oldValue { settingsChanged() } } }
    /// Temporal weighting (M6a); undoable and saved.
    @Published var weighting: WeightCurve = .flat { didSet { if weighting != oldValue { settingsChanged() } } }
    /// Motion mask (M6c); undoable and saved.
    @Published var motionMask: MotionMaskSettings = .off { didSet { if motionMask != oldValue { settingsChanged() } } }
    /// Painted mask (M6d); undoable (one step per stroke) and saved.
    @Published var paintedMask: PaintedMaskSettings = .off { didSet { if paintedMask != oldValue { settingsChanged() } } }
    /// Post-composite colour (M6e); undoable and saved; applied to the cached composite.
    @Published var color: ColorAdjustments = .identity { didSet { if color != oldValue { settingsChanged() } } }

    /// The last rendered composite and the compositing settings/quality it
    /// was rendered for. Colour and geometry changes re-process this instead
    /// of decoding frames again (PRD §10.1).
    private var cachedComposite: (key: CompositeCacheKey, result: CompositeResult)?
    /// How many frame renders the preview has started (for tests and the log).
    @Published private(set) var previewRenderCount = 0

    struct CompositeCacheKey: Equatable {
        let sourceURL: URL
        let settings: CompositeSettings
        let quality: PreviewQuality
    }

    /// The post-composite pipeline shared by preview and export: colour, then geometry.
    nonisolated static func postProcess(_ image: LinearImage, color: ColorAdjustments, geometry: GeometrySettings) throws -> LinearImage {
        try PostProcessor.apply(image, color: color, geometry: geometry)
    }
    /// Painting tool state (not saved): brush as a fraction of the canvas long edge, softness, erase.
    @Published var brushRadius: Double = 0.04
    @Published var brushSoftness: Double = 0.5
    @Published var brushErases = false
    /// Mouse drags on the preview paint instead of doing nothing.
    @Published var isPainting = false
    @Published var showPaintedMaskOverlay = true

    /// Adds a finished stroke (canvas-normalised points) as one undo step.
    func addStroke(points: [MaskStroke.Point]) {
        guard !points.isEmpty else { return }
        // One assignment → one undo step named after the stroke.
        var mask = paintedMask
        mask.strokes.append(MaskStroke(points: points, radius: brushRadius, softness: brushSoftness, erase: brushErases))
        mask.enabled = true
        paintedMask = mask
    }

    func clearStrokes() {
        paintedMask.strokes = []
    }

    /// Converts a point on the displayed (cropped) composite, normalised to
    /// its size, into canvas-normalised coordinates. Painting is only
    /// offered when there is no straighten angle (the mapping is then a
    /// plain crop offset).
    func canvasPoint(fromDisplayed p: CGPoint) -> MaskStroke.Point? {
        guard geometry.rotationDegrees == 0, let canvas = canvasSize else { return nil }
        let crop = geometry.crop.clamped(in: canvas)
        return MaskStroke.Point(x: crop.x + Double(p.x) * crop.width, y: crop.y + Double(p.y) * crop.height)
    }

    var canPaint: Bool { source != nil && geometry.rotationDegrees == 0 }
    /// Show the mask coverage (where motion contributed) instead of the composite.
    @Published var showMaskCoverage = false

    /// Uses the frame under the playhead as the mask background.
    func useMaskBackgroundAtPlayhead() {
        guard let time = scrubTime else { return }
        motionMask.background = .frame(time)
    }

    func useMedianMaskBackground() {
        motionMask.background = .median
    }

    /// The weights the current selection gets (for the curve preview).
    var currentWeights: WeightedSelection? {
        let times = selectedTimes
        guard !times.isEmpty else { return nil }
        return weighting.weights(for: times)
    }
    /// A folder of mixed-size stills was refused; the user may reopen it with Fit or Fill.
    @Published private(set) var mixedSizeRetry: [URL]?
    /// Alignment report of the last export.
    @Published private(set) var lastExportAlignment: AlignmentReport?
    /// Not part of `CompositeSettings`, so changing it re-renders (new
    /// revision) without an undo step.
    @Published var previewQuality: PreviewQuality = .draft { didSet { settingsChanged() } }
    /// Format, depth, size and color space of exports. Saved in projects;
    /// not undoable.
    @Published var exportSettings = ExportSettings()

    var exportBitDepth: ExportBitDepth {
        get { exportSettings.bitDepth }
        set { exportSettings.bitDepth = newValue }
    }

    // Project document
    @Published private(set) var projectURL: URL?
    /// The document as last read or written; the basis for "unsaved changes".
    @Published private(set) var savedProject: ProjectFile?
    @Published private(set) var projectActivity: ProjectActivity = .idle
    /// Something about the media differs from what the project recorded
    /// (frame count, duration, or the user relinked to a changed file).
    @Published private(set) var sourceNotice: String?
    /// Fingerprint of the open media, computed once at load.
    private(set) var sourceIdentity: SourceIdentity?
    /// Settings right after the clip (or project) finished loading.
    private var settingsAtOpen: CompositeSettings?
    private var exportSettingsAtOpen = ExportSettings()
    private var sourceRelinked = false

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
    /// "pass 2 of 7" while a multi-pass mode (Median) renders; nil otherwise.
    @Published private(set) var renderPass: String?
    @Published private(set) var exportActivity: ExportActivity = .idle

    // Presets (M6f)
    let presetStore: PresetStore
    @Published var presetListing = PresetListing.empty
    @Published var presetActivity: PresetActivity = .idle
    /// Names the next registered undo step instead of deriving it from the
    /// changed fields (a preset changes many at once).
    var pendingActionName: String?

    // Batch export (M6f)
    @Published var batch: BatchState?
    @Published var isBatchSheetPresented = false
    @Published var batchChoice = BatchChoice()
    var batchTask: Task<Void, Never>?

    /// The window's undo manager, handed in by the view. Settings changes
    /// register undo steps on it.
    weak var undoManager: UndoManager? {
        didSet { if undoManager !== oldValue { lastSettings = settings } }
    }

    // Recent files (most recent first), persisted.
    @Published private(set) var recentFiles: [URL] = []
    static let recentFilesLimit = 10
    private let defaults: UserDefaults
    private static let recentFilesKey = "recentFiles"

    init(defaults: UserDefaults = .standard, presetStore: PresetStore? = nil) {
        self.defaults = defaults
        self.presetStore = presetStore ?? PresetStore(directory: (try? PresetStore.defaultDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("FrameStack/Presets", isDirectory: true))
        recentFiles = (defaults.stringArray(forKey: Self.recentFilesKey) ?? []).map { URL(fileURLWithPath: $0) }
        reloadPresets()
    }

    private func noteRecent(_ url: URL) {
        var list = recentFiles.filter { $0.path != url.path }
        list.insert(url, at: 0)
        if list.count > Self.recentFilesLimit { list.removeLast(list.count - Self.recentFilesLimit) }
        recentFiles = list
        defaults.set(list.map(\.path), forKey: Self.recentFilesKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func clearRecentFiles() {
        recentFiles = []
        defaults.removeObject(forKey: Self.recentFilesKey)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    let renderer = CompositeRenderer()
    private var loadTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var sourceFrameTask: Task<Void, Never>?
    var previewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    var suppressChanges = false
    private var lastSettings: CompositeSettings?
    private var interactiveEditDepth = 0
    /// Settings when the current interactive edit (drag, slider) began; the
    /// whole edit registers as one undo step when it ends.
    private var interactiveStart: CompositeSettings?

    static let thumbnailCount = 32
    static let thumbnailHeight = 44

    // MARK: Derived values

    var samplingMode: SamplingMode { settings.samplingMode }

    var range: FrameTimeRange { FrameTimeRange(start: rangeStart, end: rangeEnd) }

    var settings: CompositeSettings {
        CompositeSettings(rangeStart: rangeStart, rangeEnd: rangeEnd, samplingKind: samplingKind,
                          nth: nth, exactCount: exactCount, blendMode: blendMode, opacity: opacity, alignment: alignment,
                          geometry: geometry, weighting: weighting, motionMask: motionMask, paintedMask: paintedMask, color: color,
                          samplingPattern: samplingPattern, frameOverrides: frameOverrides, reverseOrder: reverseOrder)
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
        if batch?.isRunning == true { return true }
        switch exportActivity {
        case .rendering, .writing: return true
        default: return false
        }
    }

    var canExport: Bool {
        if case .success? = selection, source != nil, !isExporting { return true }
        return false
    }

    /// How many decode passes a Median render needs at a given output size.
    func medianPlan(for size: PixelSize?) -> MedianPlan? {
        guard blendMode == .median, let size, let count = try? selection?.get().selectedCount, count > 0 else { return nil }
        return MedianPlan(outputSize: size, frameCount: count)
    }

    /// Pixel size the next export will have.
    var exportOutputSize: PixelSize? {
        source.map { geometry.outputSize(for: exportSettings.sizing.outputSize(for: $0.displaySize)) }
    }

    /// The canvas size the crop refers to (before crop, at native resolution).
    var canvasSize: PixelSize? { source?.displaySize }

    /// Full-resolution size of what the preview shows (after crop).
    var displayedFullSize: PixelSize {
        geometry.outputSize(for: source?.displaySize ?? PixelSize(width: 1, height: 1))
    }

    // MARK: Geometry

    /// Sets the crop to the largest rectangle that every aligned frame
    /// covers (after the straighten angle), from the last preview's report.
    func cropToSafeArea() {
        guard let preview, let canvas = canvasSize, preview.canvasSize.width > 0, preview.canvasSize.height > 0 else { return }
        var valid: CGRect?
        if let area = preview.alignment?.validArea, !area.isNull {
            let sx = Double(canvas.width) / Double(preview.canvasSize.width)
            let sy = Double(canvas.height) / Double(preview.canvasSize.height)
            valid = CGRect(x: area.minX * sx, y: area.minY * sy, width: area.width * sx, height: area.height * sy)
        }
        geometry.crop = geometry.largestValidCrop(valid: valid, canvas: canvas)
    }

    var canCropToSafeArea: Bool {
        preview != nil && (preview?.alignment != nil || geometry.rotationDegrees != 0)
    }

    func resetCrop() {
        geometry.crop = .full
    }

    func resetGeometry() {
        geometry = .identity
    }

    /// Crop in canvas pixels (origin top-left), for the fields.
    var cropPixels: CGRect {
        guard let canvas = canvasSize else { return .zero }
        return geometry.crop.pixelRect(in: canvas)
    }

    func setCropPixels(_ rect: CGRect) {
        guard let canvas = canvasSize else { return }
        geometry.crop = NormalizedRect.from(pixels: rect, in: canvas).clamped(in: canvas)
    }

    /// Reopens the current folder of stills with a different canvas policy.
    func setSequence(canvasPolicy: CanvasPolicy) {
        if let sequence = imageSequence {
            guard sequence.canvasPolicy != canvasPolicy else { return }
            load(.sequence(sequence.files.map(\.url), canvasPolicy), project: nil, projectURL: nil)
        } else if let urls = mixedSizeRetry {
            load(.sequence(urls, canvasPolicy), project: nil, projectURL: nil)
        }
    }

    var canSaveProject: Bool {
        if case .ready = sourceState, source != nil, timeline != nil { return true }
        return false
    }

    /// True when quitting would lose work: settings or export choices differ
    /// from the saved project, or — for a clip that was never saved — from
    /// the state right after opening it.
    var hasUnsavedChanges: Bool {
        guard canSaveProject else { return false }
        if let savedProject {
            return settings != savedProject.settings || exportSettings != savedProject.export || sourceRelinked
        }
        return settings != settingsAtOpen || exportSettings != exportSettingsAtOpen
    }

    var projectName: String? {
        projectURL?.deletingPathExtension().lastPathComponent
    }

    var windowTitle: String {
        projectName ?? source?.fileName ?? sourceStateFileName ?? "FrameStack"
    }

    var windowSubtitle: String {
        var parts: [String] = []
        if projectName != nil, let source { parts.append(source.fileName) }
        if hasUnsavedChanges { parts.append("Edited") }
        return parts.joined(separator: " — ")
    }

    private var sourceStateFileName: String? {
        if case let .loading(name, _) = sourceState { return name }
        return nil
    }

    // MARK: Opening

    static let projectType: UTType =
        UTType(ProjectFile.typeIdentifier) ?? UTType(exportedAs: ProjectFile.typeIdentifier, conformingTo: .json)

    static func isProject(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == ProjectFile.fileExtension
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, Self.projectType] + ImageSequenceLoader.imageTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose a video, a FrameStack project, a folder of images, or several images"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            open(panel.urls)
        }
    }

    /// Opens a video, a `.framestack` project, a folder of stills (one
    /// image stands for its whole folder) or an explicit set of stills.
    func open(_ url: URL) {
        open([url])
    }

    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        if urls.count == 1, Self.isProject(first) {
            openProject(first)
        } else if urls.count == 1, !ImageSequenceLoader.isDirectory(first), !ImageSequenceLoader.isImageFile(first) {
            load(.video(first), project: nil, projectURL: nil)
        } else {
            load(.sequence(urls), project: nil, projectURL: nil)
        }
    }

    /// Re-times or reverses the open image sequence. Frame identity is kept:
    /// the selected first/last frames stay the same images.
    func setSequence(framesPerSecond: Double? = nil, reversed: Bool? = nil) {
        guard let sequence = imageSequence, let timeline else { return }
        let fps = framesPerSecond ?? sequence.framesPerSecond
        guard fps > 0, fps.isFinite, fps <= 10_000 else { return }
        let updated = sequence.with(framesPerSecond: fps, reversed: reversed)
        guard updated != sequence else { return }
        let oldRange = timeline.frameIndices(in: range)
        var first = oldRange?.lowerBound ?? 0
        var last = oldRange?.upperBound ?? max(timeline.count - 1, 0)
        if updated.reversed != sequence.reversed {
            // The same images, now at mirrored indices.
            (first, last) = (timeline.count - 1 - last, timeline.count - 1 - first)
        }
        let newTimeline = updated.timeline
        source = .imageSequence(updated)
        self.timeline = newTimeline
        sourceIdentity = SourceIdentity.compute(forSequence: updated)
        sourceFrame = nil
        withUndoGroup {
            let new = newTimeline.range(firstFrame: first, lastFrame: last, end: updated.duration)
            rangeStart = new.start
            rangeEnd = new.end
        }
        if rangeStart == settings.rangeStart, rangeEnd == settings.rangeEnd { settingsChanged(debounce: false) }
        loadThumbnails(for: .imageSequence(updated), timeline: newTimeline)
        scheduleSourceFrame()
    }

    // MARK: Projects

    func openProject(_ url: URL) {
        let project: ProjectFile
        do {
            project = try ProjectFile.read(from: url)
        } catch {
            reset()
            sourceState = .failed(error.localizedDescription)
            return
        }
        switch SourceLocator.resolve(project.source, projectURL: url) {
        case let .found(media):
            load(Self.spec(for: media, in: project), project: project, projectURL: url)
        case let .changed(media, differences):
            reset()
            sourceState = .relink(RelinkRequest(project: project, projectURL: url, candidate: media, differences: differences))
        case .missing:
            reset()
            sourceState = .relink(RelinkRequest(project: project, projectURL: url, candidate: nil, differences: []))
        }
    }

    /// Relink panel: pick the media a project refers to.
    func presentRelinkPanel() {
        guard case let .relink(request) = sourceState else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = request.isSequence
        panel.canChooseFiles = !request.isSequence
        panel.message = "Locate “\(request.savedFileName)” for this project"
        panel.directoryURL = URL(fileURLWithPath: request.project.source.absolutePath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            relink(to: url)
        }
    }

    /// Uses `url` as the project's media if its fingerprint matches; otherwise
    /// asks again, now naming the chosen file as the candidate.
    func relink(to url: URL) {
        guard case let .relink(request) = sourceState else { return }
        switch SourceLocator.check(url, against: request.project.source) {
        case let .found(media):
            load(Self.spec(for: media, in: request.project), project: request.project, projectURL: request.projectURL)
        case let .changed(media, differences):
            sourceState = .relink(RelinkRequest(project: request.project, projectURL: request.projectURL,
                                                candidate: media, differences: differences))
        case .missing:
            sourceState = .relink(RelinkRequest(project: request.project, projectURL: request.projectURL,
                                                candidate: nil, differences: []))
        }
    }

    /// The user's explicit decision to use a file that differs from the saved
    /// media. The project is marked edited and the notice stays visible.
    func useRelinkCandidateAnyway() {
        guard case let .relink(request) = sourceState, let candidate = request.candidate else { return }
        load(Self.spec(for: candidate, in: request.project), project: request.project, projectURL: request.projectURL,
             relinkedToChangedMedia: true)
    }

    func cancelRelink() {
        guard case .relink = sourceState else { return }
        sourceState = .empty
    }

    /// The document as it would be written now.
    func currentProject(for projectURL: URL?) -> ProjectFile? {
        guard let source, let timeline, let sourceIdentity else { return nil }
        let reference = SourceReference.make(source: source, identity: sourceIdentity, frameCount: timeline.count, projectURL: projectURL)
        return ProjectFile(
            source: reference, settings: settings, export: exportSettings,
            ui: ProjectFile.UIState(previewQuality: previewQuality.rawValue, viewMode: viewMode.rawValue, scrubIndex: scrubIndex),
            writer: "FrameStack \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
        )
    }

    /// Save (⌘S): writes to the current project file or asks where to save.
    /// Returns false if nothing was written (cancelled panel or error).
    @discardableResult
    func saveProject() -> Bool {
        guard canSaveProject else { return false }
        if let projectURL { return save(to: projectURL) }
        return saveProjectAs()
    }

    @discardableResult
    func saveProjectAs() -> Bool {
        guard canSaveProject else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = (projectName ?? (source?.fileName as NSString?)?.deletingPathExtension ?? "Untitled") + ".\(ProjectFile.fileExtension)"
        panel.message = "Save the project (settings and a reference to the video — the video is not copied)"
        guard panel.runModal() == .OK, var url = panel.url else { return false }
        if url.pathExtension.lowercased() != ProjectFile.fileExtension {
            url.appendPathExtension(ProjectFile.fileExtension)
        }
        return save(to: url)
    }

    @discardableResult
    func save(to url: URL) -> Bool {
        guard let project = currentProject(for: url) else { return false }
        do {
            try project.write(to: url)
        } catch {
            projectActivity = .failed(error.localizedDescription)
            return false
        }
        projectURL = url
        savedProject = project
        sourceRelinked = false
        projectActivity = .saved(url, Date())
        noteRecent(url)
        return true
    }

    private func reset() {
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
        projectActivity = .idle
        batchTask?.cancel()
        batch = nil
        sourceNotice = nil
        sourceIdentity = nil
        mixedSizeRetry = nil
        // Alignment and geometry belong to a source (a project restores its
        // own); blend, sampling and export choices carry over like preferences.
        suppressChanges = true
        frameOverrides = .none
        alignment = .off
        geometry = .identity
        weighting = .flat
        motionMask = .off
        paintedMask = .off
        color = .identity
        suppressChanges = false
        cachedComposite = nil
        isPainting = false
        // Export choices follow the user from clip to clip, but a project's
        // choices do not leak into an unrelated video opened afterwards.
        if projectURL != nil { exportSettings = ExportSettings() }
        projectURL = nil
        savedProject = nil
        settingsAtOpen = nil
        sourceRelinked = false
        undoManager?.removeAllActions(withTarget: self)
        lastSettings = nil
        sourceState = .empty
    }

    /// What to load: a movie file, stills chosen by the user, or a saved
    /// sequence (exactly the saved file names inside a folder).
    enum MediaSpec {
        case video(URL)
        case sequence([URL], CanvasPolicy = .strict)
        case savedSequence(folder: URL, SequenceReference)

        var displayName: String {
            switch self {
            case let .video(url): return url.lastPathComponent
            case let .sequence(urls, _):
                guard let first = urls.first else { return "" }
                return (urls.count == 1 && ImageSequenceLoader.isDirectory(first)) ? first.lastPathComponent
                    : first.deletingLastPathComponent().lastPathComponent
            case let .savedSequence(folder, _): return folder.lastPathComponent
            }
        }

        var url: URL? {
            switch self {
            case let .video(url): return url
            case let .sequence(urls, _): return urls.first
            case let .savedSequence(folder, _): return folder
            }
        }
    }

    private static func spec(for media: URL, in project: ProjectFile) -> MediaSpec {
        if let sequence = project.source.sequence { return .savedSequence(folder: media, sequence) }
        return .video(media)
    }

    /// Loads media; when `project` is given, its settings are applied once
    /// the frames are known and the document becomes the window's project.
    private func load(_ spec: MediaSpec, project: ProjectFile?, projectURL: URL?, relinkedToChangedMedia: Bool = false) {
        reset()
        sourceState = .loading(fileName: spec.displayName, step: "Reading metadata…")

        loadTask = Task { [weak self] in
            do {
                let media: MediaSource
                let timeline: FrameTimeline
                var scan: FrameScanResult?
                let identity: SourceIdentity
                switch spec {
                case let .video(url):
                    let info = try await VideoSourceLoader.load(url: url)
                    guard let self, !Task.isCancelled else { return }
                    self.source = .video(info)
                    self.sourceState = .loading(fileName: info.fileName, step: "Scanning frame timestamps…")
                    async let identityTask = Task.detached(priority: .utility) { try SourceIdentity.compute(for: url) }.value
                    let result = try await FrameScanner.scan(info) { [weak self] count in
                        self?.reportScanProgress(count)
                    }
                    identity = try await identityTask
                    media = .video(info)
                    timeline = result.timeline
                    scan = result
                case let .sequence(urls, policy):
                    let info = try await ImageSequenceLoader.load(urls, canvasPolicy: policy)
                    media = .imageSequence(info)
                    timeline = info.timeline
                    identity = SourceIdentity.compute(forSequence: info)
                case let .savedSequence(folder, saved):
                    let info = try await ImageSequenceLoader.load(folder: folder, fileNames: saved.fileNames,
                                                                  framesPerSecond: saved.framesPerSecond, reversed: saved.reversed,
                                                                  canvasPolicy: saved.canvasPolicy)
                    media = .imageSequence(info)
                    timeline = info.timeline
                    identity = SourceIdentity.compute(forSequence: info)
                }
                guard let self, !Task.isCancelled else { return }
                self.source = media
                self.timeline = timeline
                self.scanResult = scan
                self.scanned = timeline.count
                self.sourceIdentity = identity
                self.suppressChanges = true
                self.rangeStart = .zero
                self.rangeEnd = media.duration
                if let project {
                    self.apply(project: project, to: media, timeline: timeline, relinkedToChangedMedia: relinkedToChangedMedia)
                }
                self.suppressChanges = false
                self.sourceState = .ready
                self.lastSettings = self.settings
                self.settingsAtOpen = self.settings
                self.exportSettingsAtOpen = self.exportSettings
                self.settingsChanged(debounce: false)
                if let project, let projectURL {
                    self.projectURL = projectURL
                    self.savedProject = project
                    self.sourceRelinked = relinkedToChangedMedia || project.source.absolutePath != media.url.standardizedFileURL.path
                    self.noteRecent(projectURL)
                } else {
                    self.noteRecent(media.url)
                }
                self.loadThumbnails(for: media, timeline: timeline)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.source = nil
                if case .mixedImageSizes = error as? MediaError, case let .sequence(urls, _) = spec {
                    self.mixedSizeRetry = urls
                }
                self.sourceState = .failed(error.localizedDescription)
            }
        }
    }

    /// Applies a project's settings to a freshly scanned clip. Values that
    /// no longer fit (a range past the end of a shorter clip) are clamped and
    /// reported in `sourceNotice`; nothing is silently dropped.
    private func apply(project: ProjectFile, to info: MediaSource, timeline: FrameTimeline, relinkedToChangedMedia: Bool) {
        var notices: [String] = []
        let word = info.isImageSequence ? "image folder" : "video"
        if relinkedToChangedMedia {
            notices.append("Relinked to “\(info.fileName)”, which differs from the \(word) the project was saved with.")
        }
        if timeline.count != project.source.frameCount || info.duration != project.source.duration {
            notices.append("The \(word) now has \(timeline.count) frames over \(Format.seconds(info.duration.seconds)); the project was saved with \(project.source.frameCount) frames over \(Format.seconds(project.source.duration.seconds)).")
        }
        if info.displaySize != project.source.displaySize {
            notices.append("The \(word) is \(info.displaySize); the project was saved with \(project.source.displaySize).")
        }
        var s = project.settings
        if s.rangeEnd > info.duration || s.rangeStart >= info.duration || !(s.rangeStart < s.rangeEnd) {
            notices.append("The saved time range \(Format.seconds(s.rangeStart.seconds)) – \(Format.seconds(s.rangeEnd.seconds)) does not fit this video; it was clamped.")
            s.rangeEnd = min(s.rangeEnd, info.duration)
            if !(s.rangeStart < s.rangeEnd) { s.rangeStart = .zero }
        }
        rangeStart = s.rangeStart
        rangeEnd = s.rangeEnd
        samplingKind = s.samplingKind
        nth = max(1, s.nth)
        exactCount = max(1, s.exactCount)
        samplingPattern = SamplingPattern(take: max(1, s.samplingPattern.take), skip: max(0, s.samplingPattern.skip))
        frameOverrides = s.frameOverrides
        blendMode = s.blendMode
        opacity = min(max(s.opacity, 0), 1)
        reverseOrder = s.reverseOrder
        alignment = s.alignment
        geometry = GeometrySettings(rotationDegrees: min(max(s.geometry.rotationDegrees, -GeometrySettings.maximumRotation), GeometrySettings.maximumRotation),
                                    crop: s.geometry.crop.clamped(in: info.displaySize), edgeFill: s.geometry.edgeFill)
        weighting = s.weighting
        motionMask = s.motionMask
        paintedMask = s.paintedMask
        color = s.color
        exportSettings = project.export
        if let quality = project.ui.previewQuality.flatMap(PreviewQuality.init(rawValue:)) { previewQuality = quality }
        if let mode = project.ui.viewMode.flatMap(PreviewViewMode.init(rawValue:)) { viewMode = mode }
        if let index = project.ui.scrubIndex { scrubIndex = min(max(index, 0), timeline.count - 1) }
        sourceNotice = notices.isEmpty ? nil : notices.joined(separator: " ")
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

    private func loadThumbnails(for source: MediaSource, timeline: FrameTimeline) {
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

    // Frame overrides (PRD §4.3)

    /// The override on the frame under the playhead (`nil` without a playhead).
    var overrideAtPlayhead: FrameOverrides.State? {
        scrubTime.map { frameOverrides.state(of: $0) }
    }

    /// The frame under the playhead is inside the time range.
    var playheadIsInRange: Bool {
        scrubTime.map { range.contains($0) } ?? false
    }

    /// The frame under the playhead is part of the current selection.
    var playheadIsSelected: Bool {
        guard let i = scrubIndex, case let .success(result)? = selection else { return false }
        return result.selectedIndices.contains(i)
    }

    func setOverrideAtPlayhead(_ state: FrameOverrides.State) {
        guard let time = scrubTime else { return }
        var overrides = frameOverrides
        overrides.set(state, for: time)
        frameOverrides = overrides
    }

    /// Excludes the playhead frame, or returns it to the sampling's decision.
    func toggleExcludeAtPlayhead() {
        guard let state = overrideAtPlayhead else { return }
        setOverrideAtPlayhead(state == .excluded ? .auto : .excluded)
    }

    func clearFrameOverrides() {
        frameOverrides = .none
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
    /// collapses into a single undo step. No undo groups are opened (the
    /// window's manager already groups by event and a nested group hid the
    /// action name); instead the intermediate values register nothing and
    /// one step from the start value to the end value is registered when
    /// the edit ends.
    func beginInteractiveEdit() {
        if interactiveEditDepth == 0 { interactiveStart = settings }
        interactiveEditDepth += 1
    }

    func endInteractiveEdit() {
        guard interactiveEditDepth > 0 else { return }
        interactiveEditDepth -= 1
        if interactiveEditDepth == 0, let start = interactiveStart {
            interactiveStart = nil
            registerUndo(from: start, to: settings)
        }
    }

    private func registerUndo(from old: CompositeSettings, to new: CompositeSettings) {
        guard old != new, let undoManager else { return }
        // A manager that does not group by event needs an explicit group
        // around every registration (the window's manager groups by event;
        // tests use an explicit one).
        let needsGroup = !undoManager.groupsByEvent && undoManager.groupingLevel == 0
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { model in
            // Called on the main thread by the undo manager; apply
            // synchronously so the redo registration lands while
            // `isUndoing` is still true.
            MainActor.assumeIsolated { model.apply(old) }
        }
        if !undoManager.isUndoing, !undoManager.isRedoing {
            undoManager.setActionName(pendingActionName ?? Self.actionName(from: old, to: new))
        }
        if needsGroup { undoManager.endUndoGrouping() }
    }

    /// Restores a settings snapshot as one change (undo/redo).
    func apply(_ s: CompositeSettings) {
        suppressChanges = true
        rangeStart = s.rangeStart
        rangeEnd = s.rangeEnd
        samplingKind = s.samplingKind
        nth = s.nth
        exactCount = s.exactCount
        samplingPattern = s.samplingPattern
        frameOverrides = s.frameOverrides
        blendMode = s.blendMode
        opacity = s.opacity
        reverseOrder = s.reverseOrder
        alignment = s.alignment
        geometry = s.geometry
        weighting = s.weighting
        motionMask = s.motionMask
        paintedMask = s.paintedMask
        color = s.color
        suppressChanges = false
        settingsChanged()
    }

    /// Aligns to the frame under the playhead (falls back to the middle
    /// frame if that frame is not selected).
    func useReferenceAtPlayhead() {
        guard let time = scrubTime else { return }
        alignment.reference = .frame(time)
    }

    func useMiddleReference() {
        alignment.reference = .middle
    }

    /// The frame the current selection is aligned to.
    var alignmentReferenceTime: FrameTime? {
        alignment.reference.resolve(in: selectedTimes)
    }

    func settingsChanged(debounce: Bool = true) {
        guard !suppressChanges else { return }
        let new = settings
        if interactiveEditDepth == 0, let old = lastSettings {
            registerUndo(from: old, to: new)
        }
        lastSettings = new
        settingsRevision += 1
        if let timeline {
            do {
                selection = .success(try new.selection(in: timeline))
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
        if old.samplingKind != new.samplingKind || old.nth != new.nth || old.exactCount != new.exactCount
            || old.samplingPattern != new.samplingPattern { return "Change Sampling" }
        if old.frameOverrides != new.frameOverrides {
            let (before, after) = (old.frameOverrides, new.frameOverrides)
            if after.isEmpty { return before.count == 1 ? "Clear Frame Override" : "Clear Frame Overrides" }
            if after.excluded.count > before.excluded.count { return "Exclude Frame" }
            if after.included.count > before.included.count { return "Always Include Frame" }
            return "Clear Frame Override"
        }
        if old.blendMode != new.blendMode { return "Change Blend Mode" }
        if old.reverseOrder != new.reverseOrder { return "Reverse Stacking Order" }
        if old.opacity != new.opacity { return "Change Opacity" }
        if old.alignment != new.alignment { return "Change Alignment" }
        if old.geometry.rotationDegrees != new.geometry.rotationDegrees { return "Straighten" }
        if old.geometry.crop != new.geometry.crop { return "Change Crop" }
        if old.geometry.edgeFill != new.geometry.edgeFill { return "Change Edge Fill" }
        if old.weighting != new.weighting { return "Change Weighting" }
        if old.motionMask != new.motionMask { return "Change Motion Mask" }
        if old.paintedMask != new.paintedMask {
            if new.paintedMask.strokes.count == old.paintedMask.strokes.count + 1, let last = new.paintedMask.strokes.last {
                return last.erase ? "Erase Mask" : "Paint Mask"
            }
            if new.paintedMask.strokes.isEmpty, !old.paintedMask.strokes.isEmpty { return "Clear Painted Mask" }
            return "Change Painted Mask"
        }
        if old.color != new.color {
            if old.color.exposure != new.color.exposure { return "Change Exposure" }
            if old.color.contrast != new.color.contrast { return "Change Contrast" }
            if old.color.saturation != new.color.saturation { return "Change Saturation" }
            if old.color.curve != new.color.curve { return "Change Tone Curve" }
            return "Change White Balance"
        }
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
            maxLongEdge: previewQuality.maxLongEdge,
            alignment: alignment,
            weighting: weighting,
            motionMask: motionMask,
            paintedMask: paintedMask,
            reverseOrder: reverseOrder
        )
        let revision = settingsRevision
        let renderer = renderer
        let geometry = geometry
        let color = color
        let key = CompositeCacheKey(sourceURL: source.url, settings: settings.compositingPart, quality: previewQuality)
        let cached = cachedComposite?.key == key ? cachedComposite?.result : nil
        renderActivity = cached == nil ? .waiting : .idle

        previewTask = Task { [weak self] in
            if debounce, cached == nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled else { return }
            do {
                let result: CompositeResult
                if let cached {
                    result = cached
                } else {
                    self?.renderActivity = .rendering(done: 0, total: request.frames.count)
                    self?.previewRenderCount += 1
                    result = try await renderer.render(request) { [weak self] progress in
                        self?.reportPreviewProgress(progress, revision: revision)
                    }
                }
                let (image, finalSize, coverageImage) = try await Task.detached(priority: .userInitiated) {
                    let processed = try Self.postProcess(result.image, color: color, geometry: geometry)
                    var coverage: CGImage?
                    if let c = result.coverage {
                        // Grayscale: white where every frame moved, black where none did; same geometry as the composite.
                        var pixels = [Float](repeating: 1, count: c.count * LinearImage.channelCount)
                        for (p, v) in c.enumerated() { let o = p * 4; pixels[o] = v; pixels[o + 1] = v; pixels[o + 2] = v }
                        let gray = try GeometryProcessor.apply(GeometrySettings(rotationDegrees: geometry.rotationDegrees, crop: geometry.crop, edgeFill: .black),
                                                              to: LinearImage(width: result.image.width, height: result.image.height, pixels: pixels))
                        coverage = try ImageExporter.makeCGImage(gray, bitDepth: .eight)
                    }
                    return (try ImageExporter.makeCGImage(processed, bitDepth: .eight, alpha: ImageExporter.hasTransparency(processed)), processed.size, coverage)
                }.value
                guard let self, !Task.isCancelled, revision == self.settingsRevision else { return }
                self.cachedComposite = (key, result)
                self.preview = PreviewSnapshot(
                    image: image,
                    revision: revision,
                    size: finalSize,
                    framesComposited: result.framesComposited,
                    missingFrames: result.missingFrames.count,
                    decodeFailure: result.decodeFailureSummary,
                    elapsedSeconds: result.elapsedSeconds,
                    alignment: result.alignment,
                    weighting: result.weighting,
                    median: result.median,
                    motionMask: result.motionMask,
                    coverageImage: coverageImage,
                    canvasSize: result.image.size,
                    stackedInReverse: result.stackedInReverse,
                    reverseDecode: result.reverseDecode
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
        if batch?.isRunning == true {
            cancelBatch()
        } else if isExporting {
            exportTask?.cancel()
        } else {
            previewTask?.cancel()
            if case .rendering = renderActivity { renderActivity = .idle }
            if case .waiting = renderActivity { renderActivity = .idle }
        }
    }

    // MARK: Export

    var suggestedExportName: String {
        let ext = exportSettings.format.fileExtension
        guard let source else { return "FrameStack.\(ext)" }
        let base = projectName ?? (source.fileName as NSString).deletingPathExtension
        let count = (try? selection?.get().selectedCount) ?? 0
        let mode = blendMode == .normal ? "Normal" : blendMode.displayName
        let opacityPart = blendMode.usesOpacity && opacity < 1 ? " \(Int((opacity * 100).rounded()))%" : ""
        let sizePart = exportSettings.sizing == .native && !geometry.hasTransform ? "" : " \(exportOutputSize?.longEdge ?? 0)px"
        return "\(base) \(mode)\(opacityPart) \(count)f\(sizePart).\(ext)"
    }

    func presentExportPanel() {
        guard canExport else { return }
        let panel = NSSavePanel()
        switch exportSettings.format {
        case .png: panel.allowedContentTypes = [.png]
        case .jpeg: panel.allowedContentTypes = [.jpeg]
        case .tiff: panel.allowedContentTypes = [.tiff]
        }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedExportName
        let size = exportOutputSize?.description ?? ""
        panel.message = "Export the composite as \(exportSettings.effectiveBitDepth.displayName) \(exportSettings.format.displayName), \(size), \(exportSettings.colorSpace.displayName)"
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
            maxLongEdge: exportSettings.sizing.maxLongEdge(for: source.displaySize),
            alignment: alignment,
            weighting: weighting,
            motionMask: motionMask,
            paintedMask: paintedMask,
            reverseOrder: reverseOrder
        )
        let settings = exportSettings
        let geometry = geometry
        let color = color
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
                self?.lastExportAlignment = composite.alignment
                self?.exportActivity = .writing
                let report = try await Task.detached(priority: .userInitiated) {
                    try ImageExporter.write(try Self.postProcess(composite.image, color: color, geometry: geometry), to: url, settings: settings)
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
                self.renderPass = progress.passes > 1 ? "pass \(progress.pass) of \(progress.passes)" : nil
            }
        }
    }

    nonisolated private func reportExportProgress(_ progress: CompositeProgress) {
        Task { @MainActor [weak self] in
            guard let self, case .rendering = self.exportActivity else { return }
            self.exportActivity = .rendering(done: progress.framesComposited, total: progress.framesTotal)
            self.renderPass = progress.passes > 1 ? "pass \(progress.pass) of \(progress.passes)" : nil
        }
    }

    func revealExport() {
        if case let .finished(report, _, _) = exportActivity {
            NSWorkspace.shared.activateFileViewerSelecting([report.url])
        }
    }
}
