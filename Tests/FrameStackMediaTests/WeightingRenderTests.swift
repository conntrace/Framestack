import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// M6a: temporal weights applied by the renderer, checked against values
/// computed from the count clip's known per-frame content.
final class WeightingRenderTests: XCTestCase {
    /// Expected weighted mean of block b (bit 7−b of the frame index) over `indices`.
    private func expectedBlock(_ b: Int, indices: [Int], weights: [Double]) -> Double {
        var num = 0.0, den = 0.0
        for (i, w) in zip(indices, weights) {
            if (i >> (7 - b)) & 1 == 1 { num += w }
            den += w
        }
        return num / den
    }

    private func blockMean(_ image: LinearImage, _ b: Int) -> Double {
        Double(image.mean(x: (b * 40 + 8)..<(b * 40 + 32), y: 8..<32).x)
    }

    func testFavorLateWeightsTheCountClipByTimestamp() async throws {
        let clip = try await loadFixture(.count)
        let indices = Array(0..<30)
        let frames = indices.map { clip.timeline.frames[$0] }
        let curve = WeightCurve(preset: .late)
        let result = try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: frames, blendMode: .average,
                                                                        maxLongEdge: nil, weighting: curve))
        let report = try XCTUnwrap(result.weighting)
        XCTAssertEqual(report.preset, .late)
        XCTAssertFalse(report.ignoredByMode)
        XCTAssertFalse(report.usedFlatFallback)
        XCTAssertLessThan(report.effectiveFrameCount, 30)
        XCTAssertGreaterThan(report.effectiveFrameCount, 20)
        let weights = curve.weights(for: frames).raw
        for b in 0..<8 {
            XCTAssertEqual(blockMean(result.image, b), expectedBlock(b, indices: indices, weights: weights), accuracy: 0.02, "block \(b)")
        }
        // Flat reproduces the plain Average exactly.
        let flat = try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: frames, blendMode: .average, maxLongEdge: nil))
        XCTAssertNil(flat.weighting)
        let plain = try await render(clip, indices: indices)
        XCTAssertEqual(flat.image.pixels, plain.image.pixels)
        saveArtifact(result.image, name: "count_30_favor_late")
    }

    func testWeightsFollowTimestampsOnAVariableRateSelection() async throws {
        // Frames 0, 1, 28, 29: "late" must weight 1 and 28 by their time, not their index.
        let clip = try await loadFixture(.count)
        let indices = [0, 1, 28, 29]
        let frames = indices.map { clip.timeline.frames[$0] }
        let weights = WeightCurve(preset: .late).weights(for: frames)
        XCTAssertEqual(weights.times[1], 1.0 / 29, accuracy: 1e-9)
        XCTAssertEqual(weights.times[2], 28.0 / 29, accuracy: 1e-9)
        let result = try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: frames, blendMode: .average,
                                                                        maxLongEdge: nil, weighting: WeightCurve(preset: .late)))
        for b in 0..<8 {
            XCTAssertEqual(blockMean(result.image, b), expectedBlock(b, indices: indices, weights: weights.raw), accuracy: 0.02, "block \(b)")
        }
    }

    func testModesAndWeights() async throws {
        let clip = try await loadFixture(.blackWhite)   // even frames black, odd white
        let frames = Array(clip.timeline.frames[0..<10])
        let early = WeightCurve(preset: .early)
        // Average: white frames (odd) get the smaller weights under "early".
        let avg = try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: frames, blendMode: .average, maxLongEdge: nil, weighting: early))
        let w = early.weights(for: frames)
        let expected = zip(0..<10, w.normalized).reduce(0.0) { $0 + ($1.0 % 2 == 1 ? $1.1 : 0) }
        XCTAssertEqual(Double(avg.image.mean(x: 10..<150, y: 10..<86).x), expected, accuracy: 0.02)
        XCTAssertLessThan(expected, 0.5, "early favours the black frames")
        // Lighten ignores weights and says so.
        let lighten = try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: frames, blendMode: .lighten, maxLongEdge: nil, weighting: early))
        XCTAssertTrue(try XCTUnwrap(lighten.weighting).ignoredByMode)
        XCTAssertEqual(lighten.image.mean(x: 10..<150, y: 10..<86).x, 1, accuracy: 0.01)
        // Additive: Σ raw weights of the white frames.
        let additive = try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: frames, blendMode: .additive, maxLongEdge: nil, weighting: early))
        let whiteRaw = zip(0..<10, w.raw).reduce(0.0) { $0 + ($1.0 % 2 == 1 ? $1.1 : 0) }
        XCTAssertEqual(Double(additive.image.mean(x: 10..<150, y: 10..<86).x), whiteRaw, accuracy: 0.05)
        // Normal at 100 %: C' = C + w × (frame − C), first frame initialises; recurrence computed here.
        let normal = try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: frames, blendMode: .normal, maxLongEdge: nil, weighting: early))
        var c = 0.0
        for i in 1..<10 { let f = i % 2 == 1 ? 1.0 : 0.0; c += w.raw[i] * (f - c) }
        XCTAssertEqual(Double(normal.image.mean(x: 10..<150, y: 10..<86).x), c, accuracy: 0.02, "last white frame at weight 0.1 barely shows")
        XCTAssertLessThan(c, 0.55)
        XCTAssertTrue(try XCTUnwrap(normal.weighting).summary(framesComposited: 10).contains("Favor Early"))
    }
}
