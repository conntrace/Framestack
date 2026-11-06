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
        XCTAssertTrue(text.contains("\"formatVersion\" : 1"))
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
