import XCTest
@testable import FrameStackCore

final class FrameTimeTests: XCTestCase {
    func testEqualityAcrossTimescales() {
        let a = FrameTime(value: 1, timescale: 30)
        let b = FrameTime(value: 20, timescale: 600)
        let c = FrameTime(value: 512, timescale: 15_360)
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
        XCTAssertEqual(Set([a, b, c]).count, 1, "equal times must hash identically")
        XCTAssertNotEqual(a, FrameTime(value: 21, timescale: 600))
    }

    func testOrdering() {
        let third = FrameTime(value: 1, timescale: 3)
        XCTAssertLessThan(FrameTime(value: 333, timescale: 1000), third)
        XCTAssertLessThan(third, FrameTime(value: 334, timescale: 1000))
        XCTAssertLessThan(FrameTime(value: -1, timescale: 30), FrameTime.zero)
        XCTAssertEqual(
            [FrameTime(value: 3, timescale: 30), FrameTime(value: 1, timescale: 60), FrameTime(value: 1, timescale: 30)].sorted(),
            [FrameTime(value: 1, timescale: 60), FrameTime(value: 1, timescale: 30), FrameTime(value: 3, timescale: 30)]
        )
    }

    func testComparisonDoesNotOverflow() {
        // value × other timescale exceeds Int64; must still compare exactly.
        let a = FrameTime(value: 9_000_000_000_000_000_000, timescale: 1_000_000_000)
        let b = FrameTime(value: 9_000_000_000_000_000_000, timescale: 999_999_999)
        XCTAssertLessThan(a, b)
        XCTAssertGreaterThan(b, a)
        XCTAssertNotEqual(a, b)
    }

    func testSecondsInitializerIsExactForDecimals() {
        XCTAssertEqual(FrameTime(seconds: 2.0), FrameTime(value: 60, timescale: 30))
        XCTAssertEqual(FrameTime(seconds: 0.1), FrameTime(value: 1, timescale: 10))
        XCTAssertEqual(FrameTime(seconds: 4.966667).value, 4_966_667)
    }

    func testHalfOpenRange() {
        let r = FrameTimeRange(start: FrameTime(value: 1, timescale: 30), end: FrameTime(value: 2, timescale: 30))
        XCTAssertTrue(r.contains(FrameTime(value: 1, timescale: 30)), "start is inclusive")
        XCTAssertFalse(r.contains(FrameTime(value: 2, timescale: 30)), "end is exclusive")
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(FrameTimeRange(start: .zero, end: .zero).isEmpty)
    }

    func testCodableRoundTrip() throws {
        let t = FrameTime(value: 1001, timescale: 30_000)
        let data = try JSONEncoder().encode(t)
        XCTAssertEqual(try JSONDecoder().decode(FrameTime.self, from: data), t)
    }
}
