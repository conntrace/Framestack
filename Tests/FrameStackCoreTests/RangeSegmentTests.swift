@testable import FrameStackCore
import XCTest

final class RangeSegmentTests: XCTestCase {
    /// 150 frames at exactly 30 fps (timestamps k/30).
    private var thirtyFPS: FrameTimeline {
        FrameTimeline(presentationTimes: (0..<150).map { FrameTime(value: Int64($0), timescale: 30) })
    }

    private func whole(_ seconds: Double = 5) -> FrameTimeRange {
        FrameTimeRange(start: .zero, end: FrameTime(seconds: seconds))
    }

    func testEqualPartsCoverTheRangeWithoutGapOrOverlap() throws {
        let timeline = thirtyFPS
        let segments = RangeSegmenter.segments(of: whole(), in: timeline, count: 5)
        XCTAssertEqual(segments.map(\.frameCount), [30, 30, 30, 30, 30])
        XCTAssertEqual(segments.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(segments.first?.range.start, .zero)
        XCTAssertEqual(segments.last?.range.end, FrameTime(seconds: 5))
        for (a, b) in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(a.range.end, b.range.start, "half-open segments touch")
        }
        // Each part selects exactly its own frames; together they are the range's frames, once each.
        var seen: [FrameTime] = []
        for (k, segment) in segments.enumerated() {
            let result = try FrameSampler.select(from: timeline, range: segment.range, mode: .all)
            XCTAssertEqual(result.selectedIndices, Array((k * 30)..<((k + 1) * 30)))
            seen += result.selectedTimes(in: timeline)
        }
        XCTAssertEqual(seen, timeline.frames)
        XCTAssertEqual(RangeSegmenter.summary(of: segments), "5 parts of 30 frames")
    }

    func testUnevenCountsGiveTheEarlierPartsOneFrameMore() {
        let timeline = FrameTimeline(presentationTimes: (0..<10).map { FrameTime(value: Int64($0), timescale: 10) })
        let segments = RangeSegmenter.segments(of: whole(1), in: timeline, count: 3)
        XCTAssertEqual(segments.map(\.frameCount), [4, 3, 3])
        XCTAssertEqual(segments.map(\.range.start), [.zero, FrameTime(value: 4, timescale: 10), FrameTime(value: 7, timescale: 10)])
        XCTAssertEqual(RangeSegmenter.summary(of: segments), "3 parts of 3 or 4 frames")
    }

    func testCountIsClampedToTheFramesAndToTheMaximum() {
        let timeline = thirtyFPS
        let four = FrameTimeRange(start: FrameTime(value: 10, timescale: 30), end: FrameTime(value: 14, timescale: 30))
        let perFrame = RangeSegmenter.segments(of: four, in: timeline, count: 9)
        XCTAssertEqual(perFrame.map(\.frameCount), [1, 1, 1, 1], "never more parts than frames")
        XCTAssertEqual(RangeSegmenter.summary(of: perFrame), "4 parts of 1 frame")

        for count in [1, 0, -3] {
            let one = RangeSegmenter.segments(of: whole(), in: timeline, count: count)
            XCTAssertEqual(one, [RangeSegment(index: 0, range: whole(), frameCount: 150)], "count \(count) is the range itself")
        }
        XCTAssertEqual(RangeSegmenter.segments(of: whole(), in: timeline, count: 1000).count, RangeSegmenter.maximumCount)
        XCTAssertEqual(RangeSegmenter.segments(of: whole(), in: timeline, count: 1000).map(\.frameCount).reduce(0, +), 150)
    }

    func testEmptyRangesAndRangesBetweenFramesHaveNoSegments() {
        let timeline = thirtyFPS
        XCTAssertEqual(RangeSegmenter.segments(of: FrameTimeRange(start: FrameTime(seconds: 2), end: FrameTime(seconds: 2)), in: timeline, count: 4), [])
        XCTAssertEqual(RangeSegmenter.segments(of: FrameTimeRange(start: FrameTime(seconds: 9), end: FrameTime(seconds: 12)), in: timeline, count: 4), [])
        XCTAssertEqual(RangeSegmenter.segments(of: whole(), in: FrameTimeline(presentationTimes: []), count: 4), [])
        XCTAssertEqual(RangeSegmenter.summary(of: []), "No frames in the range")
    }

    func testIrregularTimestampsSplitByFrameCountAndKeepTheRangeEnds() throws {
        // Variable frame rate: gaps of 10, 10, 50, 10, 200, 10 ms.
        let ms: [Int64] = [0, 10, 20, 70, 80, 280, 290]
        let timeline = FrameTimeline(presentationTimes: ms.map { FrameTime(value: $0, timescale: 1000) })
        // The range starts between frames 0 and 1 and ends after the last frame.
        let range = FrameTimeRange(start: FrameTime(value: 5, timescale: 1000), end: FrameTime(value: 400, timescale: 1000))
        let segments = RangeSegmenter.segments(of: range, in: timeline, count: 3)
        XCTAssertEqual(segments.map(\.frameCount), [2, 2, 2])
        XCTAssertEqual(segments[0].range, FrameTimeRange(start: range.start, end: FrameTime(value: 70, timescale: 1000)),
                       "the first part keeps the range's own start")
        XCTAssertEqual(segments[1].range, FrameTimeRange(start: FrameTime(value: 70, timescale: 1000), end: FrameTime(value: 280, timescale: 1000)))
        XCTAssertEqual(segments[2].range, FrameTimeRange(start: FrameTime(value: 280, timescale: 1000), end: range.end))
        XCTAssertEqual(try FrameSampler.select(from: timeline, range: segments[1].range, mode: .all).selectedIndices, [3, 4])
    }

    func testLabelsSortInTimeOrder() {
        XCTAssertEqual(RangeSegmenter.label(part: 0, of: 5), "part 1 of 5")
        XCTAssertEqual(RangeSegmenter.label(part: 2, of: 12), "part 03 of 12")
        XCTAssertEqual(RangeSegmenter.label(part: 11, of: 12), "part 12 of 12")
        let labels = (0..<12).map { RangeSegmenter.label(part: $0, of: 12) }
        XCTAssertEqual(labels.sorted(), labels)
    }
}

final class StarterPresetTests: XCTestCase {
    private var worked: CompositeSettings {
        CompositeSettings(
            rangeStart: FrameTime(seconds: 1), rangeEnd: FrameTime(seconds: 4), samplingKind: .pattern, nth: 7, exactCount: 33,
            blendMode: .screen, opacity: 0.4,
            alignment: AlignmentSettings(enabled: true, mode: .perspective, reference: .frame(FrameTime(seconds: 2))),
            geometry: GeometrySettings(rotationDegrees: 1.5, crop: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), edgeFill: .white),
            weighting: WeightCurve(preset: .early),
            motionMask: MotionMaskSettings(enabled: true, background: .frame(FrameTime(seconds: 2)), threshold: 0.3, feather: 5, cleanup: 3, invert: true),
            paintedMask: PaintedMaskSettings(enabled: true, strokes: [MaskStroke(points: [.init(x: 0.5, y: 0.5)], radius: 0.1)], invert: false),
            color: ColorAdjustments(exposure: 0.5, contrast: 0.1, saturation: 0.2, temperature: 0, tint: 0),
            samplingPattern: SamplingPattern(take: 2, skip: 5),
            frameOverrides: FrameOverrides(excluded: [FrameTime(seconds: 2)]),
            reverseOrder: true
        )
    }

    func testTheBuiltInSetIsStableAndDistinct() {
        let all = StarterPreset.all
        XCTAssertEqual(all.map(\.name), ["Long Exposure", "Light Trails", "Dark Trails", "Empty Scene", "Action Sequence", "Fading Echo"])
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertTrue(all.allSatisfy { !$0.summary.isEmpty })
        // No two starters produce the same settings from the same document.
        let plain = CompositeSettings(rangeStart: .zero, rangeEnd: FrameTime(seconds: 1), samplingKind: .all, nth: 2, exactCount: 20,
                                      blendMode: .average, opacity: 1)
        let results = all.map { $0.apply(to: plain, framesInRange: nil).settings }
        for i in results.indices {
            for j in results.indices where j > i { XCTAssertNotEqual(results[i], results[j], "\(all[i].name) vs \(all[j].name)") }
            for j in all.indices { XCTAssertEqual(all[j].matches(results[i]), i == j, "\(all[j].name) on \(all[i].name)") }
        }
        XCTAssertTrue(all[0].matches(plain), "a new document is a long exposure")
    }

    func testApplyChangesOnlySamplingBlendWeightingAndTheMotionSwitch() {
        let document = worked
        let action = StarterPreset.all.first { $0.id == "action-sequence" }!
        let applied = action.apply(to: document, framesInRange: 90)
        var expected = document
        expected.samplingKind = .exactCount
        expected.exactCount = 8
        expected.blendMode = .normal
        expected.opacity = 1
        expected.reverseOrder = false
        expected.weighting = .flat
        expected.motionMask.enabled = true
        expected.motionMask.background = .median
        expected.motionMask.invert = false
        XCTAssertEqual(applied.settings, expected, "range, nth, pattern, alignment, geometry, colour, strokes, overrides and the mask's tuning stay")
        XCTAssertEqual(applied.settings.motionMask.threshold, 0.3)
        XCTAssertEqual(applied.notices, ["Kept from this document: everything but sampling, blend, weighting and the motion mask."])
        XCTAssertTrue(action.matches(applied.settings))
        XCTAssertFalse(action.matches(document))

        // A starter without the mask only switches it off; its background choice stays for later.
        let trails = StarterPreset.all.first { $0.id == "light-trails" }!.apply(to: document, framesInRange: 90).settings
        XCTAssertFalse(trails.motionMask.enabled)
        XCTAssertEqual(trails.motionMask.background, .frame(FrameTime(seconds: 2)))
        XCTAssertTrue(trails.motionMask.invert)
        XCTAssertEqual(trails.samplingKind, .all)
        XCTAssertEqual(trails.exactCount, 33, "a parameter the starter does not use is left alone")
        XCTAssertEqual(trails.blendMode, .lighten)
    }

    func testAStarterAskingForMoreFramesThanTheRangeHoldsSaysSo() {
        let empty = StarterPreset.all.first { $0.id == "empty-scene" }!
        XCTAssertEqual(empty.apply(to: worked, framesInRange: 10).notices, [
            "Exact Count 25 is more than the 10 frames in this range; all 10 are used.",
            "Kept from this document: everything but sampling, blend, weighting and the motion mask.",
        ])
        XCTAssertEqual(empty.apply(to: worked, framesInRange: 25).notices.count, 1)
    }
}
