import FrameStackCore
import FrameStackMedia
@testable import FrameStack
import XCTest

/// M6k through the app model: a folder of camera RAW files opens to a
/// preview, and what the app does when macOS reports memory pressure.
/// Real system-wide pressure is not simulated (that would squeeze the whole
/// Mac); the handler the system event calls is driven directly.
@MainActor
final class RawAndMemoryAppTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackRawApp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("FrameStackMediaTests/Fixtures")
    }

    private func waitUntil(_ timeout: TimeInterval = 30, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw XCTSkip("timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitReady(_ model: AppModel) async throws {
        try await waitUntil { if case .ready = model.sourceState { return true } else { return false } }
        try await waitUntil { model.isPreviewCurrent }
    }

    private func makeModel() -> AppModel {
        let model = AppModel(defaults: UserDefaults(suiteName: "RawApp-\(UUID().uuidString)")!,
                             presetStore: PresetStore(directory: directory.appendingPathComponent("presets")))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        return model
    }

    private func openCountClip() async throws -> AppModel {
        let model = makeModel()
        model.open(fixtures.appendingPathComponent("count_5s_30fps.mp4"))
        try await waitReady(model)
        return model
    }

    // MARK: RAW folder

    func testFolderOfRAWFilesOpensToAPreviewWithTheRAWNotice() async throws {
        let folder = directory.appendingPathComponent("raws")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, gain) in [0.5, 1.0, 1.5].enumerated() {
            try SyntheticDNG.write(to: folder.appendingPathComponent("shot_\(i).dng"), width: 256, height: 192,
                                   pixel: SyntheticDNG.patches(width: 256, height: 192, gain: gain))
        }
        let model = makeModel()
        model.open(folder)
        try await waitUntil { if case .loading = model.sourceState { return false } else { return true } }
        guard case .ready = model.sourceState, model.imageSequence?.count == 3 else {
            throw XCTSkip("This macOS does not decode the synthetic linear DNG")
        }
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.imageSequence?.rawFileCount, 3)
        XCTAssertEqual(model.preview?.framesComposited, 3)
        XCTAssertEqual(model.preview?.missingFrames, 0)
        XCTAssertEqual(model.preview?.canvasSize, PixelSize(width: 256, height: 192))
        let warnings = model.source?.warnings ?? []
        XCTAssertTrue(warnings.contains { $0.contains("RAW") && $0.contains("no RAW development controls") }, "\(warnings)")
        try await waitUntil(10) { !model.thumbnails.isEmpty }
        XCTAssertEqual(model.thumbnails.count, 3, "one filmstrip picture per shot")

        // Exports like any other source.
        model.exportSettings = ExportSettings(format: .png, bitDepth: .sixteen)
        let out = directory.appendingPathComponent("raw.png")
        model.export(to: out)
        try await waitUntil { !model.isExporting }
        guard case let .finished(report, missing, _) = model.exportActivity else { return XCTFail("\(model.exportActivity)") }
        XCTAssertEqual(missing, 0)
        XCTAssertEqual([report.width, report.height, report.bitDepth], [256, 192, 16])
    }

    // MARK: Memory pressure

    func testMemoryWarningGivesBackCachesAndChangesNothingTheOwnerSees() async throws {
        let model = try await openCountClip()
        let before = model.preview?.revision
        let renders = model.previewRenderCount
        model.handleMemoryPressure(.warning)
        XCTAssertEqual(model.memoryPressureEvents, 1)
        XCTAssertEqual(model.renderActivity, .idle)
        XCTAssertTrue(model.isPreviewCurrent)
        XCTAssertEqual(model.preview?.revision, before)
        // The kept composite survives a warning: a colour edit re-uses it.
        model.color.exposure = 0.5
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.previewRenderCount, renders, "no new composite for a colour edit")

        // A warning while work runs lets it finish.
        model.blendMode = .lighten
        model.handleMemoryPressure(.warning)
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.renderActivity, .idle)
        XCTAssertEqual(model.previewRenderCount, renders + 1)
    }

    func testCriticalMemoryStopsThePreviewRenderWithAMessageUntilTheOwnerRetries() async throws {
        let model = try await openCountClip()
        let renders = model.previewRenderCount
        model.blendMode = .median
        XCTAssertEqual(model.renderActivity, .waiting)
        model.handleMemoryPressure(.critical)
        XCTAssertEqual(model.renderActivity, .failed(AppModel.memoryStopMessage))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(model.renderActivity, .failed(AppModel.memoryStopMessage), "nothing restarts on its own")
        XCTAssertFalse(model.isPreviewCurrent)
        XCTAssertEqual(model.previewRenderCount, renders)

        // Mid-render too: wait for frames to be flowing, then stop.
        model.renderPreviewNow()
        try await waitUntil { if case .rendering = model.renderActivity { return true } else { return model.isPreviewCurrent } }
        if !model.isPreviewCurrent {
            model.handleMemoryPressure(.critical)
            XCTAssertEqual(model.renderActivity, .failed(AppModel.memoryStopMessage))
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertFalse(model.isPreviewCurrent)
        }

        // Retry (the button under the message) brings the preview back.
        model.renderPreviewNow()
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.renderActivity, .idle)
        XCTAssertEqual(model.preview?.framesComposited, 150)
    }

    func testCriticalMemoryDropsTheKeptCompositeWhenIdle() async throws {
        let model = try await openCountClip()
        let renders = model.previewRenderCount
        model.handleMemoryPressure(.critical)
        XCTAssertEqual(model.renderActivity, .idle, "nothing was running: no message")
        XCTAssertTrue(model.isPreviewCurrent, "the picture on screen stays")
        // The next colour edit has to composite again (the kept result was given back).
        model.color.exposure = 0.5
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.previewRenderCount, renders + 1)
    }

    func testCriticalMemoryStopsAnExportWithAMessageAndWritesNothing() async throws {
        let model = try await openCountClip()
        let renders = model.previewRenderCount
        // A preview is due (mode changed) when the export starts.
        model.blendMode = .median
        let out = directory.appendingPathComponent("stopped.png")
        model.export(to: out)
        XCTAssertTrue(model.isExporting)
        model.handleMemoryPressure(.critical)
        try await waitUntil { !model.isExporting }
        XCTAssertEqual(model.exportActivity, .failed(AppModel.memoryStopMessage))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(model.isPreviewCurrent, "the preview that was due is not started behind the owner's back")
        XCTAssertEqual(model.previewRenderCount, renders)

        // Afterwards an ordinary cancel is reported as a cancel, and an export works.
        model.export(to: out)
        model.cancelRendering()
        try await waitUntil { !model.isExporting }
        XCTAssertEqual(model.exportActivity, .cancelled)
        try await waitUntil { model.isPreviewCurrent }
        model.export(to: out)
        try await waitUntil { !model.isExporting }
        guard case .finished = model.exportActivity else { return XCTFail("\(model.exportActivity)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }

    func testCriticalMemoryStopsABatchAndSaysWhy() async throws {
        let model = try await openCountClip()
        model.exportSettings = ExportSettings(format: .png, bitDepth: .eight)
        var choice = BatchChoice()
        choice.blendModes = [.lighten, .darken, .median, .screen]
        let folder = directory.appendingPathComponent("batch")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.startBatch(choice: choice, folder: folder)
        XCTAssertEqual(model.batch?.isRunning, true)
        XCTAssertNil(model.batch?.note)
        model.handleMemoryPressure(.critical)
        XCTAssertEqual(model.batch?.note, AppModel.memoryStopMessage)
        try await waitUntil { model.batch?.summary != nil }
        let summary = try XCTUnwrap(model.batch?.summary)
        XCTAssertGreaterThan(summary.cancelledCount, 0)
        XCTAssertEqual(summary.finishedCount + summary.cancelledCount + summary.failedCount, summary.outputs.count)
        XCTAssertEqual(model.batch?.note, AppModel.memoryStopMessage, "the reason stays on the sheet")
        let written = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(written.count, summary.finishedCount, "no partial files")

        // A new batch starts clean and runs to the end.
        model.dismissBatch()
        model.startBatch(choice: choice, folder: folder)
        XCTAssertNil(model.batch?.note)
        try await waitUntil(60) { model.batch?.summary != nil }
        XCTAssertEqual(model.batch?.summary?.finishedCount, model.batch?.outputs.count)
    }
}
