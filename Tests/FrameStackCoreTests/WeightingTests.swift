@testable import FrameStackCore
import XCTest

final class WeightingTests: XCTestCase {
    func testPresetShapesNeverReachZero() {
        let floor = WeightCurve.presetFloor
        XCTAssertEqual(WeightCurve(preset: .flat).weight(at: 0.3), 1)
        XCTAssertEqual(WeightCurve(preset: .early).weight(at: 0), 1)
        XCTAssertEqual(WeightCurve(preset: .early).weight(at: 1), floor, accuracy: 1e-12)
        XCTAssertEqual(WeightCurve(preset: .late).weight(at: 0), floor, accuracy: 1e-12)
        XCTAssertEqual(WeightCurve(preset: .late).weight(at: 1), 1)
        XCTAssertEqual(WeightCurve(preset: .middle).weight(at: 0.5), 1)
        XCTAssertEqual(WeightCurve(preset: .middle).weight(at: 0), floor, accuracy: 1e-12)
        XCTAssertEqual(WeightCurve(preset: .middle).weight(at: 0.25), floor + (1 - floor) * 0.5, accuracy: 1e-12)
        // Out-of-range and NaN times are clamped.
        XCTAssertEqual(WeightCurve(preset: .late).weight(at: 7), 1)
        XCTAssertEqual(WeightCurve(preset: .late).weight(at: -1), floor, accuracy: 1e-12)
        XCTAssertEqual(WeightCurve(preset: .late).weight(at: .nan), floor, accuracy: 1e-12)
    }

    func testCustomCurveInterpolatesAndClamps() {
        let curve = WeightCurve(preset: .custom, points: [WeightPoint(time: 0.5, weight: 0), WeightPoint(time: 0, weight: 1), WeightPoint(time: 1, weight: 2)])
        XCTAssertEqual(curve.weight(at: 0), 1)
        XCTAssertEqual(curve.weight(at: 0.25), 0.5, accuracy: 1e-12, "unsorted points are sorted first")
        XCTAssertEqual(curve.weight(at: 0.5), 0)
        XCTAssertEqual(curve.weight(at: 0.75), 0.5, accuracy: 1e-12, "control-point weights clamp to 1 before interpolation")
        XCTAssertEqual(curve.weight(at: 1), 1, "weight 2 clamps to 1")
        XCTAssertEqual(WeightCurve(preset: .custom, points: []).weight(at: 0.3), 1, "no points → flat")
    }

    func testNormalisedTimesUseTimestampsNotIndices() {
        // Variable frame rate: 0, 0.1, 0.9, 1.0 s.
        let times = [0.0, 0.1, 0.9, 1.0].map { FrameTime(seconds: $0) }
        XCTAssertEqual(WeightCurve.normalizedTimes(times), [0, 0.1, 0.9, 1.0])
        XCTAssertEqual(WeightCurve.normalizedTimes([FrameTime(seconds: 3)]), [0], "a single frame sits at 0")
        XCTAssertEqual(WeightCurve.normalizedTimes([]), [])
        let late = WeightCurve(preset: .late).weights(for: times)
        XCTAssertEqual(late.raw[1], 0.1 + 0.9 * 0.1, accuracy: 1e-12, "the second frame is early in time, not a quarter of the way")
        XCTAssertEqual(late.normalized.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertFalse(late.usedFlatFallback)
    }

    func testEffectiveFrameCountAndFallback() {
        let ten = (0..<10).map { FrameTime(value: Int64($0), timescale: 30) }
        let flat = WeightCurve.flat.weights(for: ten)
        XCTAssertEqual(flat.effectiveFrameCount, 10, accuracy: 1e-9)
        let early = WeightCurve(preset: .early).weights(for: ten)
        XCTAssertLessThan(early.effectiveFrameCount, 10)
        XCTAssertGreaterThan(early.effectiveFrameCount, 5)
        XCTAssertEqual(early.rawRange.upperBound, 1)
        // A custom curve that is zero everywhere falls back to flat.
        let zero = WeightCurve(preset: .custom, points: [WeightPoint(time: 0, weight: 0), WeightPoint(time: 1, weight: 0)]).weights(for: ten)
        XCTAssertTrue(zero.usedFlatFallback)
        XCTAssertEqual(zero.normalized, Array(repeating: 0.1, count: 10))
        // A single frame under "late" sits at t = 0 → weight 0.1, not zero.
        let one = WeightCurve(preset: .late).weights(for: [ten[3]])
        XCTAssertEqual(one.raw, [WeightCurve.presetFloor])
        XCTAssertEqual(one.normalized, [1])
    }

    func testWeightedAverageReducer() throws {
        let black = LinearImage(width: 2, height: 1, fill: SIMD4(0, 0, 0, 1))
        let white = LinearImage(width: 2, height: 1, fill: SIMD4(1, 1, 1, 1))
        let acc = AverageAccumulator(width: 2, height: 1)
        try acc.add(black, weight: 0.25)
        try acc.add(white, weight: 0.75)
        XCTAssertEqual(acc.count, 2)
        XCTAssertEqual(acc.weightTotal, 1)
        XCTAssertEqual(try acc.result().pixel(x: 0, y: 0).x, 0.75, accuracy: 1e-7)
        // Weight 1 everywhere equals the plain mean bit for bit.
        let a = AverageAccumulator(width: 2, height: 1), b = AverageAccumulator(width: 2, height: 1)
        for img in [black, white, white] { try a.add(img); try b.add(img, weight: 1) }
        XCTAssertEqual(try a.result().pixels, try b.result().pixels)
        // Zero total weight is an error, not a NaN image.
        let z = AverageAccumulator(width: 2, height: 1)
        try z.add(white, weight: 0)
        XCTAssertThrowsError(try z.result()) { XCTAssertEqual($0 as? CompositingError, .zeroTotalWeight) }
    }

    func testOtherReducersAndWeights() throws {
        let gray = LinearImage(width: 1, height: 1, fill: SIMD4(0.5, 0.5, 0.5, 1))
        let white = LinearImage(width: 1, height: 1, fill: SIMD4(1, 1, 1, 1))
        // Additive: raw weight scales each frame (exposure accumulation).
        let add = AdditiveReducer(width: 1, height: 1, opacity: 1)
        try add.add(gray, weight: 0.5)
        try add.add(gray, weight: 1)
        XCTAssertEqual(try add.result().pixel(x: 0, y: 0).x, 0.75, accuracy: 1e-7)
        // Sequential normal: opacity × weight; first frame initialises regardless.
        let normal = SequentialReducer(width: 1, height: 1, operation: .normal, opacity: 1)
        try normal.add(gray, weight: 0.1)
        try normal.add(white, weight: 0.5)
        XCTAssertEqual(try normal.result().pixel(x: 0, y: 0).x, 0.75, accuracy: 1e-7, "0.5 + 0.5 × (1 − 0.5)")
        // Extremum ignores weights.
        let lighten = ExtremumReducer(width: 1, height: 1, kind: .maximum)
        XCTAssertFalse(lighten.usesWeights)
        try lighten.add(gray, weight: 0.01)
        try lighten.add(white, weight: 0)
        XCTAssertEqual(try lighten.result().pixel(x: 0, y: 0).x, 1)
        XCTAssertTrue(AverageAccumulator(width: 1, height: 1).usesWeights)
    }

    func testSettingsDefaultAndCodable() throws {
        let json = """
        {"rangeStart":{"value":0,"timescale":1},"rangeEnd":{"value":1,"timescale":1},"samplingKind":"all","nth":1,"exactCount":1,"blendMode":"average","opacity":1}
        """
        XCTAssertEqual(try JSONDecoder().decode(CompositeSettings.self, from: Data(json.utf8)).weighting, .flat)
        let custom = WeightCurve(preset: .custom, points: [WeightPoint(time: 0, weight: 0.2), WeightPoint(time: 1, weight: 0.9)])
        let data = try JSONEncoder().encode(custom)
        XCTAssertEqual(try JSONDecoder().decode(WeightCurve.self, from: data), custom)
        XCTAssertEqual(try JSONDecoder().decode(WeightCurve.self, from: Data("{\"preset\":\"late\"}".utf8)), WeightCurve(preset: .late))
    }
}
