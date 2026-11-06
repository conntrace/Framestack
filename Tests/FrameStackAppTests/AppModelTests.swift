import FrameStackCore
import FrameStackMedia
@testable import FrameStack
import XCTest

/// Automated version of the README "Manual verification" checklist, driven
/// through `AppModel` (the window's whole state) without a window. The
/// SwiftUI views are thin bindings onto this model, so these tests cover the
/// behavior the owner would otherwise click through: import → counts → range
/// and sampling edits → outdated/current preview → cancel → export → repeat.
@MainActor
final class AppModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackApp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixtureURL(_ name: String) -> URL {
        // Fixtures live in the media test bundle; reach them by path.
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FrameStackMediaTests/Fixtures/\(name).mp4")
    }

    /// Polls on the main actor until `condition` holds or `timeout` passes.
    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw XCTSkip("timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func openAndWait(_ model: AppModel, _ name: String) async throws {
        model.open(fixtureURL(name))
        if case .loading = model.sourceState {} else { XCTFail("expected loading state") }
        try await waitUntil { if case .ready = model.sourceState { return true } else { return false } }
        try await waitUntil { model.isPreviewCurrent }
    }

    // Checklist 1 + 2: import, metadata, scanned count, preview, selection summary.
    func testImportShowsMetadataScannedCountAndPreview() async throws {
        let model = AppModel()
        try await openAndWait(model, "count_5s_30fps")

        let source = try XCTUnwrap(model.source)
        XCTAssertEqual(source.fileName, "count_5s_30fps.mp4")
        XCTAssertEqual(source.displaySize, PixelSize(width: 320, height: 180))
        XCTAssertEqual(source.estimatedFrameCount, 150, "estimate shown before the scan")
        XCTAssertEqual(model.timeline?.count, 150, "scanned count")
        XCTAssertEqual(model.scanResult?.method, .sampleTable)
        XCTAssertEqual(model.rangeStart, .zero)
        XCTAssertEqual(model.rangeEnd, source.duration)

        let selection = try XCTUnwrap(try model.selection?.get())
        XCTAssertEqual(selection.eligibleCount, 150)
        XCTAssertEqual(selection.selectedCount, 150)
        XCTAssertEqual(model.selectedTimes.count, 150)

        let preview = try XCTUnwrap(model.preview)
        XCTAssertEqual(preview.framesComposited, 150)
        XCTAssertEqual(preview.missingFrames, 0)
        XCTAssertNil(preview.decodeFailure)
        XCTAssertEqual(preview.size, PixelSize(width: 320, height: 180), "already below the 1080 px preview cap")
        XCTAssertEqual(model.renderActivity, .idle)
        XCTAssertTrue(model.canExport)
    }

    // Checklist 3: range edits update counts immediately and mark the preview outdated.
    func testRangeEditUpdatesSelectionAndOutdatesPreview() async throws {
        let model = AppModel()
        try await openAndWait(model, "count_5s_30fps")
        let revision = model.settingsRevision

        model.rangeStart = FrameTime(seconds: 2)
        model.rangeEnd = FrameTime(seconds: 5)
        XCTAssertEqual(model.settingsRevision, revision + 2)
        XCTAssertFalse(model.isPreviewCurrent, "old preview is shown as outdated until the new one lands")
        XCTAssertEqual(try model.selection?.get().eligibleCount, 90, "[2, 5) on 30 fps")
        XCTAssertEqual(model.range.durationSeconds, 3, accuracy: 1e-9)

        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.preview?.framesComposited, 90)

        // An inverted range is an error, not a crash, and export is disabled.
        model.rangeEnd = FrameTime(seconds: 1)
        if case .failure(let error)? = model.selection {
            XCTAssertEqual(error, .emptyRange)
        } else {
            XCTFail("expected a selection error")
        }
        XCTAssertFalse(model.canExport)
        XCTAssertEqual(model.renderActivity, .idle)

        model.resetRange()
        XCTAssertEqual(try model.selection?.get().eligibleCount, 150)
    }

    // Checklist 4: Every Nth, Exact Count, and the clamping notice.
    func testSamplingModesAndClampingNotice() async throws {
        let model = AppModel()
        try await openAndWait(model, "count_5s_30fps")
        model.rangeStart = FrameTime(seconds: 1)
        model.rangeEnd = FrameTime(seconds: 2)
        XCTAssertEqual(try model.selection?.get().selectedCount, 30)

        model.samplingKind = .everyNth
        model.nth = 3
        XCTAssertEqual(try model.selection?.get().selectedCount, 10)
        XCTAssertEqual(model.selectedTimes.first, model.timeline?.frames[30], "starts with the first eligible frame")

        model.samplingKind = .exactCount
        model.exactCount = 20
        let exact = try XCTUnwrap(try model.selection?.get())
        XCTAssertEqual(exact.selectedCount, 20)
        XCTAssertEqual(exact.selectedIndices.first, 30)
        XCTAssertEqual(exact.selectedIndices.last, 59, "first and last eligible frames included")
        XCTAssertEqual(exact.notices, [])

        model.exactCount = 5000
        let clamped = try XCTUnwrap(try model.selection?.get())
        XCTAssertEqual(clamped.selectedCount, 30)
        XCTAssertEqual(clamped.notices, [.exactCountClamped(requested: 5000, available: 30)])

        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.preview?.framesComposited, 30)
    }

    // Checklist 5: cancel a running preview; the app stays usable.
    func testCancelPreviewThenRenderAgain() async throws {
        let model = AppModel()
        try await openAndWait(model, "count_5s_30fps")
        model.previewQuality = .full
        model.renderPreviewNow()
        try await waitUntil { if case .rendering = model.renderActivity { return true } else { return false } }
        model.cancelRendering()
        XCTAssertEqual(model.renderActivity, .idle)
        XCTAssertFalse(model.isPreviewCurrent)

        // Give a cancelled task time to (not) deliver a result, then render again.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(model.isPreviewCurrent, "a cancelled render must not publish a preview")
        model.renderPreviewNow()
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.preview?.framesComposited, 150)
    }

    // Loading can be abandoned (e.g. a file iCloud never delivers).
    func testCancelLoading() async throws {
        let model = AppModel()
        model.open(fixtureURL("count_5s_30fps"))
        model.cancelLoading()
        if case .empty = model.sourceState {} else { XCTFail("expected empty state after cancel") }
        XCTAssertNil(model.source)
        try await Task.sleep(nanoseconds: 500_000_000)
        if case .empty = model.sourceState {} else { XCTFail("a cancelled load must not complete later") }
        XCTAssertNil(model.preview)
    }

    // Opening a missing or damaged file fails with a message, not a hang.
    func testMissingFileFailsClearly() async throws {
        let model = AppModel()
        model.open(directory.appendingPathComponent("nope.mov"))
        try await waitUntil { if case .failed = model.sourceState { return true } else { return false } }
        if case .failed(let message) = model.sourceState {
            XCTAssertTrue(message.contains("nope.mov"), message)
        }
        XCTAssertFalse(model.canExport)
    }

    // Checklist 6 + 7: export at full resolution, verified; change settings; export again.
    func testExportThenChangeSettingsAndExportAgain() async throws {
        let model = AppModel()
        try await openAndWait(model, "moving_square_24f")
        model.previewQuality = .draft
        model.exportBitDepth = .sixteen

        let first = directory.appendingPathComponent("first.png")
        model.export(to: first)
        XCTAssertTrue(model.isExporting)
        try await waitUntil { !model.isExporting }
        guard case let .finished(report, missing, failure) = model.exportActivity else {
            return XCTFail("export did not finish: \(model.exportActivity)")
        }
        XCTAssertEqual(report.width, 480)
        XCTAssertEqual(report.height, 272)
        XCTAssertEqual(report.bitDepth, 16)
        XCTAssertTrue(report.colorProfileName?.contains("sRGB") ?? false)
        XCTAssertEqual(missing, 0)
        XCTAssertNil(failure)
        XCTAssertEqual(try ImageExporter.inspect(first).bitDepth, 16)

        model.samplingKind = .everyNth
        model.nth = 2
        model.exportBitDepth = .eight
        let second = directory.appendingPathComponent("second.png")
        model.export(to: second)
        try await waitUntil { !model.isExporting }
        guard case let .finished(report2, _, _) = model.exportActivity else {
            return XCTFail("second export did not finish: \(model.exportActivity)")
        }
        XCTAssertEqual(report2.bitDepth, 8)
        XCTAssertEqual(model.suggestedExportName, "moving_square_24f Average 12f.png")
        try await waitUntil { model.isPreviewCurrent }
    }

    // M2: blend mode and opacity drive re-renders and the export name.
    func testBlendModeAndOpacityChanges() async throws {
        let model = AppModel()
        try await openAndWait(model, "black_white_30f")
        let revision = model.settingsRevision

        model.opacity = 0.5
        XCTAssertEqual(model.settingsRevision, revision, "opacity is irrelevant to Average: no re-render")

        model.blendMode = .normal
        XCTAssertEqual(model.settingsRevision, revision + 1)
        XCTAssertFalse(model.isPreviewCurrent)
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.suggestedExportName, "black_white_30f Normal 50% 30f.png")

        model.opacity = 1
        XCTAssertEqual(model.settingsRevision, revision + 2)
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.suggestedExportName, "black_white_30f Normal 30f.png")

        model.blendMode = .lighten
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.suggestedExportName, "black_white_30f Lighten 30f.png")
        XCTAssertEqual(model.preview?.framesComposited, 30)
    }

    // M3: frame-accurate range entry, playhead, in/out points.
    func testFrameRangeEntryAndPlayhead() async throws {
        let model = AppModel()
        try await openAndWait(model, "count_5s_30fps")
        XCTAssertEqual(model.frameRange, 0...149)
        XCTAssertNil(model.scrubIndex)

        model.setFrameRange(first: 60, last: 149)
        XCTAssertEqual(model.rangeStart, model.timeline!.frames[60])
        XCTAssertEqual(model.rangeEnd, model.source!.duration, "last frame inclusive → duration")
        XCTAssertEqual(try model.selection?.get().eligibleCount, 90)

        model.setLastFrame(89)
        XCTAssertEqual(model.rangeEnd, model.timeline!.frames[90], "exclusive end = next frame's time")
        XCTAssertEqual(model.frameRange, 60...89)
        model.setFirstFrame(95)
        XCTAssertEqual(model.frameRange, 95...95, "first past last → single frame, never empty")

        // Playhead: stepping clamps; in/out points at the playhead.
        model.stepScrub(by: -1)
        XCTAssertEqual(model.scrubIndex, 94, "starts from the range start when unset")
        model.scrubIndex = 10
        model.stepScrub(by: -50)
        XCTAssertEqual(model.scrubIndex, 0)
        model.stepScrub(by: 1000)
        XCTAssertEqual(model.scrubIndex, 149)
        model.scrub(to: FrameTime(seconds: 2.51))
        XCTAssertEqual(model.scrubIndex, 75)
        XCTAssertEqual(model.scrubTime, model.timeline!.frames[75])

        model.setInPointAtPlayhead()
        XCTAssertEqual(model.frameRange, 75...95)
        model.scrubIndex = 120
        model.setOutPointAtPlayhead()
        XCTAssertEqual(model.frameRange, 75...120)
        model.scrubIndex = 30
        model.setOutPointAtPlayhead()
        XCTAssertEqual(model.frameRange, 30...30, "out before in → both move")

        // Snapped handle drags keep the range non-empty.
        model.setRangeStartSnapped(to: FrameTime(seconds: 1.0))
        XCTAssertEqual(model.frameRange, 30...30)
        model.setRangeEndSnapped(to: FrameTime(seconds: 2.0))
        XCTAssertEqual(model.frameRange, 30...59)
        model.setRangeStartSnapped(to: FrameTime(seconds: 4.0))
        XCTAssertEqual(model.frameRange, 120...120, "start dragged past end pushes end along")
        model.setRangeEndSnapped(to: FrameTime(seconds: 0.0))
        XCTAssertEqual(model.frameRange?.count, 1, "end dragged before start keeps one frame")
    }

    func testUndoRedoOfSettings() async throws {
        let model = AppModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        try await openAndWait(model, "count_5s_30fps")
        XCTAssertFalse(undo.canUndo, "opening a file is not undoable")

        model.rangeStart = FrameTime(seconds: 1)
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, "Change Time Range")
        model.blendMode = .lighten
        XCTAssertEqual(undo.undoActionName, "Change Blend Mode")

        undo.undo()
        XCTAssertEqual(model.blendMode, .average)
        XCTAssertEqual(model.rangeStart, FrameTime(seconds: 1))
        XCTAssertTrue(undo.canRedo)
        XCTAssertEqual(undo.redoActionName, "Change Blend Mode")
        undo.undo()
        XCTAssertEqual(model.rangeStart, .zero)
        XCTAssertFalse(undo.canUndo)
        undo.redo()
        XCTAssertEqual(model.rangeStart, FrameTime(seconds: 1))
        XCTAssertEqual(model.blendMode, .average)
        undo.redo()
        XCTAssertEqual(model.blendMode, .lighten)
        XCTAssertFalse(model.isPreviewCurrent, "undo/redo re-render like any change")

        // A grouped edit (drag / slider) is one step.
        model.blendMode = .normal
        model.beginInteractiveEdit()
        for v in [0.9, 0.7, 0.5, 0.3] { model.opacity = v }
        model.endInteractiveEdit()
        XCTAssertEqual(model.opacity, 0.3)
        undo.undo()
        XCTAssertEqual(model.opacity, 1, "whole drag undone at once")
        XCTAssertEqual(model.blendMode, .normal)

        // setFrameRange changes start and end as one step.
        model.setFrameRange(first: 10, last: 20)
        XCTAssertEqual(model.frameRange, 10...20)
        undo.undo()
        XCTAssertEqual(model.frameRange, 30...149)

        // Preview quality is not undoable but does re-render.
        let revision = model.settingsRevision
        model.previewQuality = .high
        XCTAssertEqual(model.settingsRevision, revision + 1)
        XCTAssertFalse(model.isPreviewCurrent)
        XCTAssertEqual(undo.undoActionName, "Change Blend Mode", "quality change registered no undo step; top is still the Normal switch")

        // Opening another clip clears the stack.
        try await openAndWait(model, "moving_square_24f")
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
    }

    func testThumbnailsLoadAfterImport() async throws {
        let model = AppModel()
        try await openAndWait(model, "portrait_rot90cw")
        try await waitUntil { !model.thumbnails.isEmpty }
        XCTAssertEqual(model.thumbnails.count, min(AppModel.thumbnailCount, model.timeline!.count), "10-frame clip → 10 distinct thumbnails")
        XCTAssertLessThan(model.thumbnails[0].image.width, model.thumbnails[0].image.height, "upright portrait")
        model.open(fixtureURL("count_5s_30fps"))
        XCTAssertTrue(model.thumbnails.isEmpty, "cleared on open")
    }

    // M3: original frame view and zoom.
    func testOriginalViewLoadsTheFrameUnderThePlayhead() async throws {
        let model = AppModel()
        try await openAndWait(model, "count_5s_30fps")
        XCTAssertNil(model.sourceFrame, "nothing decoded while showing the composite")

        model.viewMode = .original
        XCTAssertEqual(model.scrubIndex, 0, "playhead defaults to the range start")
        try await waitUntil { model.sourceFrame != nil }
        XCTAssertEqual(model.sourceFrame?.index, 0)
        XCTAssertEqual(model.sourceFrame?.image.width, 320)

        model.scrubIndex = 75
        try await waitUntil { model.sourceFrame?.index == 75 }
        XCTAssertEqual(model.sourceFrame?.time, model.timeline?.frames[75])

        // Rapid stepping settles on the last frame requested.
        for i in 76...90 { model.scrubIndex = i }
        try await waitUntil { model.sourceFrame?.index == 90 }
        XCTAssertEqual(model.sourceFrame?.index, 90)

        model.viewMode = .sideBySide
        XCTAssertEqual(model.sourceFrame?.index, 90, "kept across view modes")
        try await openAndWait(model, "moving_square_24f")
        XCTAssertNil(model.sourceFrame, "cleared on open")
    }

    func testZoomSteps() {
        let size = PixelSize(width: 1000, height: 500)
        let viewport = CGSize(width: 500, height: 500)
        XCTAssertEqual(ZoomMode.fitScale(for: size, in: viewport), 0.5)
        XCTAssertEqual(ZoomMode.fit.scale(for: size, in: viewport), 0.5)
        XCTAssertEqual(ZoomMode.scale(2).scale(for: size, in: viewport), 2)
        XCTAssertEqual(ZoomMode.stepIn(from: 0.5), 0.667)
        XCTAssertEqual(ZoomMode.stepIn(from: 0.6), 0.667)
        XCTAssertEqual(ZoomMode.stepOut(from: 0.5), 0.333)
        XCTAssertEqual(ZoomMode.stepIn(from: 8), 8, "top of the range")
        XCTAssertEqual(ZoomMode.stepOut(from: 0.1), 0.1)
        XCTAssertEqual(ZoomMode.clamped(50), 8)

        let model = AppModel()
        XCTAssertEqual(model.zoom, .fit)
        model.zoomActualSize()
        XCTAssertEqual(model.zoom, .scale(1))
        model.zoomIn(viewport: viewport)
        XCTAssertEqual(model.zoom, .scale(1.5))
        model.zoomOut(viewport: viewport)
        model.zoomOut(viewport: viewport)
        XCTAssertEqual(model.zoom, .scale(0.667))
        model.zoomToFit()
        XCTAssertEqual(model.zoom, .fit)
    }

    // A damaged file still produces a composite and says what is missing.
    func testCorruptFileReportsMissingFramesInPreviewAndExport() async throws {
        let model = AppModel()
        try await openAndWait(model, "corrupt_frame_75")
        let preview = try XCTUnwrap(model.preview)
        XCTAssertGreaterThan(preview.missingFrames, 0)
        XCTAssertEqual(preview.missingFrames + preview.framesComposited, 150)
        XCTAssertTrue(preview.decodeFailure?.contains("Cannot Decode") ?? false, preview.decodeFailure ?? "nil")

        let url = directory.appendingPathComponent("corrupt.png")
        model.export(to: url)
        try await waitUntil { !model.isExporting }
        guard case let .finished(_, missing, failure) = model.exportActivity else {
            return XCTFail("export did not finish: \(model.exportActivity)")
        }
        XCTAssertEqual(missing, preview.missingFrames)
        XCTAssertNotNil(failure)
    }
}
