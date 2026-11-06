import XCTest
@testable import FrameStackCore

final class FrameSamplerTests: XCTestCase {
    /// 5 s at 30 fps: timestamps 0/30 … 149/30.
    let cfr150 = FrameTimeline(presentationTimes: (0..<150).map { FrameTime(value: Int64($0), timescale: 30) })

    func seconds(_ s: Double) -> FrameTime { FrameTime(seconds: s) }
    var fullRange: FrameTimeRange { FrameTimeRange(start: .zero, end: seconds(5)) }

    // MARK: PRD §1 core example / §11.2 acceptance numbers

    func testAllEveryNthOnFullClip() throws {
        XCTAssertEqual(try FrameSampler.select(from: cfr150, range: fullRange, mode: .all).selectedCount, 150)
        let n2 = try FrameSampler.select(from: cfr150, range: fullRange, mode: .everyNth(2))
        XCTAssertEqual(n2.selectedCount, 75)
        XCTAssertEqual(n2.selectedIndices.first, 0)
        XCTAssertEqual(n2.selectedIndices.last, 148)
        XCTAssertEqual(try FrameSampler.select(from: cfr150, range: fullRange, mode: .everyNth(3)).selectedCount, 50)
    }

    func testTwoToFiveSecondsRange() throws {
        let range = FrameTimeRange(start: seconds(2), end: seconds(5))
        let all = try FrameSampler.select(from: cfr150, range: range, mode: .all)
        XCTAssertEqual(all.eligibleCount, 90)
        XCTAssertEqual(all.eligibleIndices, 60..<150)
        let n3 = try FrameSampler.select(from: cfr150, range: range, mode: .everyNth(3))
        XCTAssertEqual(n3.selectedCount, 30)
        XCTAssertEqual(n3.selectedIndices.first, 60)
        XCTAssertEqual(n3.selectedIndices.last, 147)
        XCTAssertEqual(n3.selectedTimes(in: cfr150).first, FrameTime(value: 2, timescale: 1))
    }

    func testExactTwentyIncludesEndpointsWithEvenSpacing() throws {
        let r = try FrameSampler.select(from: cfr150, range: fullRange, mode: .exactCount(20))
        XCTAssertEqual(r.selectedCount, 20)
        XCTAssertEqual(r.selectedIndices.first, 0)
        XCTAssertEqual(r.selectedIndices.last, 149)
        XCTAssertEqual(Set(r.selectedIndices).count, 20, "no duplicates")
        let gaps = zip(r.selectedIndices.dropFirst(), r.selectedIndices).map { $0 - $1 }
        XCTAssertEqual(Set(gaps), [7, 8], "149/19 ≈ 7.84 → gaps of 7 or 8")
        XCTAssertTrue(r.notices.isEmpty)
    }

    func testExactCountOneSelectsMidpoint() throws {
        XCTAssertEqual(try FrameSampler.select(from: cfr150, range: fullRange, mode: .exactCount(1)).selectedIndices, [74])
        XCTAssertEqual(try FrameSampler.selectPositions(eligibleCount: 5, mode: .exactCount(1)).positions, [2])
        XCTAssertEqual(try FrameSampler.selectPositions(eligibleCount: 1, mode: .exactCount(1)).positions, [0])
    }

    func testExactCountLargerThanEligibleClampsWithNotice() throws {
        let r = try FrameSampler.select(from: cfr150, range: fullRange, mode: .exactCount(151))
        XCTAssertEqual(r.selectedIndices, Array(0..<150), "never duplicates frames")
        XCTAssertEqual(r.notices, [.exactCountClamped(requested: 151, available: 150)])
        let exact = try FrameSampler.select(from: cfr150, range: fullRange, mode: .exactCount(150))
        XCTAssertEqual(exact.selectedCount, 150)
        XCTAssertTrue(exact.notices.isEmpty)
    }

    func testInvalidParameters() {
        XCTAssertThrowsError(try FrameSampler.select(from: cfr150, range: fullRange, mode: .everyNth(0))) {
            XCTAssertEqual($0 as? SamplingError, .invalidInterval(0))
        }
        XCTAssertThrowsError(try FrameSampler.select(from: cfr150, range: fullRange, mode: .exactCount(0))) {
            XCTAssertEqual($0 as? SamplingError, .invalidCount(0))
        }
        XCTAssertThrowsError(try FrameSampler.select(from: cfr150, range: FrameTimeRange(start: seconds(3), end: seconds(3)), mode: .all)) {
            XCTAssertEqual($0 as? SamplingError, .emptyRange)
        }
        XCTAssertThrowsError(try FrameSampler.select(from: cfr150, range: FrameTimeRange(start: seconds(4), end: seconds(3)), mode: .all)) {
            XCTAssertEqual($0 as? SamplingError, .emptyRange)
        }
        XCTAssertThrowsError(try FrameSampler.select(from: cfr150, range: FrameTimeRange(start: seconds(10), end: seconds(11)), mode: .all)) {
            XCTAssertEqual($0 as? SamplingError, .noEligibleFrames)
        }
    }

    // MARK: Boundaries

    func testExactBoundaries() throws {
        let oneFrame = FrameTimeRange(start: FrameTime(value: 1, timescale: 30), end: FrameTime(value: 2, timescale: 30))
        XCTAssertEqual(try FrameSampler.select(from: cfr150, range: oneFrame, mode: .all).selectedIndices, [1])

        let endAtLastFrame = FrameTimeRange(start: .zero, end: FrameTime(value: 149, timescale: 30))
        XCTAssertEqual(try FrameSampler.select(from: cfr150, range: endAtLastFrame, mode: .all).selectedIndices.last, 148,
                       "a frame exactly at the end is excluded")

        // Different timescale expressing the same instant.
        let startMid = FrameTimeRange(start: FrameTime(value: 1001, timescale: 600), end: seconds(5))
        // 1001/600 s = 1.66833… → first frame at or after it is 51/30 = 1.7 s.
        XCTAssertEqual(try FrameSampler.select(from: cfr150, range: startMid, mode: .all).eligibleIndices.first, 51)
    }

    // MARK: Variable frame rate, ordering and duplicates

    func testVariableFrameRateUsesActualTimestamps() throws {
        let vfr = FrameTimeline(presentationTimes: [0, 0.03, 0.05, 0.1, 0.2, 0.21, 0.5].map { FrameTime(seconds: $0) })
        let r = try FrameSampler.select(from: vfr, range: FrameTimeRange(start: seconds(0.05), end: seconds(0.21)), mode: .all)
        XCTAssertEqual(r.selectedIndices, [2, 3, 4])
        let k2 = try FrameSampler.select(from: vfr, range: FrameTimeRange(start: seconds(0.05), end: seconds(0.21)), mode: .exactCount(2))
        XCTAssertEqual(k2.selectedIndices, [2, 4])
    }

    func testTimelineSortsAndDropsDuplicateTimestamps() {
        let t = FrameTimeline(presentationTimes: [
            FrameTime(value: 2, timescale: 30),
            FrameTime(value: 0, timescale: 30),
            FrameTime(value: 1, timescale: 30),
            FrameTime(value: 20, timescale: 600), // same instant as 1/30
        ])
        XCTAssertEqual(t.frames, [0, 1, 2].map { FrameTime(value: $0, timescale: 30) })
        XCTAssertEqual(t.duplicateTimestampsDropped, 1)
    }

    // MARK: Exhaustive distribution properties

    func testExactCountDistributionProperties() throws {
        for m in 1...80 {
            for k in 1...m {
                let p = try FrameSampler.selectPositions(eligibleCount: m, mode: .exactCount(k)).positions
                XCTAssertEqual(p.count, k, "m=\(m) k=\(k)")
                XCTAssertTrue(zip(p.dropFirst(), p).allSatisfy { $0 > $1 }, "strictly increasing m=\(m) k=\(k)")
                XCTAssertTrue(p.allSatisfy { (0..<m).contains($0) })
                if k > 1 {
                    XCTAssertEqual(p.first, 0)
                    XCTAssertEqual(p.last, m - 1)
                    let gaps = zip(p.dropFirst(), p).map { $0 - $1 }
                    XCTAssertLessThanOrEqual(gaps.max()! - gaps.min()!, 1, "evenly spaced m=\(m) k=\(k)")
                }
            }
        }
    }

    func testEveryNthProperties() throws {
        for m in 1...50 {
            for n in 1...12 {
                let p = try FrameSampler.selectPositions(eligibleCount: m, mode: .everyNth(n)).positions
                XCTAssertEqual(p.count, (m + n - 1) / n)
                XCTAssertEqual(p.first, 0)
                XCTAssertTrue(p.enumerated().allSatisfy { $0.element == $0.offset * n })
            }
        }
    }
}
