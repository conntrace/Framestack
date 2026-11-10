@testable import FrameStackCore
import XCTest

final class MotionMaskTests: XCTestCase {
    func testDifferenceThresholdAndApply() {
        let frame: [Float] = [0.5, 0.5, 0.5, 1,  0.2, 0.2, 0.2, 1,  0, 0, 1, 1]
        let background: [Float] = [0.5, 0.5, 0.5, 1,  0.2, 0.25, 0.2, 1,  1, 0, 0, 1]
        var d = frame.withUnsafeBufferPointer { f in background.withUnsafeBufferPointer { b in MaskOps.difference(f, b, pixels: 3) } }
        XCTAssertEqual(d.count, 3)
        XCTAssertEqual(d[0], 0, accuracy: 1e-6)
        XCTAssertEqual(d[1], 0.05, accuracy: 1e-6)
        XCTAssertEqual(d[2], Float(2.0.squareRoot()), accuracy: 1e-6)
        MaskOps.threshold(&d, 0.1)
        XCTAssertEqual(d, [0, 0, 1])
        var masked = frame
        masked.withUnsafeMutableBufferPointer { MaskOps.apply(d, to: $0) }
        XCTAssertEqual(Array(masked[0..<8]), [Float](repeating: 0, count: 8), "static pixels are fully masked out (alpha 0)")
        XCTAssertEqual(Array(masked[8..<12]), [0, 0, 1, 1])
        MaskOps.invert(&d)
        XCTAssertEqual(d, [1, 1, 0])
    }

    func testMorphologyRemovesSpecksAndFillsHoles() {
        // 15×15: a single-pixel speck at (1,1) and a 9×9 block with a one-pixel hole at its centre.
        let w = 15, h = 15
        var m = [Float](repeating: 0, count: w * h)
        m[1 * w + 1] = 1
        for y in 3..<12 { for x in 3..<12 { m[y * w + x] = 1 } }
        m[7 * w + 7] = 0
        MaskOps.cleanup(&m, width: w, height: h, radius: 1)
        XCTAssertEqual(m[1 * w + 1], 0, "speck removed by the opening")
        XCTAssertEqual(m[7 * w + 7], 1, "hole filled by the closing")
        XCTAssertEqual(m[5 * w + 5], 1)
        XCTAssertEqual(m[3 * w + 3], 1, "block corners survive a radius-1 open/close")
        XCTAssertEqual(m[2 * w + 2], 0, "the block did not grow")
        XCTAssertEqual(m[0], 0)
        XCTAssertEqual(m.reduce(0, +), 81, "exactly the 9×9 block remains")
    }

    func testFeatherIsASmoothPartitionAndKeepsRange() {
        let w = 21, h = 3
        var m = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 10..<w { m[y * w + x] = 1 } }   // right half on
        MaskOps.feather(&m, width: w, height: h, radius: 2)
        let row = Array(m[(1 * w)..<(2 * w)])
        XCTAssertEqual(row[0], 0, accuracy: 1e-6)
        XCTAssertEqual(row[20], 1, accuracy: 1e-6)
        XCTAssertGreaterThan(row[11], row[9], "monotonic across the edge")
        XCTAssertEqual(row[9] + row[10], 1, accuracy: 0.05, "symmetric about the edge")
        XCTAssertTrue(row.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertEqual(row[2], 0, "far from the edge the mask is exactly zero, not a running-sum residue")
        XCTAssertEqual(row[18], 1)
        for i in 1..<w { XCTAssertGreaterThanOrEqual(row[i] + 1e-6, row[i - 1]) }
        // Radius 0 is a no-op.
        var copy = m
        MaskOps.feather(&copy, width: w, height: h, radius: 0)
        XCTAssertEqual(copy, m)
    }

    func testMaskPipelineAndOver() {
        // 6×1 frame differs from the background at x = 3 only.
        var frame = [Float](repeating: 0.2, count: 6 * 4)
        for p in 0..<6 { frame[p * 4 + 3] = 1 }
        var background = frame
        background[3 * 4] = 0.9
        let settings = MotionMaskSettings(enabled: true, threshold: 0.1, feather: 0, cleanup: 0)
        let m = frame.withUnsafeBufferPointer { f in background.withUnsafeBufferPointer { b in
            MaskOps.mask(frame: f, background: b, width: 6, height: 1, settings: settings) } }
        XCTAssertEqual(m, [0, 0, 0, 1, 0, 0])
        var masked = frame
        masked.withUnsafeMutableBufferPointer { MaskOps.apply(m, to: $0) }
        let composite = LinearImage(width: 6, height: 1, pixels: masked)
        let over = MaskOps.over(composite, background: LinearImage(width: 6, height: 1, pixels: background))
        XCTAssertEqual(over.pixel(x: 3, y: 0), SIMD4(0.2, 0.2, 0.2, 1), "the moving pixel shows the frame")
        XCTAssertEqual(over.pixel(x: 0, y: 0), SIMD4(0.2, 0.2, 0.2, 1), "elsewhere the background")
        XCTAssertEqual(over.pixel(x: 3, y: 0).w, 1)
        // Inverted keeps the static pixels.
        var inv = settings; inv.invert = true
        let mi = frame.withUnsafeBufferPointer { f in background.withUnsafeBufferPointer { b in
            MaskOps.mask(frame: f, background: b, width: 6, height: 1, settings: inv) } }
        XCTAssertEqual(mi, [1, 1, 1, 0, 1, 1])
    }

    func testSettingsCodableAndBackgroundResolution() throws {
        let json = """
        {"rangeStart":{"value":0,"timescale":1},"rangeEnd":{"value":1,"timescale":1},"samplingKind":"all","nth":1,"exactCount":1,"blendMode":"average","opacity":1}
        """
        XCTAssertEqual(try JSONDecoder().decode(CompositeSettings.self, from: Data(json.utf8)).motionMask, .off)
        let s = MotionMaskSettings(enabled: true, background: .frame(FrameTime(value: 3, timescale: 30)), threshold: 0.2, feather: 4, cleanup: 2, invert: true)
        XCTAssertEqual(try JSONDecoder().decode(MotionMaskSettings.self, from: try JSONEncoder().encode(s)), s)
        let frames = (0..<5).map { FrameTime(value: Int64($0), timescale: 30) }
        XCTAssertEqual(s.background.frameTime(in: frames), frames[3])
        XCTAssertNil(MaskBackground.frame(FrameTime(value: 9, timescale: 30)).frameTime(in: frames), "not selected → median")
        XCTAssertNil(MaskBackground.median.frameTime(in: frames))
    }
}
