import XCTest
@testable import FrameStackCore

final class CompositingTests: XCTestCase {
    func image(_ rgba: SIMD4<Float>, width: Int = 1, height: Int = 1) -> LinearImage {
        LinearImage(width: width, height: height, fill: rgba)
    }

    func testTwoFrameAverageFixedValues() throws {
        let acc = AverageAccumulator(width: 1, height: 1)
        try acc.add(image(SIMD4(0.2, 0.4, 0.6, 1)))
        try acc.add(image(SIMD4(0.6, 0.0, 1.0, 1)))
        let p = try acc.result().pixel(x: 0, y: 0)
        XCTAssertEqual(p.x, 0.4, accuracy: 1e-7)
        XCTAssertEqual(p.y, 0.2, accuracy: 1e-7)
        XCTAssertEqual(p.z, 0.8, accuracy: 1e-7)
        XCTAssertEqual(p.w, 1.0)
    }

    func testAverageIsNotLastFrameOrSequentialOpacity() throws {
        // Three frames 0, 0, 0.9. Equal weight → 0.3.
        // Naive "draw each frame at 1/i opacity" in 8-bit, or "last frame wins",
        // would give different answers.
        let acc = AverageAccumulator(width: 1, height: 1)
        for v: Float in [0, 0, 0.9] { try acc.add(image(SIMD4(v, v, v, 1))) }
        XCTAssertEqual(try acc.result().pixel(x: 0, y: 0).x, 0.3, accuracy: 1e-7)
    }

    func testIdenticalFramesReproduceExactly() throws {
        var pixels: [Float] = []
        for i in 0..<(7 * 5) {
            let v = Float(i) / 34 * 1.3 - 0.1 // includes negative and >1 values
            pixels += [v, v * 0.5, 1 - v, 1]
        }
        let frame = LinearImage(width: 7, height: 5, pixels: pixels)
        let acc = AverageAccumulator(width: 7, height: 5)
        for _ in 0..<1000 { try acc.add(frame) }
        XCTAssertEqual(acc.count, 1000)
        XCTAssertEqual(try acc.result(), frame, "bit-exact")
    }

    func testLargeFrameCountPrecision() throws {
        let acc = AverageAccumulator(width: 1, height: 1)
        let a = image(SIMD4(0.1, 0.001, 0.9, 1))
        let b = image(SIMD4(0.3, 0.002, 0.7, 1))
        for i in 0..<100_000 { try acc.add(i % 2 == 0 ? a : b) }
        let p = try acc.result().pixel(x: 0, y: 0)
        XCTAssertEqual(p.x, 0.2, accuracy: 1e-7)
        XCTAssertEqual(p.y, 0.0015, accuracy: 1e-9)
        XCTAssertEqual(p.z, 0.8, accuracy: 1e-7)
    }

    func testMatchesScalarReferenceOnRandomData() throws {
        var rng = SplitMix64(seed: 42)
        let (w, h, n) = (37, 23, 17)
        var frames: [LinearImage] = []
        for _ in 0..<n {
            frames.append(LinearImage(width: w, height: h, pixels: (0..<(w * h * 4)).map { _ in Float(rng.nextUnit()) }))
        }
        let acc = AverageAccumulator(width: w, height: h)
        for f in frames { try acc.add(f) }
        let out = try acc.result()
        for i in stride(from: 0, to: w * h * 4, by: 97) {
            let reference = frames.reduce(0.0) { $0 + Double($1.pixels[i]) } / Double(n)
            XCTAssertEqual(Double(out.pixels[i]), reference, accuracy: 1e-7)
        }
    }

    func testErrors() {
        let acc = AverageAccumulator(width: 2, height: 2)
        XCTAssertThrowsError(try acc.result()) { XCTAssertEqual($0 as? CompositingError, .noFrames) }
        XCTAssertThrowsError(try acc.add(image(SIMD4(0, 0, 0, 1), width: 3, height: 2))) {
            XCTAssertEqual($0 as? CompositingError, .dimensionMismatch(expected: 16, actual: 24))
        }
    }

    func testMemoryIsBoundedByOutputSizeNotFrameCount() throws {
        let acc = AverageAccumulator(width: 64, height: 32)
        let before = acc.memoryFootprintBytes
        for _ in 0..<500 { try acc.add(image(SIMD4(0.5, 0.5, 0.5, 1), width: 64, height: 32)) }
        XCTAssertEqual(acc.memoryFootprintBytes, before)
        XCTAssertGreaterThanOrEqual(before, 64 * 32 * 4 * 8)
    }

    // MARK: Linear vs encoded averaging (PRD §11.1 color tests)

    func testLinearLightAverageOfBlackAndWhite() throws {
        let acc = AverageAccumulator(width: 1, height: 1)
        try acc.add(image(SIMD4(0, 0, 0, 1)))
        try acc.add(image(SIMD4(1, 1, 1, 1)))
        let result = try acc.result()
        XCTAssertEqual(result.pixel(x: 0, y: 0).x, 0.5)
        // Linear 0.5 encodes to sRGB 0.73536 → 188/255. Averaging the
        // *encoded* values instead would give 128/255.
        XCTAssertEqual(PixelEncoder.encodeSRGB8(result), [188, 188, 188])
        XCTAssertEqual(PixelEncoder.encodeSRGB16(result)[0], 48_192) // round(0.7353569830524495 × 65535)
    }
}

/// Small deterministic PRNG so tests do not depend on platform randomness.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
