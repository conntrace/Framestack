import XCTest
@testable import FrameStackCore

/// Frame-accurate navigation helpers used by the timeline UI: nearest frame,
/// inclusive frame ranges ↔ exclusive time ranges, and handle snapping.
final class TimelineNavigationTests: XCTestCase {
    /// 10 frames at 30 fps: 0/30 … 9/30; duration 10/30.
    let timeline = FrameTimeline(presentationTimes: (0..<10).map { FrameTime(value: Int64($0), timescale: 30) })
    let duration = FrameTime(value: 10, timescale: 30)

    func testNearestIndex() {
        XCTAssertEqual(timeline.nearestIndex(to: FrameTime(seconds: 0)), 0)
        XCTAssertEqual(timeline.nearestIndex(to: FrameTime(seconds: -1)), 0, "before the first frame")
        XCTAssertEqual(timeline.nearestIndex(to: FrameTime(seconds: 99)), 9, "after the last frame")
        XCTAssertEqual(timeline.nearestIndex(to: FrameTime(value: 3, timescale: 30)), 3, "exact")
        XCTAssertEqual(timeline.nearestIndex(to: FrameTime(seconds: 0.11)), 3, "0.11 is nearer 3/30 = 0.1 than 4/30")
        XCTAssertEqual(timeline.nearestIndex(to: FrameTime(seconds: 0.126)), 4)
        XCTAssertEqual(timeline.nearestIndex(to: FrameTime(value: 7, timescale: 60)), 3, "exact midpoint → earlier frame")
        XCTAssertNil(FrameTimeline(presentationTimes: []).nearestIndex(to: .zero))
    }

    func testIndexAtOrBefore() {
        XCTAssertNil(timeline.index(atOrBefore: FrameTime(seconds: -0.001)))
        XCTAssertEqual(timeline.index(atOrBefore: .zero), 0)
        XCTAssertEqual(timeline.index(atOrBefore: FrameTime(value: 5, timescale: 30)), 5)
        XCTAssertEqual(timeline.index(atOrBefore: FrameTime(seconds: 0.17)), 5)
        XCTAssertEqual(timeline.index(atOrBefore: FrameTime(seconds: 5)), 9)
    }

    func testBoundaryAndInclusiveRange() {
        XCTAssertEqual(timeline.boundary(after: 3, end: duration), FrameTime(value: 4, timescale: 30))
        XCTAssertEqual(timeline.boundary(after: 9, end: duration), duration, "last frame → clip duration")

        let r = timeline.range(firstFrame: 2, lastFrame: 5, end: duration)
        XCTAssertEqual(r.start, FrameTime(value: 2, timescale: 30))
        XCTAssertEqual(r.end, FrameTime(value: 6, timescale: 30))
        XCTAssertEqual(timeline.frameIndices(in: r), 2...5, "round-trips to the same inclusive frames")
        XCTAssertEqual(FrameSampler.eligibleIndices(in: timeline, range: r).count, 4)

        // Last frame inclusive reaches the duration.
        let tail = timeline.range(firstFrame: 8, lastFrame: 9, end: duration)
        XCTAssertEqual(tail.end, duration)
        XCTAssertEqual(timeline.frameIndices(in: tail), 8...9)

        // Clamping and ordering.
        XCTAssertEqual(timeline.frameIndices(in: timeline.range(firstFrame: -4, lastFrame: 99, end: duration)), 0...9)
        XCTAssertEqual(timeline.frameIndices(in: timeline.range(firstFrame: 6, lastFrame: 2, end: duration)), 6...6, "last < first → single frame")

        XCTAssertNil(timeline.frameIndices(in: FrameTimeRange(start: FrameTime(seconds: 0.5), end: FrameTime(seconds: 0.9))))
    }

    func testNearestBoundarySnapsToFrameStartsOrDuration() {
        // Boundaries are 0/30, 1/30 … 9/30 and the duration 10/30.
        XCTAssertEqual(timeline.nearestBoundary(to: FrameTime(seconds: 0.101), end: duration), FrameTime(value: 3, timescale: 30))
        XCTAssertEqual(timeline.nearestBoundary(to: FrameTime(seconds: 0.128), end: duration), FrameTime(value: 4, timescale: 30))
        XCTAssertEqual(timeline.nearestBoundary(to: FrameTime(seconds: 0.33), end: duration), duration)
        XCTAssertEqual(timeline.nearestBoundary(to: FrameTime(seconds: 0.31), end: duration), FrameTime(value: 9, timescale: 30))
        XCTAssertEqual(timeline.nearestBoundary(to: FrameTime(seconds: 9), end: duration), duration)
    }

    func testVariableFrameRateUsesActualTimes() {
        let vfr = FrameTimeline(presentationTimes: [0, 10, 11, 50, 51, 52].map { FrameTime(value: Int64($0), timescale: 100) })
        let end = FrameTime(value: 60, timescale: 100)
        XCTAssertEqual(vfr.nearestIndex(to: FrameTime(seconds: 0.3)), 2, "0.30 is 0.19 from 0.11 and 0.20 from 0.50")
        XCTAssertEqual(vfr.nearestIndex(to: FrameTime(seconds: 0.31)), 3, "0.31 is nearer 0.50")
        XCTAssertEqual(vfr.boundary(after: 2, end: end), FrameTime(value: 50, timescale: 100))
        XCTAssertEqual(vfr.frameIndices(in: vfr.range(firstFrame: 1, lastFrame: 2, end: end)), 1...2)
    }
}
