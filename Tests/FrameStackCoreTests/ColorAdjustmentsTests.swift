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
