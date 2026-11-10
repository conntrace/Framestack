import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// M6b: exact Median in bands and whole-pixel luminance extremes on the fixtures.
final class MedianRenderTests: XCTestCase {
    func testMedianRemovesTheMovingSquareAndKeepsTheBar() async throws {
        let clip = try await loadFixture(.movingSquare)
        let result = try await render(clip, indices: Array(0..<24), mode: .median)
        let report = try XCTUnwrap(result.median)
        XCTAssertEqual(report.passes, 1, "480×272 × 24 frames fits one pass")
        XCTAssertEqual(report.frameCount, 24)
        XCTAssertEqual(result.framesComposited, 24)
        XCTAssertEqual(result.missingFrames, [])
        // The square covers each column in only 2 of 24 frames → median is background (black).
        XCTAssertEqual(result.image.mean(x: 40..<440, y: 90..<100).x, 0, accuracy: 0.005, "trail gone")
        // The static gray bar survives untouched.
        let average = try await render(clip, indices: Array(0..<24))
        XCTAssertEqual(result.image.mean(x: 40..<440, y: 220..<260).x, average.image.mean(x: 40..<440, y: 220..<260).x, accuracy: 0.002)
        XCTAssertEqual(result.image.alphaRange, 1...1)
        saveArtifact(result.image, name: "moving_square_median")
    }

    func testMultiPassMedianEqualsSinglePass() async throws {
        // Force many bands by shrinking the budget: a tiny plan on the count clip.
        let clip = try await loadFixture(.count)
        let frames = Array(clip.timeline.frames[0..<20])
        let single = try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: frames, blendMode: .median, maxLongEdge: nil))
        XCTAssertEqual(single.median?.passes, 1)
        let banded = try await CompositeRenderer(memoryBudgetBytes: 20 * 320 * 16 * 7).render(
            CompositeRequest(source: .video(clip.info), frames: frames, blendMode: .median, maxLongEdge: nil))
        let report = try XCTUnwrap(banded.median)
        XCTAssertEqual(report.bandRows, 7)
        XCTAssertEqual(report.passes, 26, "180 rows in bands of 7")
        XCTAssertEqual(banded.image.pixels, single.image.pixels, "band seams are invisible: identical pixels")
        XCTAssertEqual(banded.framesComposited, 20)
        XCTAssertTrue(report.summary.contains("26 passes"), report.summary)
        // Block values: bit b is set in more than half of frames 0…19 only for … none (bit 4 set in 16…19 = 4/20); so all blocks are black,
        // except the median of a 50/50 split (bit 0: 10 set, 10 clear → 0.5).
        XCTAssertEqual(Double(single.image.mean(x: 288..<312, y: 8..<32).x), 0.5, accuracy: 0.03, "bit 0: 10 of 20 frames → mean of the middle pair")
        XCTAssertEqual(Double(single.image.mean(x: 8..<32, y: 8..<32).x), 0, accuracy: 0.01, "bit 7 never set")
        saveArtifact(banded.image, name: "count_20_median_banded")
    }

    func testMedianProgressReportsPasses() async throws {
        let clip = try await loadFixture(.count)
        let frames = Array(clip.timeline.frames[0..<10])
        let renderer = CompositeRenderer(memoryBudgetBytes: 10 * 320 * 16 * 60)
        final class Seen: @unchecked Sendable { var passes = Set<Int>(); var maxPass = 0; let lock = NSLock() }
        let seen = Seen()
        let result = try await renderer.render(CompositeRequest(source: .video(clip.info), frames: frames, blendMode: .median, maxLongEdge: nil)) { p in
            seen.lock.lock(); seen.passes.insert(p.pass); seen.maxPass = max(seen.maxPass, p.passes); seen.lock.unlock()
        }
        XCTAssertEqual(result.median?.passes, 3)
        XCTAssertEqual(seen.passes, [1, 2, 3])
        XCTAssertEqual(seen.maxPass, 3)
    }

    func testMedianOnAnImageSequenceWithAlignmentAndWeightsIgnored() async throws {
        let folder = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/handheld_png_8f")
        let seq = try await ImageSequenceLoader.load([folder])
        let frames = seq.timeline.frames
        let result = try await CompositeRenderer(memoryBudgetBytes: 8 * 320 * 16 * 50).render(
            CompositeRequest(source: .imageSequence(seq), frames: frames, blendMode: .median, maxLongEdge: nil,
                             alignment: AlignmentSettings(enabled: true), weighting: WeightCurve(preset: .late)))
        XCTAssertEqual(result.median?.passes, 4)
        let alignment = try XCTUnwrap(result.alignment)
        XCTAssertEqual(alignment.alignedFrames, 7, "registration shared across passes")
        XCTAssertTrue(try XCTUnwrap(result.weighting).ignoredByMode)
        // Aligned median of a static scene equals the reference inside the safe area.
        let reference = try await sharedRenderer.render(CompositeRequest(source: .imageSequence(seq), frames: [frames[4]], blendMode: .average, maxLongEdge: nil))
        var diff = 0.0, n = 0.0
        let area = alignment.validArea.insetBy(dx: 2, dy: 2)
        for y in Int(area.minY)..<Int(area.maxY) { for x in Int(area.minX)..<Int(area.maxX) {
            diff += Double(abs(result.image.pixel(x: x, y: y).x - reference.image.pixel(x: x, y: y).x)); n += 1
        } }
        XCTAssertLessThan(diff / n, 0.002)
    }

    func testLuminanceModesOnTheClips() async throws {
        let bw = try await loadFixture(.blackWhite)
        let maxL = try await render(bw, indices: Array(0..<9), mode: .maxLuminance)
        XCTAssertEqual(maxL.image.mean(x: 10..<150, y: 10..<86).x, 1, accuracy: 0.01)
        let minL = try await render(bw, indices: Array(0..<9), mode: .minLuminance)
        XCTAssertEqual(minL.image.mean(x: 10..<150, y: 10..<86).x, 0, accuracy: 0.01)
        XCTAssertNil(maxL.median)
        // Moving square: max luminance keeps the white trail like Lighten; min luminance shows only the background.
        let sq = try await loadFixture(.movingSquare)
        let trail = try await render(sq, indices: Array(0..<24), mode: .maxLuminance)
        XCTAssertGreaterThan(trail.image.mean(x: 40..<440, y: 90..<100).x, 0.9)
        let background = try await render(sq, indices: Array(0..<24), mode: .minLuminance)
        XCTAssertLessThan(background.image.mean(x: 40..<440, y: 90..<100).x, 0.01)
        XCTAssertEqual(background.image.mean(x: 40..<440, y: 220..<260).x, trail.image.mean(x: 40..<440, y: 220..<260).x, accuracy: 0.002, "static bar identical")
        saveArtifact(trail.image, name: "moving_square_max_luminance")
    }
}
