import XCTest
@testable import FrameStackCore

/// Fixed-value references for every blend mode (PRD §11.1 "blend-unit
/// tests"): 1×1 two-frame cases, order dependence, opacity, large frame
/// counts, and random-data comparison against a scalar Double reference.
final class BlendModeTests: XCTestCase {
    private func px(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) -> SIMD4<Float> { SIMD4(r, g, b, a) }

    /// Reduces 1×1 frames and returns the result pixel.
    private func reduce(_ mode: BlendMode, _ frames: [SIMD4<Float>], opacity: Float = 1) throws -> SIMD4<Float> {
        let reducer = mode.makeReducer(width: 1, height: 1, opacity: opacity)
        for f in frames { try reducer.add(LinearImage(width: 1, height: 1, fill: f)) }
        XCTAssertEqual(reducer.count, frames.count)
        return try reducer.result().pixel(x: 0, y: 0)
    }

    private func assertPixel(_ p: SIMD4<Float>, _ r: Float, _ g: Float, _ b: Float, _ a: Float = 1,
                             accuracy: Float = 1e-6, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, r, accuracy: accuracy, "R \(message)", file: file, line: line)
        XCTAssertEqual(p.y, g, accuracy: accuracy, "G \(message)", file: file, line: line)
        XCTAssertEqual(p.z, b, accuracy: accuracy, "B \(message)", file: file, line: line)
        XCTAssertEqual(p.w, a, accuracy: accuracy, "A \(message)", file: file, line: line)
    }

    // MARK: Lighten / Darken

    func testLightenAndDarkenArePerChannelExtrema() throws {
        let frames = [px(0.2, 0.9, 0.5), px(0.7, 0.1, 0.5), px(0.4, 0.4, 0.6)]
        // Lighten produces (0.7, 0.9, 0.6): a color present in no frame.
        assertPixel(try reduce(.lighten, frames), 0.7, 0.9, 0.6)
        assertPixel(try reduce(.darken, frames), 0.2, 0.1, 0.5)
        // Order does not matter.
        assertPixel(try reduce(.lighten, frames.reversed()), 0.7, 0.9, 0.6)
        assertPixel(try reduce(.darken, frames.reversed()), 0.2, 0.1, 0.5)
        // Opacity is ignored.
        assertPixel(try reduce(.lighten, frames, opacity: 0.3), 0.7, 0.9, 0.6)
        // Single frame reproduces itself exactly.
        XCTAssertEqual(try reduce(.lighten, [px(0.123, 0.456, 0.789)]), px(0.123, 0.456, 0.789))
    }

    // MARK: Screen / Multiply

    func testScreenFixedValues() throws {
        assertPixel(try reduce(.screen, [px(0.5, 0.5, 0.5), px(0.5, 0.5, 0.5)]), 0.75, 0.75, 0.75)
        // Screen with black is the identity; with white gives white.
        assertPixel(try reduce(.screen, [px(0.3, 0.6, 0.9), px(0, 0, 0)]), 0.3, 0.6, 0.9)
        assertPixel(try reduce(.screen, [px(0.3, 0.6, 0.9), px(1, 1, 1)]), 1, 1, 1)
        // Three frames: 1 − 0.8·0.7·0.6 = 0.664.
        assertPixel(try reduce(.screen, [px(0.2, 0.2, 0.2), px(0.3, 0.3, 0.3), px(0.4, 0.4, 0.4)]), 0.664, 0.664, 0.664)
    }

    func testMultiplyFixedValues() throws {
        assertPixel(try reduce(.multiply, [px(0.5, 0.5, 0.5), px(0.5, 0.5, 0.5)]), 0.25, 0.25, 0.25)
        assertPixel(try reduce(.multiply, [px(0.3, 0.6, 0.9), px(1, 1, 1)]), 0.3, 0.6, 0.9, 1, accuracy: 1e-6, "white is the identity")
        assertPixel(try reduce(.multiply, [px(0.3, 0.6, 0.9), px(0, 0, 0)]), 0, 0, 0)
        assertPixel(try reduce(.multiply, [px(0.2, 0.2, 0.2), px(0.3, 0.3, 0.3), px(0.4, 0.4, 0.4)]), 0.024, 0.024, 0.024)
    }

    // MARK: Additive

    func testAdditiveSumsAndKeepsOverflow() throws {
        let p = try reduce(.additive, [px(0.6, 0.1, 0.2), px(0.7, 0.1, 0.2)])
        assertPixel(p, 1.3, 0.2, 0.4, 2, accuracy: 1e-6, "sum, not clamped; alpha sums too")
        // Export clamps: 1.3 → 255, 0.2 linear → sRGB 124.
        let image = LinearImage(width: 1, height: 1, fill: p)
        XCTAssertEqual(PixelEncoder.encodeSRGB8(image)[0], 255)
        XCTAssertEqual(PixelEncoder.encodeSRGB8(image)[1], 124)
        // Opacity scales every frame.
        assertPixel(try reduce(.additive, [px(0.6, 0.1, 0.2), px(0.7, 0.1, 0.2)], opacity: 0.5), 0.65, 0.1, 0.2, 1)
        // Order-independent.
        assertPixel(try reduce(.additive, [px(0.7, 0.1, 0.2), px(0.6, 0.1, 0.2)]), 1.3, 0.2, 0.4, 2)
    }

    // MARK: Difference

    func testDifferenceIsSequentialAndOrderDependent() throws {
        assertPixel(try reduce(.difference, [px(0.2, 0.9, 0.5), px(0.9, 0.2, 0.5)]), 0.7, 0.7, 0)
        // Three frames: [0.1, 0.2, 0.9] → |0.1−0.2| = 0.1, |0.1−0.9| = 0.8
        //               [0.9, 0.2, 0.1] → |0.9−0.2| = 0.7, |0.7−0.1| = 0.6
        let forward = [px(0.1, 0.1, 0.1), px(0.2, 0.2, 0.2), px(0.9, 0.9, 0.9)]
        assertPixel(try reduce(.difference, forward), 0.8, 0.8, 0.8)
        assertPixel(try reduce(.difference, forward.reversed()), 0.6, 0.6, 0.6)
        XCTAssertTrue(BlendMode.difference.isOrderDependent)
        XCTAssertFalse(BlendMode.average.isOrderDependent)
    }

    // MARK: Normal / opacity stack

    func testNormalAtFullOpacityIsTheLastFrameAndAverageIsNot() throws {
        let frames = [px(0, 0, 0), px(0, 0, 0), px(0.9, 0.9, 0.9)]
        assertPixel(try reduce(.normal, frames), 0.9, 0.9, 0.9, 1, accuracy: 1e-6, "last frame wins at 100 %")
        assertPixel(try reduce(.average, frames), 0.3, 0.3, 0.3, 1, accuracy: 1e-6, "equal weight")
        XCTAssertNotEqual(try reduce(.normal, frames).x, try reduce(.average, frames).x)
    }

    func testNormalOpacityFadesEarlierFramesGeometrically() throws {
        // First frame initialises the composite at full strength.
        assertPixel(try reduce(.normal, [px(0.2, 0.2, 0.2), px(0.8, 0.8, 0.8)], opacity: 0.5), 0.5, 0.5, 0.5)
        // 0 → (1 at 50 %) → 0.5 → (0 at 50 %) → 0.25
        assertPixel(try reduce(.normal, [px(0, 0, 0), px(1, 1, 1), px(0, 0, 0)], opacity: 0.5), 0.25, 0.25, 0.25)
        // Opacity 0: nothing after the first frame changes anything.
        assertPixel(try reduce(.normal, [px(0.3, 0.3, 0.3), px(1, 1, 1)], opacity: 0), 0.3, 0.3, 0.3)
    }

    func testOpacityAppliesToScreenMultiplyAndDifference() throws {
        // C' = C + α (B − C)
        assertPixel(try reduce(.screen, [px(0.5, 0.5, 0.5), px(0.5, 0.5, 0.5)], opacity: 0.5), 0.625, 0.625, 0.625)
        assertPixel(try reduce(.multiply, [px(0.5, 0.5, 0.5), px(0.5, 0.5, 0.5)], opacity: 0.5), 0.375, 0.375, 0.375)
        assertPixel(try reduce(.difference, [px(0.2, 0.2, 0.2), px(0.9, 0.9, 0.9)], opacity: 0.5), 0.45, 0.45, 0.45)
    }

    func testOpacityIsClampedToUnitRange() throws {
        assertPixel(try reduce(.normal, [px(0, 0, 0), px(1, 1, 1)], opacity: 7), 1, 1, 1)
        assertPixel(try reduce(.normal, [px(0, 0, 0), px(1, 1, 1)], opacity: -3), 0, 0, 0)
    }

    // MARK: Alpha

    func testOpaqueInputStaysOpaqueInEveryMode() throws {
        for mode in BlendMode.allCases where mode != .additive {
            let p = try reduce(mode, [px(0.1, 0.2, 0.3), px(0.6, 0.5, 0.4), px(0.9, 0.9, 0.9)], opacity: 0.6)
            XCTAssertEqual(p.w, 1, "\(mode)")
        }
    }

    // MARK: Precision and scale

    func testLargeFrameCounts() throws {
        var multiply: [SIMD4<Float>] = []
        for _ in 0..<1000 { multiply.append(px(0.999, 0.999, 0.999)) }
        XCTAssertEqual(try reduce(.multiply, multiply).x, Float(pow(0.999, 1000)), accuracy: 2e-4) // 0.3677

        var additive: [SIMD4<Float>] = []
        for _ in 0..<100_000 { additive.append(px(0.1, 0.001, 0.9)) }
        let sum = try reduce(.additive, additive)
        XCTAssertEqual(Double(sum.x), 10_000, accuracy: 0.01)
        XCTAssertEqual(Double(sum.y), 100, accuracy: 1e-3)

        var lighten: [SIMD4<Float>] = []
        for i in 0..<10_000 { lighten.append(px(Float(i % 97) / 96, 0.5, 0.5)) }
        assertPixel(try reduce(.lighten, lighten), 1, 0.5, 0.5)
    }

    func testEveryModeMatchesScalarReferenceOnRandomData() throws {
        var rng = SplitMix64(seed: 7)
        let (w, h, n) = (31, 17, 9)
        var frames: [LinearImage] = []
        for _ in 0..<n {
            var pixels: [Float] = []
            pixels.reserveCapacity(w * h * 4)
            for p in 0..<(w * h) {
                _ = p
                pixels += [Float(rng.nextUnit()), Float(rng.nextUnit()), Float(rng.nextUnit()), 1]
            }
            frames.append(LinearImage(width: w, height: h, pixels: pixels))
        }
        let opacity: Float = 0.7

        for mode in BlendMode.allCases {
            let reducer = mode.makeReducer(width: w, height: h, opacity: opacity)
            for f in frames { try reducer.add(f) }
            let out = try reducer.result()
            XCTAssertEqual(reducer.memoryFootprintBytes, mode.makeReducer(width: w, height: h, opacity: opacity).memoryFootprintBytes,
                           "\(mode) footprint must not grow with frames")

            for i in stride(from: 0, to: w * h * 4, by: 13) where i % 4 != 3 {
                let values = frames.map { Double($0.pixels[i]) }
                let a = Double(opacity)
                let reference: Double
                switch mode {
                case .average: reference = values.reduce(0, +) / Double(n)
                case .additive: reference = values.reduce(0, +) * a
                case .lighten: reference = values.max()!
                case .darken: reference = values.min()!
                case .screen, .multiply, .difference, .normal:
                    var c = values[0]
                    for f in values.dropFirst() {
                        let b: Double
                        switch mode {
                        case .screen: b = c + f - c * f
                        case .multiply: b = c * f
                        case .difference: b = abs(c - f)
                        default: b = f
                        }
                        c += a * (b - c)
                    }
                    reference = c
                }
                XCTAssertEqual(Double(out.pixels[i]), reference, accuracy: 1e-5, "\(mode) sample \(i)")
            }
        }
    }

    func testErrorsAndMetadata() throws {
        for mode in BlendMode.allCases {
            let reducer = mode.makeReducer(width: 2, height: 2, opacity: 1)
            XCTAssertThrowsError(try reducer.result(), "\(mode)") { XCTAssertEqual($0 as? CompositingError, .noFrames) }
            XCTAssertThrowsError(try reducer.add(LinearImage(width: 3, height: 2, fill: px(0, 0, 0)))) {
                XCTAssertEqual($0 as? CompositingError, .dimensionMismatch(expected: 16, actual: 24))
            }
            XCTAssertFalse(mode.explanation.isEmpty)
            XCTAssertFalse(mode.displayName.isEmpty)
        }
        XCTAssertEqual(BlendMode.allCases.count, 8)
        XCTAssertEqual(Set(BlendMode.allCases.filter(\.usesOpacity)), [.screen, .multiply, .additive, .difference, .normal])
    }
}
