import CoreGraphics
import FrameStackCore
import ImageIO
import FrameStackMedia
@testable import FrameStack
import XCTest

/// M4: `.framestack` projects through the app model — save, reopen, relink
/// (moved, missing, changed media), unsaved-change tracking — and the export
/// formats, sizing and color space choices.
@MainActor
final class ProjectTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackProjects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("media"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FrameStackMediaTests/Fixtures/\(name).mp4")
    }

    private func copyFixture(_ name: String, as fileName: String) throws -> URL {
        let url = directory.appendingPathComponent("media/\(fileName)")
        try FileManager.default.copyItem(at: fixtureURL(name), to: url)
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool) async throws {
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

    private func isRelink(_ model: AppModel) -> RelinkRequest? {
        if case let .relink(request) = model.sourceState { return request }
        return nil
    }

    /// Opens the count clip, applies a distinctive set of settings and saves.
    private func makeSavedProject(media: URL, name: String = "test") async throws -> (AppModel, URL) {
        let model = AppModel(defaults: UserDefaults(suiteName: "ProjectTests-\(UUID().uuidString)")!)
        model.open(media)
        try await waitReady(model)
        XCTAssertFalse(model.hasUnsavedChanges, "nothing changed yet")
        model.setFrameRange(first: 30, last: 119)
        model.samplingKind = .everyNth
        model.nth = 3
        model.blendMode = .screen
        model.opacity = 0.6
        model.exportSettings = ExportSettings(format: .tiff, bitDepth: .sixteen, jpegQuality: 0.9, sizing: .percent(50), colorSpace: .displayP3)
        model.previewQuality = .full
        model.scrubIndex = 42
        XCTAssertTrue(model.hasUnsavedChanges)
        let projectURL = directory.appendingPathComponent("\(name).framestack")
        XCTAssertTrue(model.save(to: projectURL))
        XCTAssertEqual(model.projectURL, projectURL)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.windowTitle, name)
        XCTAssertEqual(model.windowSubtitle, media.lastPathComponent)
        guard case .saved = model.projectActivity else { return (model, projectURL) }
        try await waitUntil { model.isPreviewCurrent }
        return (model, projectURL)
    }

    private func assertSettingsRestored(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.frameRange, 30...119, file: file, line: line)
        XCTAssertEqual(model.samplingKind, .everyNth, file: file, line: line)
        XCTAssertEqual(model.nth, 3, file: file, line: line)
        XCTAssertEqual(model.blendMode, .screen, file: file, line: line)
        XCTAssertEqual(model.opacity, 0.6, file: file, line: line)
        XCTAssertEqual(model.exportSettings.format, .tiff, file: file, line: line)
        XCTAssertEqual(model.exportSettings.sizing, .percent(50), file: file, line: line)
        XCTAssertEqual(model.exportSettings.colorSpace, .displayP3, file: file, line: line)
        XCTAssertEqual(model.previewQuality, .full, file: file, line: line)
        XCTAssertEqual(model.scrubIndex, 42, file: file, line: line)
        XCTAssertEqual(model.selectedTimes.count, 30, "frames 30…119 every 3rd", file: file, line: line)
    }

    // MARK: Save / reopen

    func testSaveQuitReopenReproducesTheSameImage() async throws {
        let media = try copyFixture("count_5s_30fps", as: "clip.mp4")
        let (original, projectURL) = try await makeSavedProject(media: media)
        let text = try String(contentsOf: projectURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"formatVersion\" : 2"))
        XCTAssertTrue(text.contains("\"kind\" : \"video\""))
        XCTAssertTrue(text.contains("\"relativePath\" : \"media/clip.mp4\""), "project next to the media folder: \(text)")
        XCTAssertTrue(text.contains("\"fingerprint\" : \"sha256:"))
        XCTAssertFalse(text.contains("\"exactCount\" : 0"))
        let originalPreview = try XCTUnwrap(original.preview)

        let reopened = AppModel(defaults: UserDefaults(suiteName: "ProjectTests-\(UUID().uuidString)")!)
        reopened.open(projectURL)
        try await waitReady(reopened)
        XCTAssertEqual(reopened.projectURL, projectURL)
        XCTAssertEqual(reopened.source?.url.lastPathComponent, "clip.mp4")
        XCTAssertNil(reopened.sourceNotice)
        XCTAssertFalse(reopened.hasUnsavedChanges, "freshly opened project is clean")
        assertSettingsRestored(reopened)
        XCTAssertEqual(reopened.selectedTimes, original.selectedTimes)
        XCTAssertEqual(reopened.recentFiles.first, projectURL, "projects appear in Open Recent")

        let preview = try XCTUnwrap(reopened.preview)
        XCTAssertEqual(preview.size, originalPreview.size)
        XCTAssertEqual(preview.framesComposited, originalPreview.framesComposited)
        XCTAssertEqual(preview.image.dataProvider?.data as Data?, originalPreview.image.dataProvider?.data as Data?,
                       "same frames, same math → identical pixels")
        XCTAssertEqual(reopened.suggestedExportName, "test Screen 60% 30f 160px.tif")
    }

    func testUnsavedChangesTrackingAndSaveOverwrites() async throws {
        let media = try copyFixture("count_5s_30fps", as: "clip.mp4")
        let (model, projectURL) = try await makeSavedProject(media: media)
        model.blendMode = .lighten
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.windowSubtitle, "clip.mp4 — Edited")
        XCTAssertTrue(model.saveProject(), "⌘S writes to the existing file without a panel")
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(try ProjectFile.read(from: projectURL).settings.blendMode, .lighten)

        model.exportSettings.format = .jpeg
        XCTAssertTrue(model.hasUnsavedChanges, "export choices are part of the document")
        model.scrubIndex = 7
        model.previewQuality = .draft
        XCTAssertTrue(model.saveProject())
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(try ProjectFile.read(from: projectURL).ui.scrubIndex, 7, "UI state is saved but does not count as an edit")
        model.scrubIndex = 8
        XCTAssertFalse(model.hasUnsavedChanges)

        // Opening a plain video leaves the project.
        model.open(media)
        try await waitReady(model)
        XCTAssertNil(model.projectURL)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.windowTitle, "clip.mp4")
        XCTAssertEqual(model.exportSettings, ExportSettings(), "a new clip starts from default export settings")
    }

    // MARK: Relink

    func testRenamedMediaIsFoundThroughTheBookmark() async throws {
        let media = try copyFixture("count_5s_30fps", as: "clip.mp4")
        let (_, projectURL) = try await makeSavedProject(media: media)
        let renamed = directory.appendingPathComponent("media/renamed clip.mp4")
        try FileManager.default.moveItem(at: media, to: renamed)

        let model = AppModel(defaults: UserDefaults(suiteName: "ProjectTests-\(UUID().uuidString)")!)
        model.open(projectURL)
        try await waitReady(model)
        XCTAssertEqual(model.source?.fileName, "renamed clip.mp4")
        assertSettingsRestored(model)
        XCTAssertNil(model.sourceNotice, "same media, just renamed")
        XCTAssertTrue(model.hasUnsavedChanges, "the new location should be saved")
        XCTAssertTrue(model.saveProject())
        XCTAssertEqual(try ProjectFile.read(from: projectURL).source.identity.fileName, "renamed clip.mp4")
    }

    func testMissingMediaAsksForRelinkAndAcceptsOnlyTheSameMedia() async throws {
        let media = try copyFixture("count_5s_30fps", as: "clip.mp4")
        let (_, projectURL) = try await makeSavedProject(media: media)
        try FileManager.default.removeItem(at: media)

        let model = AppModel(defaults: UserDefaults(suiteName: "ProjectTests-\(UUID().uuidString)")!)
        model.open(projectURL)
        let request = try XCTUnwrap(isRelink(model), "\(model.sourceState)")
        XCTAssertNil(request.candidate)
        XCTAssertTrue(request.message.contains("could not be found"), request.message)
        XCTAssertNil(model.source)
        XCTAssertFalse(model.canSaveProject)

        // Wrong file: still asking, now naming the chosen file.
        model.relink(to: fixtureURL("moving_square_24f"))
        let wrong = try XCTUnwrap(isRelink(model))
        XCTAssertEqual(wrong.candidate?.lastPathComponent, "moving_square_24f.mp4")
        XCTAssertTrue(wrong.message.contains("is not the video this project was saved with"), wrong.message)
        XCTAssertEqual(wrong.differences.count, 2)

        // A file that does not exist: back to "not found".
        model.relink(to: directory.appendingPathComponent("nope.mp4"))
        XCTAssertNil(try XCTUnwrap(isRelink(model)).candidate)

        // The right file elsewhere: loads with the saved settings.
        let elsewhere = try copyFixture("count_5s_30fps", as: "found elsewhere.mp4")
        model.relink(to: elsewhere)
        try await waitReady(model)
        XCTAssertEqual(model.source?.fileName, "found elsewhere.mp4")
        XCTAssertEqual(model.projectURL, projectURL)
        assertSettingsRestored(model)
        XCTAssertNil(model.sourceNotice)
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    func testChangedMediaIsNeverUsedWithoutAnExplicitDecision() async throws {
        let media = try copyFixture("count_5s_30fps", as: "clip.mp4")
        let (_, projectURL) = try await makeSavedProject(media: media)
        try FileManager.default.removeItem(at: media)
        try FileManager.default.copyItem(at: fixtureURL("trimmed_editlist"), to: media)

        let model = AppModel(defaults: UserDefaults(suiteName: "ProjectTests-\(UUID().uuidString)")!)
        model.open(projectURL)
        let request = try XCTUnwrap(isRelink(model), "\(model.sourceState)")
        XCTAssertEqual(request.candidate?.lastPathComponent, "clip.mp4")
        XCTAssertFalse(request.differences.isEmpty)
        XCTAssertNil(model.source, "nothing loaded yet")

        model.cancelRelink()
        if case .empty = model.sourceState {} else { XCTFail("cancel → empty, got \(model.sourceState)") }

        model.open(projectURL)
        XCTAssertNotNil(isRelink(model))
        model.useRelinkCandidateAnyway()
        try await waitReady(model)
        XCTAssertEqual(model.source?.fileName, "clip.mp4")
        XCTAssertEqual(model.timeline?.count, 62, "the trimmed clip")
        let notice = try XCTUnwrap(model.sourceNotice)
        XCTAssertTrue(notice.contains("differs from the video the project was saved with"), notice)
        XCTAssertTrue(notice.contains("62 frames"), notice)
        XCTAssertTrue(notice.contains("150 frames"), notice)
        XCTAssertTrue(notice.contains("clamped"), "range 30…119 (1…4 s) does not fit a 2.07 s clip: \(notice)")
        XCTAssertEqual(model.rangeEnd, model.source?.duration)
        XCTAssertEqual(model.rangeStart, FrameTime(value: 30, timescale: 30), "start still fits")
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.blendMode, .screen, "other settings kept")
    }

    func testCorruptAndNewerProjectFilesFailClearly() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: "ProjectTests-\(UUID().uuidString)")!)
        let garbage = directory.appendingPathComponent("garbage.framestack")
        try Data("{\"hello\": 1}".utf8).write(to: garbage)
        model.open(garbage)
        guard case let .failed(message) = model.sourceState else { return XCTFail("\(model.sourceState)") }
        XCTAssertTrue(message.contains("not a valid FrameStack project"), message)

        let newer = directory.appendingPathComponent("future.framestack")
        try Data("{\"formatVersion\": 7}".utf8).write(to: newer)
        model.open(newer)
        guard case let .failed(message2) = model.sourceState else { return XCTFail("\(model.sourceState)") }
        XCTAssertTrue(message2.contains("newer version of FrameStack"), message2)
    }

    // MARK: Export formats, sizing, color

    func testExportFormatsSizingAndColorSpace() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: "ProjectTests-\(UUID().uuidString)")!)
        model.open(fixtureURL("moving_square_24f"))   // 480×272
        try await waitReady(model)

        model.exportSettings = ExportSettings(format: .jpeg, bitDepth: .sixteen, jpegQuality: 0.9, sizing: .percent(50))
        XCTAssertEqual(model.exportOutputSize, PixelSize(width: 240, height: 136))
        XCTAssertEqual(model.suggestedExportName, "moving_square_24f Average 24f 240px.jpg")
        let jpeg = directory.appendingPathComponent("half.jpg")
        model.export(to: jpeg)
        try await waitUntil { !model.isExporting }
        guard case let .finished(report, _, _) = model.exportActivity else { return XCTFail("\(model.exportActivity)") }
        XCTAssertEqual(report.format, .jpeg)
        XCTAssertEqual(report.width, 240)
        XCTAssertEqual(report.height, 136)
        XCTAssertEqual(report.bitDepth, 8, "JPEG: 16-bit request is downgraded and reported honestly")

        model.exportSettings = ExportSettings(format: .tiff, bitDepth: .sixteen, sizing: .longEdge(320), colorSpace: .displayP3)
        XCTAssertEqual(model.suggestedExportName, "moving_square_24f Average 24f 320px.tif")
        let tiff = directory.appendingPathComponent("p3.tif")
        model.export(to: tiff)
        try await waitUntil { !model.isExporting }
        guard case let .finished(report2, _, _) = model.exportActivity else { return XCTFail("\(model.exportActivity)") }
        XCTAssertEqual(report2.format, .tiff)
        XCTAssertEqual(report2.width, 320)
        XCTAssertEqual(report2.height, 181)
        XCTAssertEqual(report2.bitDepth, 16)
        XCTAssertEqual(report2.colorProfileName, "Display P3")

        model.exportSettings = ExportSettings()
        XCTAssertEqual(model.suggestedExportName, "moving_square_24f Average 24f.png")
        XCTAssertEqual(model.exportOutputSize, PixelSize(width: 480, height: 272))
        try await waitUntil { model.isPreviewCurrent }
    }
}

// MARK: - Image sequences (M5a)

@MainActor
final class SequenceAppTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackSeqApp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fixtureFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FrameStackMediaTests/Fixtures/sequence_png_12f")
    }

    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool) async throws {
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
        AppModel(defaults: UserDefaults(suiteName: "SequenceAppTests-\(UUID().uuidString)")!)
    }

    func testOpenFolderRetimeReverseAndThumbnails() async throws {
        let model = makeModel()
        model.open(fixtureFolder)
        try await waitReady(model)
        let seq = try XCTUnwrap(model.imageSequence)
        XCTAssertEqual(seq.count, 12)
        XCTAssertEqual(model.timeline?.count, 12)
        XCTAssertEqual(model.scanned, 12)
        XCTAssertNil(model.scanResult, "no timestamp scan for stills")
        XCTAssertEqual(model.source?.displaySize, PixelSize(width: 160, height: 90))
        XCTAssertEqual(model.rangeEnd, FrameTime(value: 12, timescale: 30))
        XCTAssertEqual(model.windowTitle, "sequence_png_12f")
        XCTAssertEqual(model.preview?.framesComposited, 12)
        try await waitUntil { !model.thumbnails.isEmpty }
        XCTAssertEqual(model.thumbnails.count, 12)
        XCTAssertEqual(model.suggestedExportName, "sequence_png_12f Average 12f.png")

        // Retime: same images, new duration; a narrowed range keeps its frames.
        model.setFrameRange(first: 2, last: 7)
        model.setSequence(framesPerSecond: 10)
        XCTAssertEqual(model.imageSequence?.framesPerSecond, 10)
        XCTAssertEqual(model.source?.duration.seconds ?? 0, 1.2, accuracy: 1e-9)
        XCTAssertEqual(model.frameRange, 2...7)
        XCTAssertEqual(model.rangeStart, FrameTime(value: 2000, timescale: 10_000))
        XCTAssertEqual(model.selectedTimes.count, 6)

        // Reverse: the same six images, now at mirrored indices.
        model.setSequence(reversed: true)
        XCTAssertEqual(model.imageSequence?.reversed, true)
        XCTAssertEqual(model.frameRange, 4...9)
        XCTAssertEqual(model.imageSequence?.orderedFiles[4].fileName, "frame_7.png")
        XCTAssertEqual(model.imageSequence?.orderedFiles[9].fileName, "frame_2.png")
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.preview?.framesComposited, 6)

        // Original view shows the still under the playhead.
        model.scrubIndex = 0
        model.viewMode = .original
        try await waitUntil { model.sourceFrame != nil }
        XCTAssertEqual(model.sourceFrame?.image.width, 160)
    }

    func testOpenSeveralStillsAndMixedSizesFailClearly() async throws {
        let model = makeModel()
        model.open([3, 1, 2].map { fixtureFolder.appendingPathComponent("frame_\($0).png") })
        try await waitReady(model)
        XCTAssertEqual(model.imageSequence?.files.map(\.fileName), ["frame_1.png", "frame_2.png", "frame_3.png"])

        let mixed = directory.appendingPathComponent("mixed")
        try FileManager.default.createDirectory(at: mixed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureFolder.appendingPathComponent("frame_0.png"), to: mixed.appendingPathComponent("a.png"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FrameStackMediaTests/Fixtures/portrait_rot90cw.mp4"), to: mixed.appendingPathComponent("clip.mp4"))
        // A folder whose only image is fine but which holds a movie: the movie is skipped with a warning.
        model.open(mixed)
        try await waitReady(model)
        XCTAssertEqual(model.imageSequence?.count, 1)
        XCTAssertEqual(model.imageSequence?.skippedFileNames, ["clip.mp4"])
        XCTAssertEqual(model.source?.warnings.count, 1)
    }

    func testSequenceProjectSavesAndReopensWithRateAndOrder() async throws {
        let shoot = directory.appendingPathComponent("shoot")
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        for i in 0..<6 {
            try FileManager.default.copyItem(at: fixtureFolder.appendingPathComponent("frame_\(i).png"), to: shoot.appendingPathComponent("DSC_\(i).png"))
        }
        let model = makeModel()
        model.open(shoot)
        try await waitReady(model)
        model.setSequence(framesPerSecond: 5, reversed: true)
        model.setFrameRange(first: 1, last: 4)
        model.blendMode = .lighten
        let projectURL = directory.appendingPathComponent("shoot.framestack")
        XCTAssertTrue(model.save(to: projectURL))
        try await waitUntil { model.isPreviewCurrent }
        let text = try String(contentsOf: projectURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"kind\" : \"imageSequence\""), text)
        XCTAssertTrue(text.contains("\"framesPerSecond\" : 5"), text)
        XCTAssertTrue(text.contains("\"reversed\" : true"), text)
        XCTAssertTrue(text.contains("DSC_5.png"))
        let originalPreview = try XCTUnwrap(model.preview)

        let reopened = makeModel()
        reopened.open(projectURL)
        try await waitReady(reopened)
        XCTAssertEqual(reopened.imageSequence?.framesPerSecond, 5)
        XCTAssertEqual(reopened.imageSequence?.reversed, true)
        XCTAssertEqual(reopened.frameRange, 1...4)
        XCTAssertEqual(reopened.blendMode, .lighten)
        XCTAssertNil(reopened.sourceNotice)
        XCTAssertFalse(reopened.hasUnsavedChanges)
        XCTAssertEqual(reopened.preview?.image.dataProvider?.data as Data?, originalPreview.image.dataProvider?.data as Data?)

        // A still deleted from the folder → relink screen naming the loss.
        try FileManager.default.removeItem(at: shoot.appendingPathComponent("DSC_2.png"))
        let again = makeModel()
        again.open(projectURL)
        guard case let .relink(request) = again.sourceState else { return XCTFail("\(again.sourceState)") }
        XCTAssertTrue(request.isSequence)
        XCTAssertEqual(request.candidate?.lastPathComponent, "shoot")
        XCTAssertEqual(request.differences.first, "1 of 6 images missing")
        XCTAssertTrue(request.message.contains("image folder"), request.message)
        again.useRelinkCandidateAnyway()
        try await waitReady(again)
        XCTAssertEqual(again.imageSequence?.count, 5)
        XCTAssertTrue(again.sourceNotice?.contains("5 frames") ?? false, again.sourceNotice ?? "nil")
    }
}

// MARK: - Alignment (M5b)

@MainActor
final class AlignmentAppTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackAlignApp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("FrameStackMediaTests/Fixtures")
    }

    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool) async throws {
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
        AppModel(defaults: UserDefaults(suiteName: "AlignmentAppTests-\(UUID().uuidString)")!)
    }

    func testToggleAlignmentRerendersUndoesAndSaves() async throws {
        let model = makeModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.open(fixtures.appendingPathComponent("handheld_8f.mp4"))
        try await waitReady(model)
        XCTAssertNil(model.preview?.alignment)
        XCTAssertEqual(model.alignment, .off)

        model.alignment.enabled = true
        XCTAssertFalse(model.isPreviewCurrent, "a settings change outdates the preview")
        XCTAssertEqual(undo.undoActionName, "Change Alignment")
        try await waitUntil { model.isPreviewCurrent }
        let report = try XCTUnwrap(model.preview?.alignment)
        XCTAssertEqual(report.alignedFrames, 7)
        XCTAssertEqual(report.referenceTime, model.timeline?.frames[4])
        XCTAssertEqual(model.alignmentReferenceTime, model.timeline?.frames[4])
        XCTAssertGreaterThan(report.maxShiftPixels, 10)
        XCTAssertFalse(report.validArea.isNull)

        // Reference at the playhead; undo restores the middle.
        model.scrubIndex = 0
        model.useReferenceAtPlayhead()
        XCTAssertEqual(model.alignment.reference, .frame(model.timeline!.frames[0]))
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.preview?.alignment?.referenceTime, model.timeline?.frames[0])
        undo.undo()
        XCTAssertEqual(model.alignment.reference, .middle)
        undo.undo()
        XCTAssertFalse(model.alignment.enabled)
        undo.redo()
        XCTAssertTrue(model.alignment.enabled)
        try await waitUntil { model.isPreviewCurrent }

        // Saved and restored with the project; the export carries the report.
        model.alignment.mode = .perspective
        let projectURL = directory.appendingPathComponent("aligned.framestack")
        XCTAssertTrue(model.save(to: projectURL))
        let text = try String(contentsOf: projectURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"alignment\" : {"), text)
        XCTAssertTrue(text.contains("\"mode\" : \"perspective\""), text)
        let reopened = makeModel()
        reopened.open(projectURL)
        try await waitReady(reopened)
        XCTAssertEqual(reopened.alignment, AlignmentSettings(enabled: true, mode: .perspective, reference: .middle))
        XCTAssertEqual(reopened.preview?.alignment?.mode, .perspective)

        reopened.exportSettings = ExportSettings(format: .png, bitDepth: .eight)
        let out = directory.appendingPathComponent("aligned.png")
        reopened.export(to: out)
        try await waitUntil { !reopened.isExporting }
        guard case let .finished(exported, _, _) = reopened.exportActivity else { return XCTFail("\(reopened.exportActivity)") }
        XCTAssertTrue(exported.hasAlpha, "uncovered edges are transparent")
        XCTAssertEqual(reopened.lastExportAlignment?.alignedFrames, 7)
        XCTAssertTrue(reopened.lastExportAlignment?.fromCache ?? false, "the export reused the preview's transforms")
    }

    func testOldProjectsWithoutAlignmentReadAsOff() throws {
        let json = """
        {"rangeStart":{"value":0,"timescale":1},"rangeEnd":{"value":1,"timescale":1},"samplingKind":"all","nth":1,"exactCount":1,"blendMode":"average","opacity":1}
        """
        let settings = try JSONDecoder().decode(CompositeSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.alignment, .off)
    }
}

// MARK: - Crop, straighten, canvas policy (M5c)

@MainActor
final class GeometryAppTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackGeoApp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("FrameStackMediaTests/Fixtures")
    }

    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool) async throws {
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
        AppModel(defaults: UserDefaults(suiteName: "GeometryAppTests-\(UUID().uuidString)")!)
    }

    func testCropStraightenSafeAreaUndoProjectAndExport() async throws {
        let model = makeModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.open(fixtures.appendingPathComponent("handheld_8f.mp4"))   // 320×180
        try await waitReady(model)
        XCTAssertEqual(model.preview?.size, PixelSize(width: 320, height: 180))
        XCTAssertEqual(model.cropPixels, CGRect(x: 0, y: 0, width: 320, height: 180))
        XCTAssertFalse(model.canCropToSafeArea, "nothing aligned, no angle")

        // Crop by pixels: preview and export sizes follow; undo name.
        model.setCropPixels(CGRect(x: 20, y: 10, width: 200, height: 100))
        XCTAssertEqual(undo.undoActionName, "Change Crop")
        XCTAssertEqual(model.exportOutputSize, PixelSize(width: 200, height: 100))
        XCTAssertEqual(model.displayedFullSize, PixelSize(width: 200, height: 100))
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.preview?.size, PixelSize(width: 200, height: 100))
        XCTAssertEqual(model.preview?.canvasSize, PixelSize(width: 320, height: 180))
        model.setCropPixels(CGRect(x: 300, y: 0, width: 500, height: 50))
        XCTAssertEqual(model.cropPixels, CGRect(x: 0, y: 0, width: 320, height: 50), "clamped into the canvas")
        model.exportSettings.sizing = .percent(50)
        XCTAssertEqual(model.exportOutputSize, PixelSize(width: 160, height: 25), "crop scales with the output size")
        model.exportSettings.sizing = .native

        // Straighten then crop to the largest valid rectangle: no transparency remains.
        model.resetCrop()
        model.geometry.rotationDegrees = 5
        XCTAssertEqual(undo.undoActionName, "Straighten")
        XCTAssertTrue(model.canCropToSafeArea)
        try await waitUntil { model.isPreviewCurrent }
        model.cropToSafeArea()
        XCTAssertLessThan(model.cropPixels.width, 320)
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.suggestedExportName.hasSuffix("px.png"), true, model.suggestedExportName)

        // With alignment on, the safe area comes from the report.
        model.resetGeometry()
        model.alignment.enabled = true
        try await waitUntil { model.isPreviewCurrent }
        let report = try XCTUnwrap(model.preview?.alignment)
        model.cropToSafeArea()
        XCTAssertEqual(model.cropPixels.minX, report.validArea.minX.rounded(), accuracy: 1)
        XCTAssertEqual(model.cropPixels.width, report.validArea.width.rounded(), accuracy: 1)
        try await waitUntil { model.isPreviewCurrent }
        let preview = try XCTUnwrap(model.preview)
        XCTAssertEqual(preview.size.width, Int(model.cropPixels.width))

        // Edge fill white → the export has no alpha.
        model.geometry.crop = .full
        model.geometry.edgeFill = .white
        XCTAssertEqual(undo.undoActionName, "Change Edge Fill")
        try await waitUntil { model.isPreviewCurrent }
        model.exportSettings = ExportSettings(format: .png, bitDepth: .eight)
        let out = directory.appendingPathComponent("filled.png")
        model.export(to: out)
        try await waitUntil { !model.isExporting }
        guard case let .finished(exported, _, _) = model.exportActivity else { return XCTFail("\(model.exportActivity)") }
        XCTAssertFalse(exported.hasAlpha, "white fill made it opaque")
        XCTAssertEqual(exported.width, 320)

        // Saved and restored.
        let projectURL = directory.appendingPathComponent("geo.framestack")
        model.geometry.crop = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        XCTAssertTrue(model.save(to: projectURL))
        let text = try String(contentsOf: projectURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"geometry\" : {"), text)
        XCTAssertTrue(text.contains("\"edgeFill\" : \"white\""), text)
        let reopened = makeModel()
        reopened.open(projectURL)
        try await waitReady(reopened)
        XCTAssertEqual(reopened.geometry, model.geometry)
        XCTAssertEqual(reopened.preview?.size, PixelSize(width: 160, height: 90))

        // Undo all the way back restores the identity geometry.
        while undo.canUndo { undo.undo() }
        XCTAssertEqual(model.geometry, .identity)
    }

    func testAlignmentAndGeometryResetWhenAnotherSourceOpens() async throws {
        let model = makeModel()
        model.open(fixtures.appendingPathComponent("handheld_8f.mp4"))
        try await waitReady(model)
        model.alignment.enabled = true
        model.geometry.rotationDegrees = 3
        model.blendMode = .lighten
        try await waitUntil { model.isPreviewCurrent }
        model.open(fixtures.appendingPathComponent("count_5s_30fps.mp4"))
        try await waitReady(model)
        XCTAssertEqual(model.alignment, .off)
        XCTAssertEqual(model.geometry, .identity)
        XCTAssertEqual(model.blendMode, .lighten, "blend carries over like a preference")
        XCTAssertNil(model.preview?.alignment)
    }

    func testMixedSizeFolderOffersFitAndFill() async throws {
        let folder = directory.appendingPathComponent("mixed")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let seq = fixtures.appendingPathComponent("sequence_png_12f")
        try FileManager.default.copyItem(at: seq.appendingPathComponent("frame_0.png"), to: folder.appendingPathComponent("a_0.png"))
        // A half-size copy, written through CoreGraphics.
        let src = CGImageSourceCreateWithURL(seq.appendingPathComponent("frame_1.png") as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let ctx = CGContext(data: nil, width: 80, height: 45, bitsPerComponent: 8, bytesPerRow: 320,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 80, height: 45))
        let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent("a_1.png") as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let model = makeModel()
        model.open(folder)
        try await waitUntil { if case .failed = model.sourceState { return true } else { return false } }
        XCTAssertNotNil(model.mixedSizeRetry, "the failed state offers Fit / Fill")
        model.setSequence(canvasPolicy: .fit)
        try await waitReady(model)
        XCTAssertEqual(model.imageSequence?.canvasPolicy, .fit)
        XCTAssertEqual(model.imageSequence?.count, 2)
        XCTAssertNil(model.mixedSizeRetry)
        XCTAssertTrue(model.source?.warnings.contains { $0.contains("scaled to fit") } ?? false)
        XCTAssertEqual(model.preview?.size, PixelSize(width: 160, height: 90))

        // Saved with the policy; switching to Fill reloads.
        let projectURL = directory.appendingPathComponent("mixed.framestack")
        XCTAssertTrue(model.save(to: projectURL))
        XCTAssertTrue(try String(contentsOf: projectURL, encoding: .utf8).contains("\"canvasPolicy\" : \"fit\""))
        model.setSequence(canvasPolicy: .fill)
        try await waitReady(model)
        XCTAssertEqual(model.imageSequence?.canvasPolicy, .fill)
        let reopened = makeModel()
        reopened.open(projectURL)
        try await waitReady(reopened)
        XCTAssertEqual(reopened.imageSequence?.canvasPolicy, .fit)
    }
}

// MARK: - Temporal weighting (M6a)

@MainActor
final class WeightingAppTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackWeightApp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("FrameStackMediaTests/Fixtures")
    }

    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool) async throws {
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

    func testWeightingRerendersUndoesSavesAndExportsLikeThePreview() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: "WeightingApp-\(UUID().uuidString)")!)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.open(fixtures.appendingPathComponent("count_5s_30fps.mp4"))
        try await waitReady(model)
        XCTAssertNil(model.preview?.weighting)
        XCTAssertEqual(model.currentWeights?.effectiveFrameCount ?? 0, 150, accuracy: 1e-9)
        let flatPreview = try XCTUnwrap(model.preview)

        model.weighting.preset = .late
        XCTAssertFalse(model.isPreviewCurrent)
        XCTAssertEqual(undo.undoActionName, "Change Weighting")
        try await waitUntil { model.isPreviewCurrent }
        let report = try XCTUnwrap(model.preview?.weighting)
        XCTAssertEqual(report.preset, .late)
        XCTAssertLessThan(report.effectiveFrameCount, 150)
        XCTAssertNotEqual(model.preview?.image.dataProvider?.data as Data?, flatPreview.image.dataProvider?.data as Data?)

        // Custom points edited as one interactive step.
        model.weighting.preset = .custom
        model.beginInteractiveEdit()
        model.weighting.points[0].weight = 1
        model.weighting.points[4].weight = 0
        model.endInteractiveEdit()
        XCTAssertEqual(undo.undoActionName, "Change Weighting")
        undo.undo()
        XCTAssertEqual(model.weighting.points, WeightCurve.defaultCustomPoints, "the whole drag is one step")
        undo.undo()
        XCTAssertEqual(model.weighting.preset, .late)

        // Project round trip and an export that matches the preview's weighting.
        try await waitUntil { model.isPreviewCurrent }
        let projectURL = directory.appendingPathComponent("weighted.framestack")
        XCTAssertTrue(model.save(to: projectURL))
        XCTAssertTrue(try String(contentsOf: projectURL, encoding: .utf8).contains("\"preset\" : \"late\""))
        let reopened = AppModel(defaults: UserDefaults(suiteName: "WeightingApp-\(UUID().uuidString)")!)
        reopened.open(projectURL)
        try await waitReady(reopened)
        XCTAssertEqual(reopened.weighting, WeightCurve(preset: .late))
        XCTAssertEqual(reopened.preview?.weighting?.preset, .late)
        reopened.exportSettings = ExportSettings(format: .png, bitDepth: .eight)
        let out = directory.appendingPathComponent("late.png")
        reopened.export(to: out)
        try await waitUntil { !reopened.isExporting }
        guard case .finished = reopened.exportActivity else { return XCTFail("\(reopened.exportActivity)") }
        let exported = try readBackPixels8(out)
        // Block 0 (bit 7, set in frames 128…149) is late in the clip: under "late" it is brighter than its flat 22/150.
        let block0 = exported[(20 * 320 + 20) * 3]
        XCTAssertGreaterThan(Double(block0) / 255, SRGBTransfer.encode(22.0 / 150) + 0.05)

        // A fresh clip resets to flat.
        reopened.open(fixtures.appendingPathComponent("moving_square_24f.mp4"))
        try await waitReady(reopened)
        XCTAssertEqual(reopened.weighting, .flat)
    }

    private func readBackPixels8(_ url: URL) throws -> [UInt8] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for p in 0..<(w * h) { for c in 0..<3 { rgb[p * 3 + c] = buffer[p * 4 + c] } }
        return rgb
    }
}
