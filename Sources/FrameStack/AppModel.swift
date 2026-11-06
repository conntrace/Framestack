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

    var message: String {
        if let candidate {
            let what = differences.isEmpty ? "" : " (\(differences.joined(separator: ", ")))"
            return "“\(candidate.lastPathComponent)” is not the video this project was saved with\(what). Using it would change the result."
        }
        return "The video “\(savedFileName)” could not be found at \(project.source.absolutePath)."
    }
}

enum ProjectActivity: Equatable {
    case idle
    case saved(URL, Date)
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
    @Published private(set) var exportActivity: ExportActivity = .idle

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentFiles = (defaults.stringArray(forKey: Self.recentFilesKey) ?? []).map { URL(fileURLWithPath: $0) }
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

    /// Pixel size the next export will have.
    var exportOutputSize: PixelSize? {
        source.map { exportSettings.sizing.outputSize(for: $0.displaySize) }
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
        panel.allowedContentTypes = [.movie, Self.projectType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a video to stack, or a FrameStack project"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    /// Opens a video or a `.framestack` project.
    func open(_ url: URL) {
        if Self.isProject(url) {
            openProject(url)
        } else {
            load(video: url, project: nil, projectURL: nil)
        }
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
            load(video: media, project: project, projectURL: url)
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
        panel.canChooseDirectories = false
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
        switch SourceLocator.check(url, against: request.project.source.identity) {
        case let .found(media):
            load(video: media, project: request.project, projectURL: request.projectURL)
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
        load(video: candidate, project: request.project, projectURL: request.projectURL, relinkedToChangedMedia: true)
    }

    func cancelRelink() {
        guard case .relink = sourceState else { return }
        sourceState = .empty
    }

    /// The document as it would be written now.
    func currentProject(for projectURL: URL?) -> ProjectFile? {
        guard let source, let timeline, let sourceIdentity else { return nil }
        let reference = SourceReference.make(
            url: source.url, identity: sourceIdentity, duration: source.duration, displaySize: source.displaySize,
            frameCount: timeline.count, projectURL: projectURL
        )
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
        sourceNotice = nil
        sourceIdentity = nil
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

    /// Loads a video; when `project` is given, its settings are applied once
    /// the clip is scanned and the document becomes the window's project.
    private func load(video url: URL, project: ProjectFile?, projectURL: URL?, relinkedToChangedMedia: Bool = false) {
        reset()
        sourceState = .loading(fileName: url.lastPathComponent, step: "Reading metadata…")

        loadTask = Task { [weak self] in
            do {
                let info = try await VideoSourceLoader.load(url: url)
                guard let self, !Task.isCancelled else { return }
                self.source = info
                self.sourceState = .loading(fileName: info.fileName, step: "Scanning frame timestamps…")
                async let identityTask = Task.detached(priority: .utility) { try SourceIdentity.compute(for: url) }.value
                let scan = try await FrameScanner.scan(info) { [weak self] count in
                    self?.reportScanProgress(count)
                }
                let identity = try await identityTask
                guard !Task.isCancelled else { return }
                self.timeline = scan.timeline
                self.scanResult = scan
                self.scanned = scan.timeline.count
                self.sourceIdentity = identity
                self.suppressChanges = true
                self.rangeStart = .zero
                self.rangeEnd = info.duration
                if let project {
                    self.apply(project: project, to: info, timeline: scan.timeline, relinkedToChangedMedia: relinkedToChangedMedia)
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
                    self.sourceRelinked = relinkedToChangedMedia || project.source.absolutePath != url.standardizedFileURL.path
                    self.noteRecent(projectURL)
                } else {
                    self.noteRecent(url)
                }
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

    /// Applies a project's settings to a freshly scanned clip. Values that
    /// no longer fit (a range past the end of a shorter clip) are clamped and
    /// reported in `sourceNotice`; nothing is silently dropped.
    private func apply(project: ProjectFile, to info: VideoSourceInfo, timeline: FrameTimeline, relinkedToChangedMedia: Bool) {
        var notices: [String] = []
        if relinkedToChangedMedia {
            notices.append("Relinked to “\(info.fileName)”, which differs from the video the project was saved with.")
        }
        if timeline.count != project.source.frameCount || info.duration != project.source.duration {
            notices.append("The video now has \(timeline.count) frames over \(Format.seconds(info.duration.seconds)); the project was saved with \(project.source.frameCount) frames over \(Format.seconds(project.source.duration.seconds)).")
        }
        if info.displaySize != project.source.displaySize {
            notices.append("The video is \(info.displaySize); the project was saved with \(project.source.displaySize).")
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
        blendMode = s.blendMode
        opacity = min(max(s.opacity, 0), 1)
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
        let ext = exportSettings.format.fileExtension
        guard let source else { return "FrameStack.\(ext)" }
        let base = projectName ?? (source.fileName as NSString).deletingPathExtension
        let count = (try? selection?.get().selectedCount) ?? 0
        let mode = blendMode == .normal ? "Normal" : blendMode.displayName
        let opacityPart = blendMode.usesOpacity && opacity < 1 ? " \(Int((opacity * 100).rounded()))%" : ""
        let sizePart = exportSettings.sizing == .native ? "" : " \(exportOutputSize?.longEdge ?? 0)px"
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
            maxLongEdge: exportSettings.sizing.maxLongEdge(for: source.displaySize)
        )
        let settings = exportSettings
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
                    try ImageExporter.write(composite.image, to: url, settings: settings)
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
