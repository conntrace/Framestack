import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// M6h: stacking the selection last to first (PRD §4.4, §5.2) for any
/// source. A decoder only runs forward, so a reversed video is decoded in
/// chunks from the end; these tests pin the order, the memory bound and the
/// equality with frames fed to the reducer in reverse by hand.
final class ReverseOrderRenderTests: XCTestCase {
    /// 320×180 RGBA Float32.
    private let bytesPerCountFrame = 320 * 180 * 4 * 4

    private func render(_ clip: LoadedFixture, indices: [Int], mode: BlendMode, opacity: Float = 1, reversed: Bool,
                        weighting: WeightCurve = .flat, renderer: CompositeRenderer = sharedRenderer,
                        progress: (@Sendable (CompositeProgress) -> Void)? = nil) async throws -> CompositeResult {
        let request = CompositeRequest(source: clip.info, frames: indices.map { clip.timeline.frames[$0] }, blendMode: mode, opacity: opacity,
                                       maxLongEdge: nil, weighting: weighting, reverseOrder: reversed)
        if let progress { return try await renderer.render(request, progress: progress) }
        return try await renderer.render(request)
    }

    private func maxDifference(_ a: LinearImage, _ b: LinearImage) -> Float {
        XCTAssertEqual(a.size, b.size)
        return zip(a.pixels, b.pixels).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    /// Each frame decoded on its own, then reduced in the given order.
    private func reference(_ clip: LoadedFixture, order: [Int], mode: BlendMode, opacity: Float, weights: [Int: Double]? = nil) async throws -> LinearImage {
        var reducer: FrameReducer?
        for index in order {
            let frame = try await FrameStackMediaTests.render(clip, indices: [index]).image
            if reducer == nil { reducer = mode.makeReducer(width: frame.width, height: frame.height, opacity: opacity) }
            if let weights { try reducer!.add(frame, weight: weights[index]!) } else { try reducer!.add(frame) }
        }
        return try reducer!.result()
    }

    func testNormalReversedShowsTheFirstSelectedFrame() async throws {
        let clip = try await loadFixture(.count)
        let indices = [12, 40, 77, 101, 149]
        let forward = try await render(clip, indices: indices, mode: .normal, reversed: false)
        XCTAssertEqual(decodeFrameIndex(forward.image), 149)
        XCTAssertFalse(forward.stackedInReverse)
        XCTAssertNil(forward.reverseDecode)
        XCTAssertTrue(forward.deliveredInPresentationOrder)

        let reversed = try await render(clip, indices: indices, mode: .normal, reversed: true)
        XCTAssertEqual(decodeFrameIndex(reversed.image), 12, "the first frame is stacked last, so it is on top")
        XCTAssertEqual(reversed.framesComposited, 5)
        XCTAssertTrue(reversed.missingFrames.isEmpty)
        XCTAssertTrue(reversed.stackedInReverse)
        XCTAssertTrue(reversed.deliveredInPresentationOrder, "stacked strictly in the requested (reversed) order")
        let report = try XCTUnwrap(reversed.reverseDecode)
        XCTAssertEqual(report.chunks, 1)
        XCTAssertEqual(report.framesPerChunk, 5)
    }

    func testReversedEqualsTheSameFramesReducedInReverseByHand() async throws {
        let clip = try await loadFixture(.movingSquare)
        let indices = Array(stride(from: 0, to: 24, by: 3))
        for (mode, opacity) in [(BlendMode.normal, Float(0.4)), (.difference, 1), (.screen, 0.5), (.multiply, 0.7)] {
            let reversed = try await render(clip, indices: indices, mode: mode, opacity: opacity, reversed: true)
            let byHand = try await reference(clip, order: indices.reversed(), mode: mode, opacity: opacity)
            XCTAssertLessThan(maxDifference(reversed.image, byHand), 1e-5, "\(mode)")
            XCTAssertEqual(reversed.framesComposited, indices.count)
        }
        // Normal at 40 %: the newest frame dominates forward, the oldest reversed.
        let forward = try await render(clip, indices: indices, mode: .normal, opacity: 0.4, reversed: false)
        let reversed = try await render(clip, indices: indices, mode: .normal, opacity: 0.4, reversed: true)
        saveArtifact(forward.image, name: "moving_square_normal40_forward")
        saveArtifact(reversed.image, name: "moving_square_normal40_reversed")
        XCTAssertGreaterThan(maxDifference(forward.image, reversed.image), 0.3, "the order matters for this mode")
    }

    func testSmallMemoryBudgetDecodesInChunksWithIdenticalPixels() async throws {
        let clip = try await loadFixture(.count)
        let indices = Array(stride(from: 2, to: 150, by: 5)) // 30 frames
        let whole = try await render(clip, indices: indices, mode: .normal, opacity: 0.3, reversed: true)
        XCTAssertEqual(whole.reverseDecode?.chunks, 1)

        let tight = CompositeRenderer(memoryBudgetBytes: 7 * bytesPerCountFrame + 100)
        let progress = ProgressLog()
        let chunked = try await render(clip, indices: indices, mode: .normal, opacity: 0.3, reversed: true, renderer: tight) { progress.add($0) }
        let report = try XCTUnwrap(chunked.reverseDecode)
        XCTAssertEqual(report.framesPerChunk, 7)
        XCTAssertEqual(report.chunks, 5, "30 frames in chunks of 7")
        XCTAssertEqual(report.memoryBudgetBytes, 7 * bytesPerCountFrame + 100)
        XCTAssertTrue(report.summary.contains("5 chunks of up to 7 frames"), report.summary)
        XCTAssertEqual(chunked.image, whole.image, "chunking must not change a single value")
        XCTAssertEqual(chunked.framesComposited, 30)
        XCTAssertTrue(chunked.deliveredInPresentationOrder)
        XCTAssertEqual(progress.values.last?.framesComposited, 30)
        XCTAssertEqual(progress.values.map(\.framesComposited), progress.values.map(\.framesComposited).sorted(), "progress never runs backwards")
        XCTAssertLessThanOrEqual(progress.values.map(\.framesComposited).max() ?? 0, 30)

        // One frame per chunk is the smallest the budget can force.
        let tiny = CompositeRenderer(memoryBudgetBytes: 1)
        let few = Array(indices.prefix(4))
        let single = try await render(clip, indices: few, mode: .normal, opacity: 0.3, reversed: true, renderer: tiny)
        XCTAssertEqual(single.reverseDecode?.chunks, 4)
        XCTAssertEqual(single.reverseDecode?.framesPerChunk, 1)
        let byHand = try await reference(clip, order: few.reversed(), mode: .normal, opacity: 0.3)
        XCTAssertLessThan(maxDifference(single.image, byHand), 1e-5)
    }

    func testOrderIndependentModesIgnoreReverse() async throws {
        let clip = try await loadFixture(.movingSquare)
        let indices = Array(0..<24)
        for mode in [BlendMode.average, .lighten, .additive, .median] {
            let forward = try await render(clip, indices: indices, mode: mode, reversed: false)
            let reversed = try await render(clip, indices: indices, mode: mode, reversed: true)
            XCTAssertEqual(forward.image, reversed.image, "\(mode)")
            XCTAssertFalse(reversed.stackedInReverse, "\(mode)")
            XCTAssertNil(reversed.reverseDecode, "\(mode): decoded forward, in one pass")
        }
    }

    func testWeightsStayWithTheirTimestampsWhenReversed() async throws {
        let clip = try await loadFixture(.movingSquare)
        let indices = [0, 4, 8, 12, 16, 20]
        let curve = WeightCurve(preset: .late)
        let raw = curve.weights(for: indices.map { clip.timeline.frames[$0] }).raw
        let weights = Dictionary(uniqueKeysWithValues: zip(indices, raw))
        XCTAssertLessThan(weights[0]!, weights[20]!, "the late preset favours the last frames")
        let reversed = try await render(clip, indices: indices, mode: .normal, opacity: 0.8, reversed: true, weighting: curve)
        let byHand = try await reference(clip, order: indices.reversed(), mode: .normal, opacity: 0.8, weights: weights)
        XCTAssertLessThan(maxDifference(reversed.image, byHand), 1e-5, "frame 20 keeps the weight of frame 20, though it is stacked first")
    }

    func testDamagedFrameIsReportedMissingWhenReversedAcrossChunks() async throws {
        let clip = try await loadFixture(.corrupt)
        let indices = Array(60..<90)
        let tight = CompositeRenderer(memoryBudgetBytes: 8 * bytesPerCountFrame)
        let result = try await render(clip, indices: indices, mode: .normal, reversed: true, renderer: tight)
        XCTAssertEqual(result.reverseDecode?.chunks, 4)
        XCTAssertEqual(decodeFrameIndex(result.image), 60)
        XCTAssertFalse(result.missingFrames.isEmpty, "frame 75 cannot be decoded")
        XCTAssertTrue(result.missingFrames.contains(clip.timeline.frames[75]))
        XCTAssertEqual(result.framesComposited + result.missingFrames.count, 30)
        XCTAssertFalse(result.decodeFailures.isEmpty)
        // Forward, the decoder dies at frame 75 with frames 73 and 74 still
        // in its reorder queue and recovers at the next keyframe (90), so
        // 73…89 are lost and frame 72 ends on top. Reversed, each chunk has
        // its own reader: a chunk that ends before the damage keeps its
        // frames (observed: 73 survives, the chunk starting at 74 is lost).
        // Never more is lost than forward, and never a frame outside the
        // damaged group.
        let forward = try await render(clip, indices: indices, mode: .normal, reversed: false, renderer: tight)
        XCTAssertTrue(Set(result.missingFrames).isSubset(of: Set(forward.missingFrames)))
        XCTAssertEqual(decodeFrameIndex(forward.image), 72)
        for missing in result.missingFrames {
            XCTAssertTrue((73..<90).contains(clip.timeline.frames.firstIndex(of: missing)!))
        }
    }

    func testReversedRenderCanBeCancelled() async throws {
        let clip = try await loadFixture(.count)
        let counter = ProgressLog()
        let request = CompositeRequest(source: clip.info, frames: clip.timeline.frames, blendMode: .normal, opacity: 0.5, maxLongEdge: nil,
                                       reverseOrder: true)
        let renderer = CompositeRenderer(memoryBudgetBytes: 10 * bytesPerCountFrame)
        let task = Task {
            try await renderer.render(request) { p in
                counter.add(p)
                usleep(20_000)
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while counter.values.count < 3, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("render should have been cancelled")
        } catch is CancellationError {}
        XCTAssertLessThan(counter.values.count, 300, "cancellation must stop the render early")
        let after = try await render(clip, indices: [10, 20], mode: .normal, reversed: true, renderer: renderer)
        XCTAssertEqual(decodeFrameIndex(after.image), 10, "the renderer stays usable")
    }

    func testImageSequenceReversedShowsTheFirstSelectedImage() async throws {
        let folder = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/sequence_png_12f")
        let seq = try await ImageSequenceLoader.load([folder])
        let frames = [2, 5, 7].map { seq.timeline.frames[$0] }
        let forward = try await sharedRenderer.render(CompositeRequest(source: .imageSequence(seq), frames: frames, blendMode: .normal, maxLongEdge: nil))
        XCTAssertEqual(decodeFrameIndex(forward.image, blockWidth: 20), 7)
        let reversed = try await sharedRenderer.render(CompositeRequest(source: .imageSequence(seq), frames: frames, blendMode: .normal,
                                                                        maxLongEdge: nil, reverseOrder: true))
        XCTAssertEqual(decodeFrameIndex(reversed.image, blockWidth: 20), 2)
        XCTAssertTrue(reversed.stackedInReverse)
        XCTAssertTrue(reversed.deliveredInPresentationOrder)
        XCTAssertNil(reversed.reverseDecode, "stills are simply read in reverse; nothing is held")
        XCTAssertEqual(reversed.framesComposited, 3)
    }

    // MARK: Batch

    func testBatchVariantsHonourOverridesPatternAndReverse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackReverse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = try await loadFixture(.count)
        let frames = clip.timeline.frames
        func settings(reverse: Bool, overrides: FrameOverrides = .none) -> CompositeSettings {
            CompositeSettings(rangeStart: frames[30], rangeEnd: frames[60], samplingKind: .pattern, nth: 2, exactCount: 20,
                              blendMode: .normal, opacity: 1, samplingPattern: SamplingPattern(take: 1, skip: 9),
                              frameOverrides: overrides, reverseOrder: reverse)
        }
        // The pattern picks 30, 40, 50. Excluding 30 and forcing 33 gives 33, 40, 50.
        let overrides = FrameOverrides(excluded: [frames[30]], included: [frames[33]])
        let png = ExportSettings(format: .png, bitDepth: .eight)
        let variants = [
            BatchVariant(name: "Forward", settings: settings(reverse: false), export: png),
            BatchVariant(name: "Reversed", settings: settings(reverse: true), export: png),
            BatchVariant(name: "Edited", settings: settings(reverse: true, overrides: overrides), export: png),
        ]
        XCTAssertEqual(BatchExporter.renderPassCount(for: variants, native: clip.info.displaySize), 3, "each is a different composite")
        let plan = BatchPlan(source: .video(clip.info), timeline: clip.timeline, baseName: "count", folder: directory, variants: variants)
        let summary = await BatchExporter(renderer: sharedRenderer).run(plan) { _ in }
        var shown: [Int] = []
        for output in summary.outputs {
            guard case let .finished(report, _) = output.status else { return XCTFail("\(output.status)") }
            XCTAssertEqual(report.url.lastPathComponent, "count \(output.variant.name) 3f.png")
            let back = try readBackPixels(report.url, bitDepth: .eight)
            // Top row: block b (40 px) is white when bit 7-b of the frame index is set.
            var index = 0
            for b in 0..<8 where back.rgb[(10 * back.width + b * 40 + 20) * 3] > 0.5 { index |= 1 << (7 - b) }
            shown.append(index)
        }
        XCTAssertEqual(shown, [50, 30, 33], "last frame forward; first frame reversed; first surviving frame with overrides")
    }
}

private final class ProgressLog: @unchecked Sendable {
    private var stored: [CompositeProgress] = []
    private let lock = NSLock()
    func add(_ p: CompositeProgress) { lock.lock(); stored.append(p); lock.unlock() }
    var values: [CompositeProgress] { lock.lock(); defer { lock.unlock() }; return stored }
}
