import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// M6c: the moving-square clip is the ideal case — a white 32×32 square
/// moving 16 px per frame over a static scene (black + a gray bar).
final class MotionMaskRenderTests: XCTestCase {
    private func render(_ clip: LoadedFixture, mode: BlendMode, mask: MotionMaskSettings, maxLongEdge: Int? = nil) async throws -> CompositeResult {
        try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: clip.timeline.frames, blendMode: mode,
                                                         maxLongEdge: maxLongEdge, motionMask: mask))
    }

    func testNormalPlusMaskIsChronophotography() async throws {
        let clip = try await loadFixture(.movingSquare)
        let mask = MotionMaskSettings(enabled: true, background: .median, threshold: 0.1, feather: 0, cleanup: 0)
        let result = try await render(clip, mode: .normal, mask: mask)
        let report = try XCTUnwrap(result.motionMask)
        XCTAssertEqual(report.backgroundDescription, "the median of 24 frames")
        XCTAssertFalse(report.inverted)
        XCTAssertEqual(result.image.alphaRange, 1...1, "laid over an opaque background")
        // Every square position is visible at once: the whole path row is white.
        XCTAssertGreaterThan(result.image.mean(x: 40..<440, y: 90..<100).x, 0.9)
        // Background elsewhere: black above the path, gray bar below, as in the median.
        XCTAssertLessThan(result.image.mean(x: 40..<440, y: 20..<60).x, 0.01)
        let median = try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: clip.timeline.frames, blendMode: .median, maxLongEdge: nil))
        XCTAssertEqual(result.image.mean(x: 40..<440, y: 220..<260).x, median.image.mean(x: 40..<440, y: 220..<260).x, accuracy: 0.002)
        // Coverage: the path row was masked in 2 of 24 frames per column.
        let coverage = try XCTUnwrap(result.coverage)
        XCTAssertEqual(coverage.count, 480 * 272)
        XCTAssertEqual(Double(coverage[96 * 480 + 200]), 2.0 / 24, accuracy: 0.02)
        XCTAssertEqual(Double(coverage[40 * 480 + 200]), 0, accuracy: 1e-6)
        XCTAssertGreaterThan(report.backgroundOnlyFraction, 0.8)
        XCTAssertLessThan(report.meanCoverage, 0.02)
        saveArtifact(result.image, name: "moving_square_chronophotography")
    }

    func testAveragePlusMaskGhostsAndInvertKeepsTheStill() async throws {
        let clip = try await loadFixture(.movingSquare)
        let mask = MotionMaskSettings(enabled: true, background: .median, threshold: 0.1, feather: 0, cleanup: 0)
        let ghost = try await render(clip, mode: .average, mask: mask)
        // Masked mean: where the square was 2 of 24 frames the composite is 2/24 square + 22/24 background.
        XCTAssertEqual(Double(ghost.image.mean(x: 200..<216, y: 90..<100).x), 2.0 / 24, accuracy: 0.02)
        XCTAssertEqual(ghost.image.alphaRange, 1...1)
        var inverted = mask; inverted.invert = true
        let still = try await render(clip, mode: .average, mask: inverted)
        XCTAssertTrue(try XCTUnwrap(still.motionMask).inverted)
        XCTAssertLessThan(still.image.mean(x: 40..<440, y: 90..<100).x, 0.01, "the moving square is excluded; only background remains")
        XCTAssertEqual(still.image.mean(x: 40..<440, y: 220..<260).x, ghost.image.mean(x: 40..<440, y: 220..<260).x, accuracy: 0.002)
    }

    func testFrameBackgroundFeatherAndPreviewExportAgree() async throws {
        let clip = try await loadFixture(.movingSquare)
        let reference = clip.timeline.frames[0]   // the square at its first position
        let mask = MotionMaskSettings(enabled: true, background: .frame(reference), threshold: 0.1, feather: 3, cleanup: 1)
        let full = try await render(clip, mode: .lighten, mask: mask)
        let report = try XCTUnwrap(full.motionMask)
        XCTAssertTrue(report.backgroundDescription.hasPrefix("frame 0 at 0.000 s"), report.backgroundDescription)
        // Against frame 0 the square's first position is background (so it stays) and every later position is motion.
        XCTAssertGreaterThan(full.image.mean(x: 40..<440, y: 90..<100).x, 0.9)
        // Feathered edges: values between 0 and 1 exist just outside the path.
        let edge = full.image.mean(x: 100..<400, y: 79..<81).x
        XCTAssertGreaterThan(edge, 0.02)
        XCTAssertLessThan(edge, 0.98)
        // The preview (half size; feather/clean-up radii scale with it) agrees with the full render.
        let preview = try await render(clip, mode: .lighten, mask: mask, maxLongEdge: 240)
        XCTAssertEqual(preview.image.mean(x: 20..<220, y: 45..<50).x, full.image.mean(x: 40..<440, y: 90..<100).x, accuracy: 0.1)
        XCTAssertEqual(preview.image.mean(x: 20..<220, y: 110..<130).x, full.image.mean(x: 40..<440, y: 220..<260).x, accuracy: 0.01)
        saveArtifact(full.image, name: "moving_square_mask_frame0_lighten")
    }

    func testMaskWithMedianBlendAndBands() async throws {
        // Median + mask through the banded path: a pixel must move in more than half the frames to show.
        let clip = try await loadFixture(.movingSquare)
        let mask = MotionMaskSettings(enabled: true, background: .median, threshold: 0.1, feather: 0, cleanup: 0)
        let renderer = CompositeRenderer(memoryBudgetBytes: 24 * 480 * 16 * 40)
        let result = try await renderer.render(CompositeRequest(source: .video(clip.info), frames: clip.timeline.frames, blendMode: .median,
                                                                  maxLongEdge: nil, motionMask: mask))
        XCTAssertEqual(result.median?.passes, 7)
        XCTAssertNotNil(result.motionMask)
        XCTAssertLessThan(result.image.mean(x: 40..<440, y: 90..<100).x, 0.01, "no pixel moves in more than half the frames → background")
        let coverage = try XCTUnwrap(result.coverage)
        XCTAssertEqual(Double(coverage[96 * 480 + 200]), 2.0 / 24, accuracy: 0.02, "coverage counted once across passes")
    }
}
