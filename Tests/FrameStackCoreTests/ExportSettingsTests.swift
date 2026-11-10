@testable import FrameStackCore
import XCTest

final class ExportSettingsTests: XCTestCase {
    let landscape4K = PixelSize(width: 3840, height: 2160)
    let portrait = PixelSize(width: 1080, height: 1920)

    func testNativeSizingKeepsSize() {
        XCTAssertNil(OutputSizing.native.maxLongEdge(for: landscape4K))
        XCTAssertEqual(OutputSizing.native.outputSize(for: landscape4K), landscape4K)
    }

    func testLongEdgeSizingDownscalesOnly() {
        XCTAssertEqual(OutputSizing.longEdge(1920).outputSize(for: landscape4K), PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(OutputSizing.longEdge(960).outputSize(for: portrait), PixelSize(width: 540, height: 960))
        XCTAssertEqual(OutputSizing.longEdge(8000).outputSize(for: landscape4K), landscape4K, "never upscales")
        XCTAssertEqual(OutputSizing.longEdge(0).outputSize(for: landscape4K), PixelSize(width: 1, height: 1), "clamped to ≥ 1")
    }

    func testPercentSizing() {
        XCTAssertEqual(OutputSizing.percent(50).outputSize(for: landscape4K), PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(OutputSizing.percent(25).outputSize(for: portrait), PixelSize(width: 270, height: 480))
        XCTAssertEqual(OutputSizing.percent(100).outputSize(for: landscape4K), landscape4K)
        XCTAssertNil(OutputSizing.percent(100).maxLongEdge(for: landscape4K))
        XCTAssertEqual(OutputSizing.percent(150).outputSize(for: landscape4K), landscape4K, "clamped to 100 %")
        XCTAssertEqual(OutputSizing.percent(0).outputSize(for: landscape4K), PixelSize(width: 38, height: 21), "clamped to 1 %")
    }

    func testJPEGIsAlwaysEightBit() {
        var s = ExportSettings(format: .jpeg, bitDepth: .sixteen)
        XCTAssertEqual(s.effectiveBitDepth, .eight)
        s.format = .tiff
        XCTAssertEqual(s.effectiveBitDepth, .sixteen)
        XCTAssertEqual(ExportFormat.jpeg.fileExtension, "jpg")
        XCTAssertEqual(ExportFormat.tiff.fileExtension, "tif")
    }

    func testSettingsRoundTripThroughJSON() throws {
        let export = ExportSettings(format: .tiff, bitDepth: .sixteen, jpegQuality: 0.8, sizing: .longEdge(2048), colorSpace: .displayP3)
        let composite = CompositeSettings(
            rangeStart: FrameTime(value: 1, timescale: 30), rangeEnd: FrameTime(value: 149, timescale: 30),
            samplingKind: .everyNth, nth: 3, exactCount: 20, blendMode: .lighten, opacity: 0.75
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(ExportSettings.self, from: encoder.encode(export)), export)
        let exportJSON = String(decoding: try encoder.encode(export), as: UTF8.self)
        XCTAssertTrue(exportJSON.contains("\"sizing\":{\"kind\":\"longEdge\",\"value\":2048}"), exportJSON)
        XCTAssertEqual(try decoder.decode(OutputSizing.self, from: Data("{\"kind\":\"native\"}".utf8)), .native)
        XCTAssertThrowsError(try decoder.decode(OutputSizing.self, from: Data("{\"kind\":\"huge\"}".utf8)))
        XCTAssertEqual(try decoder.decode(CompositeSettings.self, from: encoder.encode(composite)), composite)
        let json = String(decoding: try encoder.encode(composite), as: UTF8.self)
        XCTAssertTrue(json.contains("\"samplingKind\":\"everyNth\""), "stable identifiers, not display names: \(json)")
        XCTAssertTrue(json.contains("\"blendMode\":\"lighten\""))
        XCTAssertEqual(composite.samplingMode, .everyNth(3))
    }
}

final class ColorPrimariesTests: XCTestCase {
    func testSRGBToXYZMatchesIEC61966() {
        let m = ColorPrimaries.rgbToXYZ(ColorPrimaries.sRGB)
        let expected = [0.4124, 0.3576, 0.1805, 0.2126, 0.7152, 0.0722, 0.0193, 0.1192, 0.9505]
        for i in 0..<9 { XCTAssertEqual(m[i], expected[i], accuracy: 0.0005, "element \(i)") }
    }

    func testSRGBToDisplayP3MatrixMatchesReference() {
        // Reference values (Apple / colour-science) for linear sRGB → linear Display P3.
        let expected = [0.8225, 0.1774, 0.0000, 0.0332, 0.9669, 0.0000, 0.0171, 0.0724, 0.9105]
        let m = ColorPrimaries.sRGBToDisplayP3
        for i in 0..<9 { XCTAssertEqual(m[i], expected[i], accuracy: 0.0005, "element \(i)") }
    }

    func testWhiteAndGrayAreUnchangedAndRoundTripIsIdentity() {
        let m = ColorPrimaries.sRGBToDisplayP3
        let white = ColorPrimaries.apply(m, to: [1, 1, 1])
        for c in white { XCTAssertEqual(c, 1, accuracy: 1e-9) }
        let gray = ColorPrimaries.apply(m, to: [0.18, 0.18, 0.18])
        for c in gray { XCTAssertEqual(c, 0.18, accuracy: 1e-9) }
        let identity = ColorPrimaries.multiply(ColorPrimaries.displayP3ToSRGB, ColorPrimaries.sRGBToDisplayP3)
        for i in 0..<9 { XCTAssertEqual(identity[i], i % 4 == 0 ? 1 : 0, accuracy: 1e-9) }
    }

    func testEncodeInDisplayP3DesaturatesSRGBRed() {
        // sRGB red lies inside the P3 gamut, so in P3 it becomes a less
        // saturated red (some green and blue); gray stays identical.
        let image = LinearImage(width: 2, height: 1, fill: SIMD4(1, 0, 0, 1))
        var gray = image
        gray.pixels[4] = 0.5; gray.pixels[5] = 0.5; gray.pixels[6] = 0.5
        let srgb = PixelEncoder.encode8(gray, colorSpace: .sRGB)
        let p3 = PixelEncoder.encode8(gray, colorSpace: .displayP3)
        XCTAssertEqual(Array(srgb[0..<3]), [255, 0, 0])
        XCTAssertEqual(p3[0], 234, accuracy: 1)   // sRGB-encode(0.8225) × 255
        XCTAssertEqual(p3[1], 51, accuracy: 1)    // sRGB-encode(0.0332) × 255
        XCTAssertEqual(p3[2], 35, accuracy: 1)    // sRGB-encode(0.0171) × 255
        XCTAssertEqual(Array(p3[3..<6]), Array(srgb[3..<6]), "neutral gray is the same in both")
        let p3_16 = PixelEncoder.encode16(gray, colorSpace: .displayP3)
        XCTAssertEqual(Double(p3_16[0]) / 257, Double(p3[0]), accuracy: 1)
    }

    func testSRGBEncodersAreUnchanged() {
        let image = LinearImage(width: 1, height: 1, fill: SIMD4(0.5, 0.25, 0, 1))
        XCTAssertEqual(PixelEncoder.encodeSRGB8(image), PixelEncoder.encode8(image, colorSpace: .sRGB))
        XCTAssertEqual(PixelEncoder.encodeSRGB16(image), PixelEncoder.encode16(image, colorSpace: .sRGB))
        XCTAssertEqual(PixelEncoder.encodeSRGB8(image), [188, 137, 0])
    }
}
