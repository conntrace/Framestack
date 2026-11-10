import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// Temporal range segmentation through the batch exporter: one composite per
/// part, each made of exactly that part's frames.
final class SegmentBatchTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackSegments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The frame number the count fixture writes into its top row.
    private func frameIndex(at url: URL) throws -> Int {
        let back = try readBackPixels(url, bitDepth: .eight)
        var index = 0
        for b in 0..<8 where back.rgb[(10 * back.width + b * 40 + 20) * 3] > 0.5 { index |= 1 << (7 - b) }
        return index
    }

    func testEachPartIsACompositeOfItsOwnFramesFirstToLast() async throws {
        let clip = try await loadFixture(.count)
        let frames = clip.timeline.frames
        // Frames 30…149 in four parts of 30.
        let range = FrameTimeRange(start: frames[30], end: FrameTime(seconds: clip.info.duration.seconds + 1))
        let segments = RangeSegmenter.segments(of: range, in: clip.timeline, count: 4)
        XCTAssertEqual(segments.map(\.frameCount), [30, 30, 30, 30])
        let png = ExportSettings(format: .png, bitDepth: .eight)
        var variants: [BatchVariant] = []
        for reverse in [false, true] {
            for segment in segments {
                let s = CompositeSettings(rangeStart: segment.range.start, rangeEnd: segment.range.end, samplingKind: .all, nth: 2, exactCount: 20,
                                          blendMode: .normal, opacity: 1, reverseOrder: reverse)
                variants.append(BatchVariant(name: "\(reverse ? "First" : "Last") \(RangeSegmenter.label(part: segment.index, of: segments.count))",
                                             settings: s, export: png))
            }
        }
        XCTAssertEqual(BatchExporter.renderPassCount(for: variants, native: clip.info.displaySize), 8, "every part is its own composite")
        let plan = BatchPlan(source: .video(clip.info), timeline: clip.timeline, baseName: "count", folder: directory, variants: variants)
        XCTAssertEqual(BatchExporter.outputs(for: plan).map(\.url.lastPathComponent), [
            "count Last part 1 of 4 30f.png", "count Last part 2 of 4 30f.png", "count Last part 3 of 4 30f.png", "count Last part 4 of 4 30f.png",
            "count First part 1 of 4 30f.png", "count First part 2 of 4 30f.png", "count First part 3 of 4 30f.png", "count First part 4 of 4 30f.png",
        ])
        let summary = await BatchExporter(renderer: sharedRenderer).run(plan) { _ in }
        XCTAssertEqual(summary.finishedCount, 8)
        XCTAssertEqual(summary.rendersPerformed, 8)
        var shown: [Int] = []
        for output in summary.outputs {
            guard case let .finished(report, missing) = output.status else { return XCTFail("\(output.variant.name): \(output.status)") }
            XCTAssertEqual(missing, 0)
            shown.append(try frameIndex(at: report.url))
        }
        XCTAssertEqual(shown, [59, 89, 119, 149, 30, 60, 90, 120], "the last and the first frame of each part")
    }

    func testSamplingAppliesInsideEachPartAndUnevenPartsAreNamedByTheirOwnCounts() async throws {
        let clip = try await loadFixture(.count)
        let frames = clip.timeline.frames
        // Frames 0…99 in three parts: 34, 33, 33. Every 10th frame inside each part.
        let range = FrameTimeRange(start: .zero, end: frames[100])
        let segments = RangeSegmenter.segments(of: range, in: clip.timeline, count: 3)
        XCTAssertEqual(segments.map(\.frameCount), [34, 33, 33])
        let png = ExportSettings(format: .png, bitDepth: .eight)
        let variants = segments.map { segment in
            BatchVariant(name: "Nth \(RangeSegmenter.label(part: segment.index, of: segments.count))",
                         settings: CompositeSettings(rangeStart: segment.range.start, rangeEnd: segment.range.end, samplingKind: .everyNth, nth: 10,
                                                     exactCount: 20, blendMode: .normal, opacity: 1),
                         export: png)
        }
        let plan = BatchPlan(source: .video(clip.info), timeline: clip.timeline, baseName: "count", folder: directory, variants: variants)
        // Part 1: 0, 10, 20, 30 · part 2: 34, 44, 54, 64 · part 3: 67, 77, 87, 97.
        XCTAssertEqual(try variants.map { try BatchExporter.selection(for: $0, in: plan).selectedIndices },
                       [[0, 10, 20, 30], [34, 44, 54, 64], [67, 77, 87, 97]], "the step restarts at each part's first frame")
        let summary = await BatchExporter(renderer: sharedRenderer).run(plan) { _ in }
        XCTAssertEqual(summary.outputs.map(\.url.lastPathComponent), ["count Nth part 1 of 3 4f.png", "count Nth part 2 of 3 4f.png", "count Nth part 3 of 3 4f.png"])
        XCTAssertEqual(summary.finishedCount, 3)
        XCTAssertEqual(try summary.outputs.map { try frameIndex(at: $0.url) }, [30, 64, 97])
    }
}
