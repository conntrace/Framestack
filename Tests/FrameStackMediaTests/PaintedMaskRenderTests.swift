import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// M6d: a painted mask limits where frames blend; elsewhere the background shows.
final class PaintedMaskRenderTests: XCTestCase {
    func testPaintedRegionLimitsTheBlendAndCombinesWithTheMotionMask() async throws {
        let clip = try await loadFixture(.movingSquare)   // square path along y ≈ 80…112, x 0…480
        // Paint only the left half of the frame (a wide horizontal stroke).
        let left = MaskStroke(points: [.init(x: 0.0, y: 0.35), .init(x: 0.5, y: 0.35)], radius: 0.1, softness: 0)
        let painted = PaintedMaskSettings(enabled: true, strokes: [left])
        // Lighten + painted mask, median background (motion mask off): left half shows the trail, right half the background.
        let result = try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: clip.timeline.frames,
                                                                        blendMode: .lighten, maxLongEdge: nil, paintedMask: painted))
        let report = try XCTUnwrap(result.motionMask)
        XCTAssertFalse(report.motionActive)
        XCTAssertEqual(report.paintedStrokes, 1)
        XCTAssertTrue(report.summary.contains("1 painted stroke"), report.summary)
        XCTAssertGreaterThan(result.image.mean(x: 60..<200, y: 90..<100).x, 0.9, "painted: the trail shows")
        XCTAssertLessThan(result.image.mean(x: 300..<440, y: 90..<100).x, 0.01, "unpainted: median background (black)")
        XCTAssertEqual(result.image.alphaRange, 1...1)
        let coverage = try XCTUnwrap(result.coverage)
        XCTAssertEqual(coverage[96 * 480 + 100], 1, accuracy: 1e-6)
        XCTAssertEqual(coverage[96 * 480 + 400], 0, accuracy: 1e-6)

        // With the motion mask too: Normal blend → chronophotography only on the left.
        let both = try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: clip.timeline.frames, blendMode: .normal,
                                                                      maxLongEdge: nil, motionMask: MotionMaskSettings(enabled: true, feather: 0, cleanup: 0),
                                                                      paintedMask: painted))
        XCTAssertTrue(try XCTUnwrap(both.motionMask).motionActive)
        XCTAssertGreaterThan(both.image.mean(x: 60..<200, y: 90..<100).x, 0.8, "chronophotography on the painted side (compression halos keep it below 1)")
        XCTAssertLessThan(both.image.mean(x: 300..<440, y: 90..<100).x, 0.01)
        XCTAssertEqual(Double(try XCTUnwrap(both.coverage)[96 * 480 + 100]), 2.0 / 24, accuracy: 0.02, "motion × painted")

        // Inverted painting excludes the left half instead; a half-size preview agrees.
        var inverted = painted; inverted.invert = true
        let inv = try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: clip.timeline.frames,
                                                                     blendMode: .lighten, maxLongEdge: 240, paintedMask: inverted))
        let leftSide = inv.image.mean(x: 30..<100, y: 45..<50).x, rightSide = inv.image.mean(x: 150..<220, y: 45..<50).x
        XCTAssertLessThan(leftSide, 0.01)
        XCTAssertGreaterThan(rightSide, 0.8, "the half-size Lanczos trail is a little under 1; the sides are what matters")
        XCTAssertGreaterThan(rightSide, leftSide + 0.7)
        saveArtifact(result.image, name: "moving_square_painted_left")
    }
}
