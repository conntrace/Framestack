import FrameStackCore
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
