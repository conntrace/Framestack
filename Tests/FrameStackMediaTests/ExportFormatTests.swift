import CoreGraphics
import FrameStackCore
@testable import FrameStackMedia
import XCTest

final class ExportFormatTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackExportFormats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func composite() async throws -> LinearImage {
        let clip = try await loadFixture(.movingSquare)
        return try await render(clip, indices: Array(0..<24)).image
    }

    func testJPEGIsEightBitSRGBAndCloseToTheSource() async throws {
        let image = try await composite()
        let url = directory.appendingPathComponent("square.jpg")
        let report = try ImageExporter.write(image, to: url, settings: ExportSettings(format: .jpeg, bitDepth: .sixteen, jpegQuality: 0.95))
        XCTAssertEqual(report.format, .jpeg)
        XCTAssertEqual(report.bitDepth, 8, "JPEG cannot be 16-bit; the request is downgraded, never misreported")
        XCTAssertEqual(report.width, 480)
        XCTAssertEqual(report.height, 272)
        XCTAssertTrue(report.colorProfileName?.contains("sRGB") ?? false, report.colorProfileName ?? "none")
        let readBack = try readBackPixels(url, bitDepth: .eight)
        let expected = PixelEncoder.encodeSRGB8(image)
        var total = 0.0
        for i in 0..<expected.count { total += abs(readBack.rgb[i] * 255 - Double(expected[i])) }
        XCTAssertLessThan(total / Double(expected.count), 1.0, "mean |Δ| per sample in 8-bit steps")
        XCTAssertEqual(readBack.rgb[(96 * 480 + 200) * 3] * 255, 82, accuracy: 4, "the 2-of-24 trail survives JPEG")
    }

    func testSixteenBitTIFFRoundTrip() async throws {
        let image = try await composite()
        let url = directory.appendingPathComponent("square.tif")
        let report = try ImageExporter.write(image, to: url, settings: ExportSettings(format: .tiff, bitDepth: .sixteen))
        XCTAssertEqual(report.format, .tiff)
        XCTAssertEqual(report.bitDepth, 16)
        XCTAssertTrue(report.colorProfileName?.contains("sRGB") ?? false)
        let readBack = try readBackPixels(url, bitDepth: .sixteen)
        let expected = PixelEncoder.encodeSRGB16(image)
        for (x, y) in [(0, 0), (200, 96), (240, 220), (479, 271)] {
            for c in 0..<3 {
                let i = (y * 480 + x) * 3 + c
                XCTAssertEqual(readBack.rgb[i], Double(expected[i]) / 65_535, accuracy: 2.0 / 65_535, "(\(x),\(y)) c\(c)")
            }
        }
        let eight = try ImageExporter.write(image, to: directory.appendingPathComponent("square8.tif"), settings: ExportSettings(format: .tiff, bitDepth: .eight))
        XCTAssertEqual(eight.bitDepth, 8)
        XCTAssertLessThan(eight.fileSizeBytes, report.fileSizeBytes)
    }

    /// The Display P3 file must display identically to the sRGB file: when
    /// CoreGraphics converts the P3 PNG back to sRGB the pixels match the
    /// sRGB export, which proves both the matrix and the embedded profile.
    func testDisplayP3ExportMatchesSRGBExportAfterColorManagement() async throws {
        var image = try await composite()
        // Add saturated colors so the test is not all neutral.
        for p in 0..<image.width { image.pixels[p * 4] = 0.9; image.pixels[p * 4 + 1] = 0.1; image.pixels[p * 4 + 2] = 0.05 }
        let srgbURL = directory.appendingPathComponent("srgb.png")
        let p3URL = directory.appendingPathComponent("p3.png")
        try ImageExporter.write(image, to: srgbURL, settings: ExportSettings(format: .png, bitDepth: .sixteen, colorSpace: .sRGB))
        let p3 = try ImageExporter.write(image, to: p3URL, settings: ExportSettings(format: .png, bitDepth: .sixteen, colorSpace: .displayP3))
        XCTAssertEqual(p3.colorProfileName, "Display P3")
        XCTAssertEqual(p3.bitDepth, 16)

        // readBackPixels draws into an sRGB context, i.e. color-manages the P3 file to sRGB.
        let a = try readBackPixels(srgbURL, bitDepth: .sixteen).rgb
        let b = try readBackPixels(p3URL, bitDepth: .sixteen).rgb
        var maxDelta = 0.0
        for i in 0..<a.count { maxDelta = max(maxDelta, abs(a[i] - b[i])) }
        XCTAssertLessThan(maxDelta * 255, 1.0, "max |Δ| in 8-bit steps after CoreGraphics converts P3 → sRGB")

        // And the raw P3 samples differ from the sRGB ones for the red row (it is encoded in different primaries).
        let rawP3 = PixelEncoder.encode16(image, colorSpace: .displayP3)
        let rawSRGB = PixelEncoder.encode16(image, colorSpace: .sRGB)
        XCTAssertLessThan(rawP3[0], rawSRGB[0], "red is less saturated in P3 coordinates")
        XCTAssertGreaterThan(rawP3[1], rawSRGB[1])
    }

    func testOutputSizingRendersAtTheReducedSize() async throws {
        let clip = try await loadFixture(.movingSquare)   // 480×272
        let sizing = OutputSizing.longEdge(240)
        let result = try await render(clip, indices: Array(0..<24), maxLongEdge: sizing.maxLongEdge(for: clip.info.displaySize))
        XCTAssertEqual(result.image.size, PixelSize(width: 240, height: 136))
        XCTAssertEqual(sizing.outputSize(for: clip.info.displaySize), result.image.size)
        let url = directory.appendingPathComponent("half.png")
        let report = try ImageExporter.write(result.image, to: url, settings: ExportSettings(format: .png, bitDepth: .eight, sizing: sizing))
        XCTAssertEqual(report.width, 240)
        XCTAssertEqual(report.height, 136)
        // The static gray bar keeps its value when downscaled.
        let full = try await render(clip, indices: Array(0..<24)).image
        XCTAssertEqual(result.image.mean(x: 20..<220, y: 110..<130).x, full.mean(x: 40..<440, y: 220..<260).x, accuracy: 0.01)
    }

    func testVerificationCatchesAWrongContainer() async throws {
        // Writing a JPEG to a .png name is allowed (the extension is the user's), but the
        // read-back must identify the container correctly.
        let image = try await composite()
        let url = directory.appendingPathComponent("really-a-jpeg.png")
        let report = try ImageExporter.write(image, to: url, settings: ExportSettings(format: .jpeg))
        XCTAssertEqual(report.format, .jpeg)
        XCTAssertEqual(try ImageExporter.inspect(url).typeIdentifier, "public.jpeg")
    }
}
