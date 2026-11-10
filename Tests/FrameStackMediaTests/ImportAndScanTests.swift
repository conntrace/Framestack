import FrameStackCore
@testable import FrameStackMedia
import XCTest

final class ImportAndScanTests: XCTestCase {
    func testCountClipMetadata() async throws {
        let info = try await VideoSourceLoader.load(url: Fixture.count.url)
        XCTAssertEqual(info.fileName, "count_5s_30fps.mp4")
        XCTAssertEqual(info.encodedSize, PixelSize(width: 320, height: 180))
        XCTAssertEqual(info.displaySize, PixelSize(width: 320, height: 180))
        XCTAssertEqual(info.orientation, .up)
        XCTAssertEqual(info.duration.seconds, 5.0, accuracy: 0.001)
        XCTAssertEqual(info.nominalFrameRate ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(info.estimatedFrameCount, 150)
        XCTAssertEqual(info.codec, "avc1")
        XCTAssertFalse(info.isHDR)
        XCTAssertNotNil(info.transferFunction, "BT.709 tags should be read from the format description")
    }

    /// PRD §1 / §11.2: 5 s at 30 fps → 150 frames, confirmed from the stream's
    /// own timestamps (the clip uses B-frames and an MP4 edit list).
    func testScanFindsExactTimestampsOfFiveSecondClip() async throws {
        let fixture = try await loadFixture(.count)
        XCTAssertEqual(fixture.timeline.count, 150)
        XCTAssertEqual(fixture.timeline.duplicateTimestampsDropped, 0)
        for (i, t) in fixture.timeline.frames.enumerated() {
            XCTAssertEqual(t, FrameTime(value: Int64(i), timescale: 30), "frame \(i) at \(t)")
        }

        let full = FrameTimeRange(start: .zero, end: fixture.info.duration)
        XCTAssertEqual(try FrameSampler.select(from: fixture.timeline, range: full, mode: .all).selectedCount, 150)
        XCTAssertEqual(try FrameSampler.select(from: fixture.timeline, range: full, mode: .everyNth(2)).selectedCount, 75)
        XCTAssertEqual(try FrameSampler.select(from: fixture.timeline, range: full, mode: .everyNth(3)).selectedCount, 50)
        let twoToFive = FrameTimeRange(start: FrameTime(seconds: 2), end: FrameTime(seconds: 5))
        XCTAssertEqual(try FrameSampler.select(from: fixture.timeline, range: twoToFive, mode: .all).selectedCount, 90)
        XCTAssertEqual(try FrameSampler.select(from: fixture.timeline, range: twoToFive, mode: .everyNth(3)).selectedCount, 30)
    }

    /// The fast sample-table scan must yield exactly the timestamps the
    /// decoder delivers, for every fixture (B-frame delay edit list,
    /// trimming edit list, no edit list, rotation).
    func testSampleTableScanAgreesWithDecodeScan() async throws {
        for fixture in [Fixture.count, .trimmed, .movingSquare, .blackWhite, .portrait] {
            let info = try await VideoSourceLoader.load(url: fixture.url)
            let fast = try await FrameScanner.scan(info, preference: .automatic)
            let decoded = try await FrameScanner.scan(info, preference: .decodeOnly)
            XCTAssertEqual(decoded.method, .decode)
            XCTAssertEqual(fast.timeline, decoded.timeline,
                           "\(fixture.rawValue): method \(fast.method) \(fast.fallbackReason ?? "")")
            if fixture == .count {
                XCTAssertEqual(fast.method, .sampleTable, fast.fallbackReason ?? "")
            }
        }
    }

    func testTrimmedEditListPresentsOnlyEditedFrames() async throws {
        let clip = try await loadFixture(.trimmed)
        XCTAssertEqual(clip.timeline.count, 62)
        XCTAssertEqual(clip.timeline.frames.first, .zero)
        XCTAssertEqual(clip.timeline.frames.last, FrameTime(value: 61, timescale: 30))
        let first = try await render(clip, indices: [0])
        XCTAssertEqual(decodeFrameIndex(first.image), 45)
        let last = try await render(clip, indices: [61])
        XCTAssertEqual(decodeFrameIndex(last.image), 106)
        let all = try await render(clip, indices: Array(0..<62), maxLongEdge: 64)
        XCTAssertEqual(all.framesComposited, 62)
        XCTAssertEqual(all.missingFrames, [])
    }

    func testPortraitOrientationFromDisplayMatrix() async throws {
        let info = try await VideoSourceLoader.load(url: Fixture.portrait.url)
        XCTAssertEqual(info.encodedSize, PixelSize(width: 320, height: 180))
        XCTAssertEqual(info.orientation, .right)
        XCTAssertEqual(info.displaySize, PixelSize(width: 180, height: 320))
    }

    func testMissingFileFailsClearly() async {
        let url = URL(fileURLWithPath: "/nonexistent/clip.mov")
        do {
            _ = try await VideoSourceLoader.load(url: url)
            XCTFail("expected an error")
        } catch let error as MediaError {
            XCTAssertEqual(error, .fileNotFound(path: url.path))
            XCTAssertNotNil(error.errorDescription)
        } catch {
            XCTFail("unexpected error type \(error)")
        }
    }

    func testCorruptFileFailsWithoutCrashing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let garbage = dir.appendingPathComponent("garbage.mp4")
        var rng = SystemRandomNumberGenerator()
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) }).write(to: garbage)

        // A real clip cut off in the middle of its media data.
        let truncated = dir.appendingPathComponent("truncated.mp4")
        let original = try Data(contentsOf: Fixture.count.url)
        try original.prefix(original.count / 3).write(to: truncated)

        for url in [garbage, truncated] {
            do {
                let info = try await VideoSourceLoader.load(url: url)
                // If AVFoundation accepts the header, scanning/decoding must
                // still fail cleanly or visibly report lost frames — never
                // crash and never pass off a partial stack as complete.
                let scan = try await FrameScanner.scan(info)
                let result = try await sharedRenderer.render(CompositeRequest(
                    source: info, frames: scan.timeline.frames, blendMode: .average, maxLongEdge: 64
                ))
                XCTAssertTrue(scan.timeline.count < 150 || !result.missingFrames.isEmpty,
                              "\(url.lastPathComponent) rendered as if complete")
            } catch {
                XCTAssertTrue(error is MediaError, "\(url.lastPathComponent): \(error)")
            }
        }
    }
}
