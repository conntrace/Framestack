import FrameStackCore
@testable import FrameStackMedia
import XCTest

final class ExportTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSixteenBitPNGRoundTrip() async throws {
        let clip = try await loadFixture(.movingSquare)
        let composite = try await render(clip, indices: Array(0..<24)).image
        let url = directory.appendingPathComponent("square16.png")

        let report = try ImageExporter.writePNG(composite, to: url, bitDepth: .sixteen)
        XCTAssertEqual(report.width, 480, "full resolution, never downscaled")
        XCTAssertEqual(report.height, 272)
        XCTAssertEqual(report.bitDepth, 16)
        XCTAssertTrue(report.colorProfileName?.contains("sRGB") ?? false, "profile: \(report.colorProfileName ?? "none")")
        XCTAssertGreaterThan(report.fileSizeBytes, 0)

        let readBack = try readBackPixels(url, bitDepth: .sixteen)
        XCTAssertEqual(readBack.cgImage.bitsPerComponent, 16)
        let expected = PixelEncoder.encodeSRGB16(composite)
        for (x, y) in [(0, 0), (200, 96), (240, 220), (479, 271), (33, 100)] {
            for c in 0..<3 {
                let i = (y * 480 + x) * 3 + c
                XCTAssertEqual(readBack.rgb[i], Double(expected[i]) / 65_535, accuracy: 2.0 / 65_535, "(\(x),\(y)) c\(c)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["square16.png"],
                       "no temporary files left behind")
    }

    func testEightBitPNGRoundTripAndLinearLightValue() async throws {
        let clip = try await loadFixture(.movingSquare)
        let composite = try await render(clip, indices: Array(0..<24)).image
        let url = directory.appendingPathComponent("square8.png")

        let report = try ImageExporter.writePNG(composite, to: url, bitDepth: .eight)
        XCTAssertEqual(report.bitDepth, 8)
        XCTAssertEqual(report.width, 480)
        XCTAssertEqual(report.height, 272)

        let readBack = try readBackPixels(url, bitDepth: .eight)
        let expected = PixelEncoder.encodeSRGB8(composite)
        for (x, y) in [(0, 0), (200, 96), (240, 220), (479, 271)] {
            for c in 0..<3 {
                let i = (y * 480 + x) * 3 + c
                XCTAssertEqual(readBack.rgb[i], Double(expected[i]) / 255, accuracy: 1.0 / 255, "(\(x),\(y)) c\(c)")
            }
        }
        // The square's 2-in-24 trail as stored in the file.
        XCTAssertEqual(readBack.rgb[(96 * 480 + 200) * 3] * 255, 82, accuracy: 3)
    }

    func testOverwriteReplacesExistingFile() throws {
        let url = directory.appendingPathComponent("out.png")
        try ImageExporter.writePNG(LinearImage(width: 4, height: 2, fill: SIMD4(0, 0, 0, 1)), to: url, bitDepth: .eight)
        let report = try ImageExporter.writePNG(LinearImage(width: 6, height: 3, fill: SIMD4(1, 1, 1, 1)), to: url, bitDepth: .eight)
        XCTAssertEqual(report.width, 6)
        XCTAssertEqual(try readBackPixels(url, bitDepth: .eight).rgb.first, 1)
    }

    func testTransparentCompositeIsRejectedNotSilentlyFlattened() {
        let url = directory.appendingPathComponent("alpha.png")
        XCTAssertThrowsError(try ImageExporter.writePNG(LinearImage(width: 2, height: 2, fill: SIMD4(0.25, 0.25, 0.25, 0.5)), to: url, bitDepth: .eight)) {
            XCTAssertEqual($0 as? MediaError, .transparencyNotSupported)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
