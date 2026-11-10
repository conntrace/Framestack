@testable import FrameStackCore
import XCTest

final class ColorAdjustmentsTests: XCTestCase {
    func testExposureDoublesLinearLightPerStop() {
        let out = ColorProcessor.adjust(SIMD3(0.1, 0.2, 0.3), ColorAdjustments(exposure: 1))
        XCTAssertEqual(out.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(out.y, 0.4, accuracy: 1e-12)
        XCTAssertEqual(out.z, 0.6, accuracy: 1e-12)
        XCTAssertEqual(ColorProcessor.adjust(SIMD3(0.4, 0.4, 0.4), ColorAdjustments(exposure: -2)).x, 0.1, accuracy: 1e-12)
    }

    func testWhiteBalanceGainsAndSaturation() {
        let warm = ColorProcessor.adjust(SIMD3(0.5, 0.5, 0.5), ColorAdjustments(temperature: 1))
        XCTAssertEqual(warm.x, 0.65, accuracy: 1e-12)
        XCTAssertEqual(warm.y, 0.5, accuracy: 1e-12)
        XCTAssertEqual(warm.z, 0.35, accuracy: 1e-12)
        let green = ColorProcessor.adjust(SIMD3(0.5, 0.5, 0.5), ColorAdjustments(tint: -1))
        XCTAssertEqual(green.y, 0.6, accuracy: 1e-12)
        // Saturation −1 → the pixel's luminance in every channel; +1 doubles the chroma.
        let c = SIMD3(0.8, 0.2, 0.1)
        let y = (c * ColorProcessor.luminance).sum()
        let gray = ColorProcessor.adjust(c, ColorAdjustments(saturation: -1))
        XCTAssertEqual(gray.x, y, accuracy: 1e-12); XCTAssertEqual(gray.y, y, accuracy: 1e-12); XCTAssertEqual(gray.z, y, accuracy: 1e-12)
        let vivid = ColorProcessor.adjust(c, ColorAdjustments(saturation: 1))
        XCTAssertEqual(vivid.x, y + 2 * (0.8 - y), accuracy: 1e-12)
    }

    func testContrastPivotsAtEncodedMidGrayAndClamps() {
        let mid = SRGBTransfer.decode(0.5)
        let same = ColorProcessor.adjust(SIMD3(repeating: mid), ColorAdjustments(contrast: 1))
        XCTAssertEqual(same.x, mid, accuracy: 1e-9, "mid-gray is the pivot")
        let bright = ColorProcessor.adjust(SIMD3(repeating: SRGBTransfer.decode(0.7)), ColorAdjustments(contrast: 1))
        XCTAssertEqual(SRGBTransfer.encode(bright.x), 0.9, accuracy: 1e-9, "0.5 + 0.2 × 2")
        let flat = ColorProcessor.adjust(SIMD3(repeating: SRGBTransfer.decode(0.9)), ColorAdjustments(contrast: -1))
        XCTAssertEqual(SRGBTransfer.encode(flat.x), 0.5, accuracy: 1e-9, "−1 flattens everything to mid-gray")
        let clipped = ColorProcessor.adjust(SIMD3(repeating: SRGBTransfer.decode(0.95)), ColorAdjustments(contrast: 1))
        XCTAssertEqual(clipped.x, 1, accuracy: 1e-9, "clamped at white")
    }

    func testOrderIsExposureThenWhiteBalanceThenSaturationThenContrast() {
        let a = ColorAdjustments(exposure: 1, contrast: 0.5, saturation: 0.5, temperature: 0.5, tint: 0)
        var v = SIMD3(0.1, 0.2, 0.3)
        v *= 2
        v *= a.whiteBalanceGains
        let y = (v * ColorProcessor.luminance).sum()
        v = SIMD3(repeating: y) + (v - SIMD3(repeating: y)) * 1.5
        for i in 0..<3 { v[i] = SRGBTransfer.decode(min(max(0.5 + (SRGBTransfer.encode(min(max(v[i], 0), 1)) - 0.5) * 1.5, 0), 1)) }
        let out = ColorProcessor.adjust(SIMD3(0.1, 0.2, 0.3), a)
        for i in 0..<3 { XCTAssertEqual(out[i], v[i], accuracy: 1e-9) }
    }

    func testImageApplicationHandlesAlphaAndIdentity() {
        var image = LinearImage(width: 2, height: 1, fill: SIMD4(0.25, 0.25, 0.25, 1))
        image.pixels[4] = 0.1; image.pixels[5] = 0.1; image.pixels[6] = 0.1; image.pixels[7] = 0.5   // straight 0.2 at half coverage
        let out = ColorProcessor.apply(ColorAdjustments(exposure: 1), to: image)
        XCTAssertEqual(out.pixel(x: 0, y: 0), SIMD4(0.5, 0.5, 0.5, 1))
        XCTAssertEqual(out.pixel(x: 1, y: 0).x, 0.2, accuracy: 1e-6, "straight 0.4 × alpha 0.5, alpha untouched")
        XCTAssertEqual(out.pixel(x: 1, y: 0).w, 0.5)
        XCTAssertEqual(ColorProcessor.apply(.identity, to: image).pixels, image.pixels)
        XCTAssertTrue(ColorAdjustments.identity.isIdentity)
        XCTAssertEqual(CompositeSettings(rangeStart: .zero, rangeEnd: .zero, samplingKind: .all, nth: 1, exactCount: 1, blendMode: .average, opacity: 1,
                                         geometry: GeometrySettings(rotationDegrees: 3), color: ColorAdjustments(exposure: 1)).compositingPart.color, .identity)
        let json = """
        {"rangeStart":{"value":0,"timescale":1},"rangeEnd":{"value":1,"timescale":1},"samplingKind":"all","nth":1,"exactCount":1,"blendMode":"average","opacity":1}
        """
        XCTAssertEqual(try? JSONDecoder().decode(CompositeSettings.self, from: Data(json.utf8)).color, .identity)
    }
}

final class ToneCurveTests: XCTestCase {
    func testIdentityCurveIsExactlyANoOpIncludingValuesAboveOne() {
        XCTAssertTrue(ToneCurve.identity.isIdentity)
        XCTAssertTrue(ColorAdjustments().isIdentity)
        for x in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(ToneCurve.identity.value(at: x), x, accuracy: 1e-12)
        }
        // The pipeline skips an identity curve, so overflow (Additive) survives.
        let out = ColorProcessor.adjust(SIMD3(2.5, 0.25, -0.1), ColorAdjustments())
        XCTAssertEqual(out, SIMD3(2.5, 0.25, -0.1))
        XCTAssertEqual(ToneCurve.Shape.linear.curve, .identity)
    }

    func testCurvePassesThroughItsPointsAndNeverOvershoots() {
        let curve = ToneCurve(points: [TonePoint(input: 0, output: 0.1), TonePoint(input: 0.25, output: 0.6),
                                       TonePoint(input: 0.5, output: 0.6), TonePoint(input: 0.75, output: 0.2),
                                       TonePoint(input: 1, output: 0.9)])
        for p in curve.points { XCTAssertEqual(curve.value(at: p.input), p.output, accuracy: 1e-12) }
        // Between two points the value stays between their outputs (no ringing).
        let pts = curve.normalizedPoints
        for i in 0..<(pts.count - 1) {
            let lo = min(pts[i].output, pts[i + 1].output), hi = max(pts[i].output, pts[i + 1].output)
            for k in 0...50 {
                let x = pts[i].input + (pts[i + 1].input - pts[i].input) * Double(k) / 50
                let v = curve.value(at: x)
                XCTAssertGreaterThanOrEqual(v, lo - 1e-12, "x=\(x)")
                XCTAssertLessThanOrEqual(v, hi + 1e-12, "x=\(x)")
            }
        }
        // A monotone set of points gives a monotone curve.
        let rising = ToneCurve.Shape.strongContrast.curve
        var previous = -1.0
        for k in 0...400 {
            let v = rising.value(at: Double(k) / 400)
            XCTAssertGreaterThanOrEqual(v, previous)
            previous = v
        }
        XCTAssertEqual(rising.value(at: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertLessThan(rising.value(at: 0.2), 0.2)
        XCTAssertGreaterThan(rising.value(at: 0.8), 0.8)
        // Inputs outside 0…1 clamp; flat beyond the end points.
        XCTAssertEqual(curve.value(at: -3), 0.1, accuracy: 1e-12)
        XCTAssertEqual(curve.value(at: 7), 0.9, accuracy: 1e-12)
    }

    func testCurveActsOnEncodedTonesPerChannelAfterContrast() {
        // Mid-gray in encoded terms (0.5) is linear 0.2140; lifting the
        // middle point to 0.75 must give the linear value of encoded 0.75.
        var curve = ToneCurve.identity
        curve.points[2].output = 0.75
        let mid = SRGBTransfer.decode(0.5)
        let out = ColorProcessor.adjust(SIMD3(mid, 0, 1), ColorAdjustments(curve: curve))
        XCTAssertEqual(out.x, SRGBTransfer.decode(0.75), accuracy: 1e-7)
        XCTAssertEqual(out.y, 0, accuracy: 1e-9)
        XCTAssertEqual(out.z, 1, accuracy: 1e-9)
        // The lookup table agrees with the spline far below one 16-bit step.
        let table = curve.table()
        for k in 0...1000 {
            let e = Double(k) / 1000
            XCTAssertEqual(table.linearOutput(forEncoded: e), SRGBTransfer.decode(curve.value(at: e)), accuracy: 2e-6, "e=\(e)")
        }
        // Order: exposure first (linear), curve last. +1 EV on 0.1 → 0.2, then the curve.
        let both = ColorProcessor.adjust(SIMD3(0.1, 0.1, 0.1), ColorAdjustments(exposure: 1, curve: curve))
        XCTAssertEqual(both.x, SRGBTransfer.decode(curve.value(at: SRGBTransfer.encode(0.2))), accuracy: 1e-6)
        // Values above 1 clamp to the curve's white point once a curve is active.
        XCTAssertEqual(ColorProcessor.adjust(SIMD3(4, 4, 4), ColorAdjustments(curve: curve)).x, 1, accuracy: 1e-9)
    }

    func testImageApplicationHandlesAlphaAndDocumentsWithoutACurveStillDecode() throws {
        var curve = ToneCurve.identity
        curve.points[0].output = 0.2   // lifted blacks
        let adjustments = ColorAdjustments(curve: curve)
        // One opaque black pixel, one half-covered black pixel, one empty pixel.
        let image = LinearImage(width: 3, height: 1, pixels: [0, 0, 0, 1, 0, 0, 0, 0.5, 0, 0, 0, 0])
        let out = ColorProcessor.apply(adjustments, to: image)
        let lifted = Float(SRGBTransfer.decode(0.2))
        XCTAssertEqual(out.pixels[0], lifted, accuracy: 1e-6)
        XCTAssertEqual(out.pixels[4], lifted * 0.5, accuracy: 1e-6, "straight colour adjusted, then re-multiplied")
        XCTAssertEqual(out.pixels[8], 0)
        XCTAssertEqual(out.pixels[11], 0)

        let old = Data(#"{"exposure":0.5,"contrast":0,"saturation":0,"temperature":0,"tint":0}"#.utf8)
        let decoded = try JSONDecoder().decode(ColorAdjustments.self, from: old)
        XCTAssertEqual(decoded.exposure, 0.5)
        XCTAssertEqual(decoded.curve, .identity)
        let back = try JSONDecoder().decode(ColorAdjustments.self, from: JSONEncoder().encode(adjustments))
        XCTAssertEqual(back, adjustments)
        // Unsorted, duplicated and out-of-range points are normalised, not trusted.
        let messy = ToneCurve(points: [TonePoint(input: 1, output: 2), TonePoint(input: 0, output: -1), TonePoint(input: 0, output: 0.1)])
        XCTAssertEqual(messy.normalizedPoints, [TonePoint(input: 0, output: 0.1), TonePoint(input: 1, output: 1)])
        XCTAssertEqual(messy.value(at: 0.5), 0.55, accuracy: 1e-12)
    }
}
