import XCTest
@testable import FrameStackCore

/// M6h: take/skip pattern sampling, per-frame overrides, stacking order.
final class FrameOverridesTests: XCTestCase {
    /// 5 s at 30 fps: timestamps 0/30 … 149/30.
    let cfr150 = FrameTimeline(presentationTimes: (0..<150).map { FrameTime(value: Int64($0), timescale: 30) })
    func t(_ frame: Int) -> FrameTime { FrameTime(value: Int64(frame), timescale: 30) }
    var fullRange: FrameTimeRange { FrameTimeRange(start: .zero, end: FrameTime(seconds: 5)) }

    // MARK: Pattern

    func testPatternTakesThenSkipsFromTheFirstFrame() throws {
        XCTAssertEqual(try FrameSampler.selectPositions(eligibleCount: 10, mode: .pattern(take: 2, skip: 3)).positions, [0, 1, 5, 6])
        XCTAssertEqual(try FrameSampler.selectPositions(eligibleCount: 7, mode: .pattern(take: 3, skip: 1)).positions, [0, 1, 2, 4, 5, 6])
        XCTAssertEqual(try FrameSampler.selectPositions(eligibleCount: 4, mode: .pattern(take: 5, skip: 5)).positions, [0, 1, 2, 3],
                       "a take longer than the range selects all of it")
        XCTAssertEqual(try FrameSampler.selectPositions(eligibleCount: 6, mode: .pattern(take: 2, skip: 0)).positions, Array(0..<6),
                       "skip 0 is every frame")
        for n in 1...7 {
            XCTAssertEqual(try FrameSampler.selectPositions(eligibleCount: 50, mode: .pattern(take: 1, skip: n - 1)).positions,
                           try FrameSampler.selectPositions(eligibleCount: 50, mode: .everyNth(n)).positions, "take 1, skip n-1 = every nth (\(n))")
        }
        XCTAssertTrue(try FrameSampler.selectPositions(eligibleCount: 10, mode: .pattern(take: 2, skip: 3)).notices.isEmpty)
    }

    func testPatternStartsAtTheRangeStart() throws {
        let range = FrameTimeRange(start: FrameTime(seconds: 2), end: FrameTime(seconds: 5))
        let r = try FrameSampler.select(from: cfr150, range: range, mode: .pattern(take: 2, skip: 8))
        XCTAssertEqual(r.selectedCount, 18)
        XCTAssertEqual(Array(r.selectedIndices.prefix(4)), [60, 61, 70, 71])
        XCTAssertEqual(r.selectedIndices.last, 141)
    }

    func testInvalidPatternsThrow() {
        XCTAssertThrowsError(try FrameSampler.selectPositions(eligibleCount: 10, mode: .pattern(take: 0, skip: 1))) {
            XCTAssertEqual($0 as? SamplingError, .invalidPattern(take: 0, skip: 1))
        }
        XCTAssertThrowsError(try FrameSampler.selectPositions(eligibleCount: 10, mode: .pattern(take: 1, skip: -1))) {
            XCTAssertEqual($0 as? SamplingError, .invalidPattern(take: 1, skip: -1))
        }
        XCTAssertEqual(SamplingError.invalidPattern(take: 0, skip: 1).errorDescription,
                       "A pattern takes at least 1 frame and skips 0 or more (got take 0, skip 1).")
    }

    // MARK: Overrides

    func testOverridesNormaliseAndRoundTrip() throws {
        let o = FrameOverrides(excluded: [t(9), t(3), t(9), t(5)], included: [t(7), t(5), t(1), t(7)])
        XCTAssertEqual(o.excluded, [t(3), t(5), t(9)], "sorted, unique")
        XCTAssertEqual(o.included, [t(1), t(7)], "a time in both lists is excluded")
        XCTAssertEqual(o.count, 5)
        XCTAssertFalse(o.isEmpty)
        XCTAssertTrue(FrameOverrides.none.isEmpty)
        XCTAssertEqual(o.state(of: t(5)), .excluded)
        XCTAssertEqual(o.state(of: t(7)), .included)
        XCTAssertEqual(o.state(of: t(2)), .auto)
        XCTAssertEqual(o.state(of: FrameTime(value: 10, timescale: 60)), .excluded, "times compare by value, not by timescale")

        let back = try JSONDecoder().decode(FrameOverrides.self, from: JSONEncoder().encode(o))
        XCTAssertEqual(back, o)
        XCTAssertEqual(try JSONDecoder().decode(FrameOverrides.self, from: Data("{}".utf8)), .none)
        let messy = try JSONDecoder().decode(FrameOverrides.self, from: JSONEncoder().encode(Messy(excluded: [t(4), t(2), t(4)], included: [t(2)])))
        XCTAssertEqual(messy, FrameOverrides(excluded: [t(2), t(4)]), "a hand-edited file is normalised on load")
    }

    private struct Messy: Encodable { let excluded: [FrameTime]; let included: [FrameTime] }

    func testSettingAnOverrideMovesTheFrameBetweenLists() {
        var o = FrameOverrides.none
        o.set(.excluded, for: t(8))
        o.set(.excluded, for: t(2))
        o.set(.included, for: t(5))
        XCTAssertEqual(o.excluded, [t(2), t(8)])
        o.set(.included, for: t(8))
        XCTAssertEqual(o.excluded, [t(2)])
        XCTAssertEqual(o.included, [t(5), t(8)])
        o.set(.excluded, for: t(5))
        XCTAssertEqual(o, FrameOverrides(excluded: [t(2), t(5)], included: [t(8)]))
        o.set(.auto, for: t(2))
        o.set(.auto, for: t(5))
        o.set(.auto, for: t(8))
        o.set(.auto, for: t(99))
        XCTAssertEqual(o, .none)
    }

    func testExcludedFramesAreRemovedAndNeverReplaced() throws {
        // Every 3rd of 150 picks 0, 3, 6, …; excluding 3 and 6 leaves a gap,
        // excluding 4 (not picked) changes nothing.
        let o = FrameOverrides(excluded: [t(3), t(6), t(4)])
        let r = try FrameSampler.select(from: cfr150, range: fullRange, mode: .everyNth(3), overrides: o)
        XCTAssertEqual(r.selectedCount, 48)
        XCTAssertEqual(Array(r.selectedIndices.prefix(3)), [0, 9, 12])
        XCTAssertEqual(r.excludedIndices, [3, 4, 6])
        XCTAssertEqual(r.removedByOverride, 2)
        XCTAssertEqual(r.addedByOverride, 0)
        XCTAssertEqual(r.inactiveOverrides, 0)
        XCTAssertEqual(r.eligibleCount, 150, "the range is unaffected")
    }

    func testIncludedFramesAreAddedInTimeOrder() throws {
        let o = FrameOverrides(included: [t(4), t(3), t(149)])
        let r = try FrameSampler.select(from: cfr150, range: fullRange, mode: .everyNth(3), overrides: o)
        XCTAssertEqual(r.selectedCount, 52)
        XCTAssertEqual(Array(r.selectedIndices.prefix(4)), [0, 3, 4, 6])
        XCTAssertEqual(r.selectedIndices.last, 149)
        XCTAssertEqual(r.selectedIndices, r.selectedIndices.sorted())
        XCTAssertEqual(Set(r.selectedIndices).count, r.selectedCount)
        XCTAssertEqual(r.forcedIndices, [3, 4, 149])
        XCTAssertEqual(r.addedByOverride, 2, "frame 3 was already picked")
        XCTAssertEqual(r.removedByOverride, 0)

        let exact = try FrameSampler.select(from: cfr150, range: fullRange, mode: .exactCount(20), overrides: FrameOverrides(excluded: [t(0)], included: [t(1)]))
        XCTAssertEqual(exact.selectedCount, 20, "one removed, one added")
        XCTAssertEqual(exact.selectedIndices.first, 1)
    }

    func testOverridesOutsideTheRangeOrOffTheTimelineAreInactive() throws {
        let range = FrameTimeRange(start: FrameTime(seconds: 2), end: FrameTime(seconds: 3))
        let o = FrameOverrides(excluded: [t(10), t(60), FrameTime(value: 121, timescale: 60)], included: [t(90), t(100)])
        let r = try FrameSampler.select(from: cfr150, range: range, mode: .all, overrides: o)
        XCTAssertEqual(r.eligibleIndices, 60..<90)
        XCTAssertEqual(r.selectedIndices, Array(61..<90), "only frame 60 is excluded; frame 90 is the excluded range end")
        XCTAssertEqual(r.excludedIndices, [60])
        XCTAssertEqual(r.forcedIndices, [])
        XCTAssertEqual(r.inactiveOverrides, 4)
        // Widening the range brings them back into effect.
        let wide = try FrameSampler.select(from: cfr150, range: fullRange, mode: .everyNth(50), overrides: o)
        XCTAssertEqual(wide.selectedIndices, [0, 50, 90, 100], "every 50th picks 0, 50, 100; frame 90 is forced in")
        XCTAssertEqual(wide.inactiveOverrides, 1, "the half-frame timestamp matches no frame")
    }

    func testExcludingEverySelectedFrameIsAnErrorNotAnEmptyComposite() {
        let range = FrameTimeRange(start: .zero, end: t(3))
        let o = FrameOverrides(excluded: [t(0), t(1), t(2)])
        XCTAssertThrowsError(try FrameSampler.select(from: cfr150, range: range, mode: .all, overrides: o)) {
            XCTAssertEqual($0 as? SamplingError, .allFramesExcluded(excluded: 3))
            XCTAssertEqual(($0 as? SamplingError)?.errorDescription,
                           "Every selected frame is excluded (3 excluded in this range). Clear an exclusion or change the sampling.")
        }
        // An inclusion rescues it.
        let rescued = FrameOverrides(excluded: [t(0), t(2)], included: [t(1)])
        XCTAssertEqual(try FrameSampler.select(from: cfr150, range: range, mode: .exactCount(1), overrides: rescued).selectedIndices, [1])
    }

    func testNoOverridesIsIdenticalToTheOldSelection() throws {
        for mode: SamplingMode in [.all, .everyNth(7), .exactCount(13), .pattern(take: 2, skip: 2)] {
            let plain = try FrameSampler.select(from: cfr150, range: fullRange, mode: mode)
            let none = try FrameSampler.select(from: cfr150, range: fullRange, mode: mode, overrides: .none)
            XCTAssertEqual(plain, none)
            XCTAssertEqual(plain.excludedIndices, [])
            XCTAssertEqual(plain.forcedIndices, [])
        }
    }

    // MARK: Settings

    private var base: CompositeSettings {
        CompositeSettings(rangeStart: .zero, rangeEnd: FrameTime(seconds: 5), samplingKind: .pattern, nth: 2, exactCount: 20,
                          blendMode: .normal, opacity: 0.5, samplingPattern: SamplingPattern(take: 2, skip: 3),
                          frameOverrides: FrameOverrides(excluded: [t(0)], included: [t(2)]), reverseOrder: true)
    }

    func testSettingsSelectionAppliesPatternAndOverrides() throws {
        let r = try base.selection(in: cfr150)
        XCTAssertEqual(Array(r.selectedIndices.prefix(4)), [1, 2, 5, 6])
        XCTAssertEqual(r.selectedCount, 60)
        XCTAssertEqual(base.samplingMode, .pattern(take: 2, skip: 3))
        XCTAssertEqual(SamplingPattern(take: 2, skip: 3).summary, "take 2, skip 3")
        XCTAssertEqual(SamplingKind.pattern.displayName, "Pattern")
    }

    func testSettingsRoundTripAndOlderFilesDecodeWithDefaults() throws {
        let data = try JSONEncoder().encode(base)
        XCTAssertEqual(try JSONDecoder().decode(CompositeSettings.self, from: data), base)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["samplingPattern", "frameOverrides", "reverseOrder"] {
            XCTAssertNotNil(object.removeValue(forKey: key), key)
        }
        object["samplingKind"] = "everyNth"
        let old = try JSONDecoder().decode(CompositeSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.samplingPattern, .default)
        XCTAssertEqual(old.frameOverrides, .none)
        XCTAssertFalse(old.reverseOrder)
        XCTAssertEqual(old.opacity, 0.5)
    }

    func testCompositingPartKeepsReverseOnlyWhereItChangesTheResult() {
        var a = base
        var b = base
        b.reverseOrder = false
        XCTAssertNotEqual(a.compositingPart, b.compositingPart, "Normal depends on the order")
        for mode in BlendMode.allCases {
            a.blendMode = mode
            b.blendMode = mode
            XCTAssertEqual(a.compositingPart == b.compositingPart, !mode.isOrderDependent, "\(mode)")
        }
        // Overrides and the pattern change which frames are composited.
        var c = base
        c.frameOverrides = .none
        XCTAssertNotEqual(base.compositingPart, c.compositingPart)
        var d = base
        d.samplingPattern.skip = 4
        XCTAssertNotEqual(base.compositingPart, d.compositingPart)
    }
}
