@testable import FrameStackCore
import XCTest

/// The mask operations run on all cores in chunks (D-038). These tests
/// compare them, value for value, with the plain serial loops they replaced:
/// the result must not depend on how the work is split.
final class MaskOpsReferenceTests: XCTestCase {
    // MARK: Serial reference (the code before the parallel version)

    private func referenceMorph(_ mask: inout [Float], width: Int, height: Int, radius: Int, dilate: Bool) {
        guard radius > 0 else { return }
        var tmp = [Float](repeating: 0, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                var best: Float = dilate ? -.infinity : .infinity
                for dx in -radius...radius {
                    let v = mask[y * width + min(max(x + dx, 0), width - 1)]
                    best = dilate ? max(best, v) : min(best, v)
                }
                tmp[y * width + x] = best
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var best: Float = dilate ? -.infinity : .infinity
                for dy in -radius...radius {
                    let v = tmp[min(max(y + dy, 0), height - 1) * width + x]
                    best = dilate ? max(best, v) : min(best, v)
                }
                mask[y * width + x] = best
            }
        }
    }

    private func referenceFeather(_ mask: inout [Float], width: Int, height: Int, radius: Int) {
        guard radius > 0 else { return }
        var tmp = [Float](repeating: 0, count: mask.count)
        let window = Float(2 * radius + 1)
        for _ in 0..<3 {
            for y in 0..<height {
                var sum: Float = 0
                for dx in -radius...radius { sum += mask[y * width + min(max(dx, 0), width - 1)] }
                for x in 0..<width {
                    tmp[y * width + x] = sum / window
                    let leaving = min(max(x - radius, 0), width - 1)
                    let entering = min(max(x + radius + 1, 0), width - 1)
                    sum += mask[y * width + entering] - mask[y * width + leaving]
                }
            }
            for x in 0..<width {
                var sum: Float = 0
                for dy in -radius...radius { sum += tmp[min(max(dy, 0), height - 1) * width + x] }
                for y in 0..<height {
                    mask[y * width + x] = sum / window
                    let leaving = min(max(y - radius, 0), height - 1)
                    let entering = min(max(y + radius + 1, 0), height - 1)
                    sum += tmp[entering * width + x] - tmp[leaving * width + x]
                }
            }
            for i in 0..<mask.count {
                if mask[i] < 1e-5 { mask[i] = 0 } else if mask[i] > 1 - 1e-5 { mask[i] = 1 }
            }
        }
    }

    // MARK: Inputs

    /// A fixed pseudo-random sequence (no dependence on the system generator).
    private struct Generator {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
    }

    /// Binary blobs and specks, like a thresholded difference.
    private func binaryMask(width: Int, height: Int, seed: UInt64) -> [Float] {
        var g = Generator(state: seed)
        var m = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let blob = ((x / 9) + (y / 7)) % 5 == 0
                let noise = g.next()
                m[y * width + x] = (blob && noise > 0.05) || noise > 0.97 ? 1 : 0
            }
        }
        return m
    }

    /// Small shapes with every radius (including wider than the image), and
    /// one large enough to be split across cores with two radii (the serial
    /// reference is slow in a debug build).
    private static let cases: [(Int, Int, Int)] =
        [(1, 1), (5, 3), (3, 200), (64, 1), (257, 131)].flatMap { size in [1, 2, 7, 32, 40].map { (size.0, size.1, $0) } }
        + [(900, 400, 3), (900, 400, 21)]

    func testMorphMatchesTheSerialLoopExactly() {
        for (w, h, r) in Self.cases {
            for dilate in [true, false] {
                var expected = binaryMask(width: w, height: h, seed: UInt64(w * 31 + h + r))
                var actual = expected
                referenceMorph(&expected, width: w, height: h, radius: r, dilate: dilate)
                MaskOps.morph(&actual, width: w, height: h, radius: r, dilate: dilate)
                XCTAssertEqual(actual, expected, "\(w)×\(h), radius \(r), \(dilate ? "dilate" : "erode")")
            }
        }
    }

    func testFeatherMatchesTheSerialLoopBitForBit() {
        for (w, h, r) in Self.cases {
            var expected = binaryMask(width: w, height: h, seed: UInt64(w * 17 + h * 3 + r))
            var actual = expected
            referenceFeather(&expected, width: w, height: h, radius: r)
            MaskOps.feather(&actual, width: w, height: h, radius: r)
            XCTAssertEqual(actual.map(\.bitPattern), expected.map(\.bitPattern), "\(w)×\(h), radius \(r)")
        }
    }

    func testDifferenceThresholdAndApplyMatchSerialArithmetic() {
        let w = 900, h = 400, n = w * h
        var g = Generator(state: 99)
        let frame = (0..<(n * 4)).map { _ in g.next() }
        let background = (0..<(n * 4)).map { _ in g.next() }
        var distance = frame.withUnsafeBufferPointer { f in
            background.withUnsafeBufferPointer { b in MaskOps.difference(f, b, pixels: n) }
        }
        var expectedDistance = [Float](repeating: 0, count: n)
        for p in 0..<n {
            let i = p * 4
            let dr = frame[i] - background[i], dg = frame[i + 1] - background[i + 1], db = frame[i + 2] - background[i + 2]
            expectedDistance[p] = (dr * dr + dg * dg + db * db).squareRoot()
        }
        XCTAssertEqual(distance.map(\.bitPattern), expectedDistance.map(\.bitPattern))

        MaskOps.threshold(&distance, 0.6)
        XCTAssertEqual(distance, expectedDistance.map { $0 > 0.6 ? 1 : 0 })

        var masked = frame
        masked.withUnsafeMutableBufferPointer { MaskOps.apply(distance, to: $0) }
        var expected = frame
        for p in 0..<n { for c in 0..<4 { expected[p * 4 + c] *= distance[p] } }
        XCTAssertEqual(masked.map(\.bitPattern), expected.map(\.bitPattern))
    }

    func testParallelRangesCoverEveryIndexOnce() {
        for count in [0, 1, 7, 1000, 100_003] {
            for minimum in [1, 64, 5000] {
                var hits = [Int32](repeating: 0, count: count)
                hits.withUnsafeMutableBufferPointer { h in
                    let p = h.baseAddress
                    MaskOps.parallel(count, minimumChunk: minimum) { range in
                        for i in range { p![i] += 1 }
                    }
                }
                XCTAssertTrue(hits.allSatisfy { $0 == 1 }, "count \(count), minimum chunk \(minimum)")
            }
        }
    }
}
