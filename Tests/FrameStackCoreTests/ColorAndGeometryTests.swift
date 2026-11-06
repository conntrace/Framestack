import XCTest
@testable import FrameStackCore

final class ColorMathTests: XCTestCase {
    func testTransferFunctionReferenceValues() {
        // Reference values computed independently from IEC 61966-2-1.
        XCTAssertEqual(SRGBTransfer.encode(0.5), 0.735_356_983_052_449_5, accuracy: 1e-12)
        XCTAssertEqual(SRGBTransfer.encode(0.18), 0.461_356_129_500_441_64, accuracy: 1e-12)
        XCTAssertEqual(SRGBTransfer.encode(0.01), 0.099_852_822_734_128_32, accuracy: 1e-12)
        XCTAssertEqual(SRGBTransfer.encode(0), 0)
        XCTAssertEqual(SRGBTransfer.encode(1), 1, accuracy: 1e-12)
        XCTAssertEqual(SRGBTransfer.decode(0.5), 0.214_041_140_482_232_55, accuracy: 1e-12)
        XCTAssertEqual(SRGBTransfer.decode(0.2), 0.033_104_766_570_885_055, accuracy: 1e-12)
        XCTAssertEqual(SRGBTransfer.decode(128.0 / 255.0), 0.215_860_500_113_899_26, accuracy: 1e-12)
    }

    func testTransferFunctionRoundTripAndContinuity() {
        for i in 0...1000 {
            let x = Double(i) / 1000
            XCTAssertEqual(SRGBTransfer.decode(SRGBTransfer.encode(x)), x, accuracy: 1e-12)
        }
        // The two pieces meet at the threshold.
        XCTAssertEqual(SRGBTransfer.encode(0.003_130_8), 0.040_449_936, accuracy: 1e-7)
    }

    func testEightBitRoundTripIsExactForEveryCode() {
        for code in 0...255 {
            let linear = Float(SRGBTransfer.decode(Double(code) / 255))
            XCTAssertEqual(PixelEncoder.quantize(linear: linear, maxValue: 255), code)
        }
    }

    func testSixteenBitRoundTrip() {
        for code in stride(from: 0, through: 65_535, by: 97) {
            let linear = Float(SRGBTransfer.decode(Double(code) / 65_535))
            XCTAssertEqual(PixelEncoder.quantize(linear: linear, maxValue: 65_535), code, accuracy: 1)
        }
    }

    func testClampingOutOfRangeValues() {
        XCTAssertEqual(PixelEncoder.quantize(linear: -0.2, maxValue: 255), 0)
        XCTAssertEqual(PixelEncoder.quantize(linear: 2.5, maxValue: 255), 255)
        XCTAssertEqual(PixelEncoder.quantize(linear: 1, maxValue: 65_535), 65_535)
        XCTAssertEqual(PixelEncoder.quantize(linear: .nan, maxValue: 255), 0)
        XCTAssertEqual(PixelEncoder.quantize(linear: .infinity, maxValue: 255), 255)
    }

    func testEncoderLayoutIsRGBRowMajorTopDown() {
        // 2×1: left red, right blue.
        let img = LinearImage(width: 2, height: 1, pixels: [1, 0, 0, 1, 0, 0, 1, 1])
        XCTAssertEqual(PixelEncoder.encodeSRGB8(img), [255, 0, 0, 0, 0, 255])
        XCTAssertEqual(PixelEncoder.encodeSRGB16(img), [65_535, 0, 0, 0, 0, 65_535])
    }
}

final class GeometryTests: XCTestCase {
    func testVideoTransformMapping() {
        XCTAssertEqual(ImageOrientation.fromVideoTransform(a: 1, b: 0, c: 0, d: 1), .up)
        XCTAssertEqual(ImageOrientation.fromVideoTransform(a: 0, b: 1, c: -1, d: 0), .right)
        XCTAssertEqual(ImageOrientation.fromVideoTransform(a: -1, b: 0, c: 0, d: -1), .down)
        XCTAssertEqual(ImageOrientation.fromVideoTransform(a: 0, b: -1, c: 1, d: 0), .left)
        XCTAssertEqual(ImageOrientation.fromVideoTransform(a: -1, b: 0, c: 0, d: 1), .upMirrored)
        XCTAssertEqual(ImageOrientation.fromVideoTransform(a: 1, b: 0, c: 0, d: -1), .downMirrored)
        XCTAssertEqual(ImageOrientation.fromVideoTransform(a: 0, b: 1, c: 1, d: 0), .leftMirrored)
        XCTAssertEqual(ImageOrientation.fromVideoTransform(a: 0, b: -1, c: -1, d: 0), .rightMirrored)
        // cos(π/2) is not exactly 0 in floating point.
        XCTAssertEqual(ImageOrientation.fromVideoTransform(a: cos(.pi / 2), b: sin(.pi / 2), c: -sin(.pi / 2), d: cos(.pi / 2)), .right)
        // 45° is not supported (reported, not ignored).
        XCTAssertNil(ImageOrientation.fromVideoTransform(a: 0.707, b: 0.707, c: -0.707, d: 0.707))
        XCTAssertNil(ImageOrientation.fromVideoTransform(a: 2, b: 0, c: 0, d: 2))
    }

    func testDisplaySize() {
        let encoded = PixelSize(width: 1920, height: 1080)
        XCTAssertEqual(ImageOrientation.right.displaySize(forEncoded: encoded), PixelSize(width: 1080, height: 1920))
        XCTAssertEqual(ImageOrientation.down.displaySize(forEncoded: encoded), encoded)
    }

    func testFittingLongEdge() {
        XCTAssertEqual(PixelSize(width: 3840, height: 2160).fitting(maxLongEdge: 1080), PixelSize(width: 1080, height: 608))
        XCTAssertEqual(PixelSize(width: 1080, height: 1920).fitting(maxLongEdge: 1080), PixelSize(width: 608, height: 1080))
        XCTAssertEqual(PixelSize(width: 640, height: 360).fitting(maxLongEdge: 1080), PixelSize(width: 640, height: 360), "never upscales")
        XCTAssertEqual(PixelSize(width: 640, height: 360).fitting(maxLongEdge: nil), PixelSize(width: 640, height: 360))
        XCTAssertEqual(PixelSize(width: 4000, height: 1).fitting(maxLongEdge: 100), PixelSize(width: 100, height: 1))
    }
}
