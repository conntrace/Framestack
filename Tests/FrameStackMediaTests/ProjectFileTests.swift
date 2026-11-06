import FrameStackCore
@testable import FrameStackMedia
import XCTest

final class ProjectFileTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackProject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("media"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Copies a fixture next to the project so moves/renames can be simulated.
    private func copyFixture(_ fixture: Fixture, as name: String) throws -> URL {
        let url = directory.appendingPathComponent("media/\(name)")
        try FileManager.default.copyItem(at: fixture.url, to: url)
        return url
    }

    private func sampleProject(media: URL, projectURL: URL) throws -> ProjectFile {
        let identity = try SourceIdentity.compute(for: media)
        let reference = SourceReference.make(
            url: media, identity: identity, duration: FrameTime(value: 5, timescale: 1),
            displaySize: PixelSize(width: 320, height: 180), frameCount: 150, projectURL: projectURL
        )
        let settings = CompositeSettings(
            rangeStart: FrameTime(value: 1, timescale: 1), rangeEnd: FrameTime(value: 4, timescale: 1),
            samplingKind: .exactCount, nth: 2, exactCount: 20, blendMode: .screen, opacity: 0.6
        )
        let export = ExportSettings(format: .jpeg, bitDepth: .eight, jpegQuality: 0.85, sizing: .percent(50), colorSpace: .displayP3)
        return ProjectFile(source: reference, settings: settings, export: export,
                           ui: ProjectFile.UIState(previewQuality: "Full", viewMode: "Original", scrubIndex: 42), writer: "test")
    }

    // MARK: Fingerprint

    func testFingerprintIsStableAcrossCopiesAndRenames() throws {
        let a = try copyFixture(.count, as: "a.mp4")
        let b = try copyFixture(.count, as: "renamed copy.mp4")
        let ia = try SourceIdentity.compute(for: a)
        let ib = try SourceIdentity.compute(for: b)
        XCTAssertEqual(ia.fingerprint, ib.fingerprint)
        XCTAssertTrue(ia.fingerprint.hasPrefix("sha256:"))
        XCTAssertEqual(ia.fileSizeBytes, ib.fileSizeBytes)
        XCTAssertEqual(ib.differences(from: ia), [], "a rename or copy is the same media")
        XCTAssertNotEqual(ia.fileName, ib.fileName)
    }

    func testFingerprintDetectsDifferentAndEditedFiles() throws {
        let count = try copyFixture(.count, as: "count.mp4")
        let other = try copyFixture(.movingSquare, as: "square.mp4")
        let saved = try SourceIdentity.compute(for: count)
        let differences = try SourceIdentity.compute(for: other).differences(from: saved)
        XCTAssertEqual(differences.count, 2, "size and contents: \(differences)")

        // Same size, one byte changed at the very end → fingerprint differs.
        let edited = try copyFixture(.count, as: "edited.mp4")
        let handle = try FileHandle(forWritingTo: edited)
        try handle.seek(toOffset: UInt64(saved.fileSizeBytes - 1))
        try handle.write(contentsOf: Data([0x5A]))
        try handle.close()
        let editedDifferences = try SourceIdentity.compute(for: edited).differences(from: saved)
        XCTAssertEqual(editedDifferences, ["contents differ (fingerprint)"])
    }

    // MARK: Document

    func testWriteReadRoundTripIsLossless() throws {
        let media = try copyFixture(.count, as: "clip.mp4")
        let projectURL = directory.appendingPathComponent("projects/test.framestack")
        let project = try sampleProject(media: media, projectURL: projectURL)
        try project.write(to: projectURL)

        let text = try String(contentsOf: projectURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"formatVersion\" : 1"), "human-readable JSON: \(text.prefix(200))")
        XCTAssertTrue(text.contains("\"relativePath\" : \"../media/clip.mp4\""), text)
        XCTAssertTrue(text.contains("\"blendMode\" : \"screen\""))

        let read = try ProjectFile.read(from: projectURL)
        XCTAssertEqual(read, project)
        XCTAssertEqual(read.source.relativePath, "../media/clip.mp4")
        XCTAssertEqual(read.export.sizing, .percent(50))
        XCTAssertEqual(read.ui.scrubIndex, 42)
    }

    func testReadRejectsMissingCorruptAndNewerFiles() throws {
        let missing = directory.appendingPathComponent("projects/none.framestack")
        XCTAssertThrowsError(try ProjectFile.read(from: missing)) { error in
            guard case .unreadable? = error as? ProjectError else { return XCTFail("\(error)") }
        }
        let garbage = directory.appendingPathComponent("projects/garbage.framestack")
        try Data("not json".utf8).write(to: garbage)
        XCTAssertThrowsError(try ProjectFile.read(from: garbage)) { error in
            guard case .corrupt? = error as? ProjectError else { return XCTFail("\(error)") }
        }
        let noVersion = directory.appendingPathComponent("projects/noversion.framestack")
        try Data("{\"settings\": {}}".utf8).write(to: noVersion)
        XCTAssertThrowsError(try ProjectFile.read(from: noVersion)) { error in
            guard case .corrupt? = error as? ProjectError else { return XCTFail("\(error)") }
        }
        let newer = directory.appendingPathComponent("projects/newer.framestack")
        try Data("{\"formatVersion\": 99}".utf8).write(to: newer)
        XCTAssertThrowsError(try ProjectFile.read(from: newer)) { error in
            XCTAssertEqual(error as? ProjectError, .newerFormat(path: newer.path, version: 99))
            XCTAssertTrue(error.localizedDescription.contains("newer version"), error.localizedDescription)
        }
        let truncated = directory.appendingPathComponent("projects/truncated.framestack")
        try Data("{\"formatVersion\": 1, \"settings\": {}}".utf8).write(to: truncated)
        XCTAssertThrowsError(try ProjectFile.read(from: truncated)) { error in
            guard case .corrupt? = error as? ProjectError else { return XCTFail("\(error)") }
        }
    }

    // MARK: Resolution

    func testResolvesUnmovedMedia() throws {
        let media = try copyFixture(.count, as: "clip.mp4")
        let projectURL = directory.appendingPathComponent("projects/p.framestack")
        let project = try sampleProject(media: media, projectURL: projectURL)
        XCTAssertEqual(resolvedPath(SourceLocator.resolve(project.source, projectURL: projectURL)), media.resolvingSymlinksInPath().path)
    }

    /// Bookmarks resolve `/var` to `/private/var`; compare canonical paths.
    private func resolvedPath(_ resolution: SourceResolution) -> String? {
        switch resolution {
        case let .found(url), let .changed(url, _): return url.resolvingSymlinksInPath().path
        case .missing: return nil
        }
    }

    func testResolvesRenamedMediaThroughTheBookmark() throws {
        let media = try copyFixture(.count, as: "clip.mp4")
        let projectURL = directory.appendingPathComponent("projects/p.framestack")
        let project = try sampleProject(media: media, projectURL: projectURL)
        let renamed = directory.appendingPathComponent("media/renamed.mp4")
        try FileManager.default.moveItem(at: media, to: renamed)
        XCTAssertEqual(resolvedPath(SourceLocator.resolve(project.source, projectURL: projectURL)), renamed.resolvingSymlinksInPath().path)
    }

    func testResolvesMediaMovedTogetherWithTheProjectThroughTheRelativePath() throws {
        let media = try copyFixture(.count, as: "clip.mp4")
        let projectURL = directory.appendingPathComponent("projects/p.framestack")
        var project = try sampleProject(media: media, projectURL: projectURL)
        // Simulate a copy to another machine: no bookmark, old absolute path gone.
        project.source.bookmark = nil
        project.source.absolutePath = "/Volumes/Old Mac/media/clip.mp4"
        let moved = directory.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: moved.appendingPathComponent("media"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moved.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let movedMedia = moved.appendingPathComponent("media/clip.mp4")
        try FileManager.default.moveItem(at: media, to: movedMedia)
        let movedProject = moved.appendingPathComponent("projects/p.framestack")
        XCTAssertEqual(resolvedPath(SourceLocator.resolve(project.source, projectURL: movedProject)), movedMedia.resolvingSymlinksInPath().path)
    }

    func testMissingMediaIsReportedNotGuessed() throws {
        let media = try copyFixture(.count, as: "clip.mp4")
        let projectURL = directory.appendingPathComponent("projects/p.framestack")
        let project = try sampleProject(media: media, projectURL: projectURL)
        try FileManager.default.removeItem(at: media)
        XCTAssertEqual(SourceLocator.resolve(project.source, projectURL: projectURL), .missing)
    }

    func testReplacedMediaIsReportedAsChangedNeverUsedSilently() throws {
        let media = try copyFixture(.count, as: "clip.mp4")
        let projectURL = directory.appendingPathComponent("projects/p.framestack")
        let project = try sampleProject(media: media, projectURL: projectURL)
        try FileManager.default.removeItem(at: media)
        try FileManager.default.copyItem(at: Fixture.movingSquare.url, to: media)
        guard case let .changed(url, differences) = SourceLocator.resolve(project.source, projectURL: projectURL) else {
            return XCTFail("expected .changed")
        }
        XCTAssertEqual(url.resolvingSymlinksInPath().path, media.resolvingSymlinksInPath().path)
        XCTAssertEqual(differences.count, 2)
        // A relink to the right file elsewhere is accepted; to a wrong file is flagged.
        let elsewhere = try copyFixture(.count, as: "found it.mp4")
        XCTAssertEqual(SourceLocator.check(elsewhere, against: project.source.identity), .found(elsewhere))
        guard case .changed = SourceLocator.check(Fixture.blackWhite.url, against: project.source.identity) else {
            return XCTFail("a different clip must be flagged")
        }
    }

    func testRelativePathAcrossVolumesIsNil() {
        XCTAssertNil(SourceReference.relativePath(to: URL(fileURLWithPath: "/Volumes/X/a.mov"), from: URL(fileURLWithPath: "/Users/me/p")))
        XCTAssertEqual(SourceReference.relativePath(to: URL(fileURLWithPath: "/Users/me/clips/a.mov"), from: URL(fileURLWithPath: "/Users/me/projects")), "../clips/a.mov")
        XCTAssertEqual(SourceReference.relativePath(to: URL(fileURLWithPath: "/Users/me/p/a.mov"), from: URL(fileURLWithPath: "/Users/me/p")), "a.mov")
    }
}
