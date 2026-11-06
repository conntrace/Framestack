@testable import FrameStackCore
import XCTest

final class MedianTests: XCTestCase {
    private func image(_ values: [Float]) -> LinearImage {
        // One row, values.count / 4 pixels.
        LinearImage(width: values.count / 4, height: 1, pixels: values)
    }

    func testMedianOfOddAndEvenCounts() {
        var a: [Float] = [5, 1, 4, 2, 3]
        a.withUnsafeMutableBufferPointer { XCTAssertEqual(MedianBandAccumulator.median($0), 3) }
        var b: [Float] = [4, 1, 3, 2]
        b.withUnsafeMutableBufferPointer { XCTAssertEqual(MedianBandAccumulator.median($0), 2.5, "mean of the two middle values") }
        var c: [Float] = [7]
        c.withUnsafeMutableBufferPointer { XCTAssertEqual(MedianBandAccumulator.median($0), 7) }
        var d: [Float] = [1, 1, 1, 9, 9]
        d.withUnsafeMutableBufferPointer { XCTAssertEqual(MedianBandAccumulator.median($0), 1) }
        var e: [Float] = [.nan, 0, 1, 2]
        e.withUnsafeMutableBufferPointer { XCTAssertEqual(MedianBandAccumulator.median($0), 1.5, "NaN sorts last") }
        // Random vectors agree with a full sort.
        var rng = SystemRandomNumberGenerator()
        for n in [2, 3, 10, 101, 256] {
            var v = (0..<n).map { _ in Float.random(in: 0...1, using: &rng) }
            let sorted = v.sorted()
            let expected = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
            v.withUnsafeMutableBufferPointer { XCTAssertEqual(MedianBandAccumulator.median($0), expected, accuracy: 1e-6, "n = \(n)") }
        }
    }

    func testBandAccumulatorMedianPerSample() throws {
        let acc = MedianBandAccumulator(width: 2, height: 1, frameCapacity: 3)
        try acc.add(image([0, 0, 0, 1, 0.9, 0.9, 0.9, 1]))
        try acc.add(image([1, 1, 1, 1, 0.1, 0.1, 0.1, 1]))
        try acc.add(image([0.2, 0.3, 0.4, 1, 0.5, 0.5, 0.5, 1]))
        XCTAssertEqual(acc.count, 3)
        XCTAssertFalse(acc.usesWeights)
        let out = try acc.result()
        XCTAssertEqual(out.pixel(x: 0, y: 0), SIMD4(0.2, 0.3, 0.4, 1))
        XCTAssertEqual(out.pixel(x: 1, y: 0), SIMD4(0.5, 0.5, 0.5, 1))
        XCTAssertThrowsError(try acc.add(image([0, 0, 0, 1, 0, 0, 0, 1]))) {
            XCTAssertEqual($0 as? CompositingError, .historyFull(capacity: 3))
        }
        XCTAssertEqual(acc.memoryFootprintBytes, 2 * 4 * 3 * 4)
    }

    func testMedianPlanRespectsTheBudget() {
        let plan = MedianPlan(outputSize: PixelSize(width: 1920, height: 1080), frameCount: 600, memoryBudgetBytes: 1 << 30)
        // 1 GiB / (1920 × 16 B × 600) = 58 rows per band.
        XCTAssertEqual(plan.bandRows, 58)
        XCTAssertEqual(plan.passes, 19)
        XCTAssertEqual(plan.rows(ofPass: 0), 0..<58)
        XCTAssertEqual(plan.rows(ofPass: 18), 1044..<1080, "last band is shorter")
        XCTAssertLessThanOrEqual(plan.bandHistoryBytes, 1 << 30)
        let small = MedianPlan(outputSize: PixelSize(width: 320, height: 180), frameCount: 150)
        XCTAssertEqual(small.passes, 1, "a small preview fits in one pass")
        let tiny = MedianPlan(outputSize: PixelSize(width: 4000, height: 3000), frameCount: 100_000, memoryBudgetBytes: 1 << 20)
        XCTAssertEqual(tiny.bandRows, 1, "never below one row, however many frames")
        XCTAssertEqual(tiny.passes, 3000)
    }

    func testLuminanceExtremumKeepsWholePixels() throws {
        // Frame A: red-ish (0.9, 0, 0) → Y 0.191; frame B: dim gray (0.3, 0.3, 0.3) → Y 0.3; frame C: blue (0, 0, 1) → Y 0.072.
        let a = image([0.9, 0, 0, 1]), b = image([0.3, 0.3, 0.3, 1]), c = image([0, 0, 1, 1])
        let maxL = LuminanceExtremumReducer(width: 1, height: 1, kind: .maximum)
        for f in [a, b, c] { try maxL.add(f) }
        XCTAssertEqual(try maxL.result().pixel(x: 0, y: 0), SIMD4(0.3, 0.3, 0.3, 1), "the brightest frame's colour, not the per-channel max (0.9, 0.3, 1)")
        let minL = LuminanceExtremumReducer(width: 1, height: 1, kind: .minimum)
        for f in [a, b, c] { try minL.add(f) }
        XCTAssertEqual(try minL.result().pixel(x: 0, y: 0), SIMD4(0, 0, 1, 1))
        // Ties keep the earlier frame; weights are ignored.
        let tie = LuminanceExtremumReducer(width: 1, height: 1, kind: .maximum)
        try tie.add(image([0.5, 0.5, 0.5, 1]))
        try tie.add(image([0.5, 0.5, 0.5, 0.5]), weight: 0)
        XCTAssertEqual(try tie.result().pixel(x: 0, y: 0).w, 1)
        XCTAssertFalse(tie.usesWeights)
        XCTAssertEqual(maxL.count, 3)
    }

    func testBlendModeMetadata() {
        XCTAssertTrue(BlendMode.median.requiresFrameHistory)
        XCTAssertFalse(BlendMode.average.requiresFrameHistory)
        for mode in [BlendMode.median, .maxLuminance, .minLuminance] {
            XCTAssertFalse(mode.isOrderDependent)
            XCTAssertFalse(mode.usesOpacity)
            XCTAssertFalse(mode.makeReducer(width: 2, height: 2).usesWeights)
        }
        XCTAssertTrue(BlendMode.maxLuminance.makeReducer(width: 2, height: 2) is LuminanceExtremumReducer)
        XCTAssertEqual(BlendMode.allCases.count, 11)
    }
}
