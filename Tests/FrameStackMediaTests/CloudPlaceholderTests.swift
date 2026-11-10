import Darwin
import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// D-037: stills that are iCloud placeholders are left out unopened. The
/// file system flag cannot be set from a test, so the loader's placeholder
/// question is answered by the test; the real flag is checked by the opt-in
/// run on a folder that really has placeholders.
final class CloudPlaceholderTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackCloud-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Copies of a real still under new names; `garbage` names get bytes
    /// that are not an image, so opening one would show up as "skipped".
    private func makeFolder(images: [String], garbage: [String] = []) throws -> [URL] {
        let still = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/sequence_png_12f/frame_0.png")
        for name in images { try FileManager.default.copyItem(at: still, to: scratch.appendingPathComponent(name)) }
        for name in garbage { try Data("not an image".utf8).write(to: scratch.appendingPathComponent(name)) }
        return (images + garbage).map { scratch.appendingPathComponent($0) }
    }

    func testPlaceholderImagesAreLeftOutUnopenedAndListed() async throws {
        let urls = try makeFolder(images: ["a_1.png", "a_3.png", "a_4.png"], garbage: ["a_2.png"])
        var asked: [String] = []
        let seq = try await ImageSequenceLoader.load(
            folder: scratch, candidates: urls, framesPerSecond: 30, reversed: false, canvasPolicy: .strict,
            isPlaceholder: { asked.append($0.lastPathComponent); return $0.lastPathComponent == "a_2.png" })
        XCTAssertEqual(seq.files.map(\.fileName), ["a_1.png", "a_3.png", "a_4.png"])
        XCTAssertEqual(seq.notDownloadedFileNames, ["a_2.png"])
        XCTAssertEqual(seq.skippedFileNames, [], "the placeholder was not opened: had it been, it would be listed as unreadable")
        XCTAssertEqual(asked, ["a_1.png", "a_2.png", "a_3.png", "a_4.png"], "every image is asked about before it is read")
        let notice = try XCTUnwrap(seq.warnings.first)
        XCTAssertTrue(notice.contains("1 image in the folder is stored in iCloud"), notice)
        XCTAssertTrue(notice.contains("a_2.png"), notice)
        XCTAssertEqual(seq.timeline.count, 3, "the frames that are here still stack")
        // The list survives a change of rate or order.
        XCTAssertEqual(seq.with(framesPerSecond: 12, reversed: true).notDownloadedFileNames, ["a_2.png"])
    }

    func testFolderOfOnlyPlaceholdersFailsWithTheICloudMessage() async throws {
        let urls = try makeFolder(images: [], garbage: ["b_1.png", "b_2.png"])
        do {
            _ = try await ImageSequenceLoader.load(folder: scratch, candidates: urls, framesPerSecond: 30, reversed: false,
                                                   canvasPolicy: .strict, isPlaceholder: { _ in true })
            XCTFail("expected the iCloud error")
        } catch let error as MediaError {
            XCTAssertEqual(error, .imagesNotDownloaded(path: scratch.path, count: 2))
            let text = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(text.contains("2 images") && text.contains("iCloud") && text.contains("Download them in Finder"), text)
        }
    }

    /// Reopening a project checks the saved stills; a placeholder among them
    /// is reported as in iCloud, not as missing, and is not opened.
    func testProjectCheckReportsPlaceholdersWithoutOpeningThem() async throws {
        let urls = try makeFolder(images: ["d_1.png", "d_2.png", "d_3.png"])
        let seq = try await ImageSequenceLoader.load([scratch], framesPerSecond: 30, reversed: false)
        let reference = SourceReference.make(source: .imageSequence(seq), identity: SourceIdentity.compute(forSequence: seq),
                                             frameCount: 3, projectURL: scratch.appendingPathComponent("p.framestack"))
        XCTAssertEqual(SourceLocator.check(scratch, against: reference), .found(scratch))
        // d_2 "moves to iCloud"; d_3 is deleted.
        try FileManager.default.removeItem(at: urls[2])
        guard case let .changed(_, differences) = SourceLocator.check(scratch, against: reference, isPlaceholder: { $0.lastPathComponent == "d_2.png" }) else {
            return XCTFail("expected changed")
        }
        XCTAssertEqual(Array(differences.prefix(2)), ["1 of 3 images stored in iCloud, not downloaded to this Mac", "1 of 3 images missing"])
    }

    /// A single source file (a video) that is a placeholder is not fingerprinted.
    func testProjectCheckDoesNotFingerprintAPlaceholderFile() throws {
        let video = loadFixtureURL()
        let reference = SourceReference(bookmark: nil, absolutePath: video.path, relativePath: nil,
                                        identity: try SourceIdentity.compute(for: video),
                                        duration: .zero, displaySize: PixelSize(width: 0, height: 0), frameCount: 0)
        XCTAssertEqual(SourceLocator.check(video, against: reference), .found(video))
        guard case let .changed(_, differences) = SourceLocator.check(video, against: reference, isPlaceholder: { _ in true }) else {
            return XCTFail("expected changed")
        }
        XCTAssertEqual(differences.count, 1)
        XCTAssertTrue(differences[0].hasPrefix("stored in iCloud, not downloaded to this Mac"), differences[0])
    }

    func testFilesOnThisDiskAreNotPlaceholders() throws {
        let urls = try makeFolder(images: ["c_1.png"])
        XCTAssertFalse(CloudFiles.isNotDownloaded(urls[0]))
        XCTAssertFalse(CloudFiles.isNotDownloaded(scratch.appendingPathComponent("absent.png")))
        XCTAssertFalse(CloudFiles.isNotDownloaded(loadFixtureURL()))
    }

    private func loadFixtureURL() -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(Fixture.movingSquare.rawValue).mp4")
    }

    /// Opt-in, on a folder that really holds iCloud placeholders:
    ///
    ///     FRAMESTACK_REAL_RAW_FOLDER="/path/to/folder" swift test --filter CloudPlaceholderTests/testOwnerFolderPlaceholdersAreLeftAlone
    ///
    /// Opens the folder the way the app does and checks, from the file
    /// system flag alone, that no placeholder was downloaded by it.
    func testOwnerFolderPlaceholdersAreLeftAlone() async throws {
        guard let path = ProcessInfo.processInfo.environment["FRAMESTACK_REAL_RAW_FOLDER"], !path.isEmpty else {
            throw XCTSkip("Set FRAMESTACK_REAL_RAW_FOLDER=/path to run on a folder with iCloud placeholders.")
        }
        let folder = URL(fileURLWithPath: path)
        func dataless() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: path).filter { name in
                var info = stat()
                guard lstat(folder.appendingPathComponent(name).path, &info) == 0 else { return false }
                return info.st_flags & 0x4000_0000 != 0 && ImageSequenceLoader.isImageFile(folder.appendingPathComponent(name))
            }.sorted()
        }
        let before = try dataless()
        let start = Date()
        let seq = try await ImageSequenceLoader.load([folder], canvasPolicy: .fit)
        let seconds = Date().timeIntervalSince(start)
        let after = try dataless()
        FileHandle.standardError.write(Data("CLOUD  \(seq.count) images opened, \(seq.notDownloadedFileNames.count) left out as iCloud placeholders, \(seq.skippedFileNames.count) skipped, \(String(format: "%.2f", seconds)) s; placeholders on disk before \(before.count), after \(after.count)\n".utf8))
        XCTAssertEqual(seq.notDownloadedFileNames.sorted(), before, "exactly the placeholders are left out")
        XCTAssertEqual(after, before, "opening the folder downloaded nothing")
        XCTAssertFalse(seq.files.contains { before.contains($0.fileName) })
        if !before.isEmpty {
            XCTAssertTrue(seq.warnings.contains { $0.contains("stored in iCloud") })
        }
    }
}
