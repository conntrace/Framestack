import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// D-009 revisited (D-020): sources with more than 8 bits per component are
/// decoded to half-float RGBA so their precision survives into the composite.
final class TenBitDecodeTests: XCTestCase {
    override func tearDown() {
        CompositeRenderer.forceEightBitDecode = false
    }

    /// Distinct values along one row of the ramp, in 1/100000 linear steps.
    private func distinctLevels(_ image: LinearImage, row: Int = 90) -> Int {
        var set = Set<Int>()
        for x in 0..<image.width {
            set.insert(Int((image.pixels[(row * image.width + x) * 4] * 100_000).rounded()))
        }
        return set.count
    }

    func testTenBitSourceIsIdentifiedAndKeepsItsPrecision() async throws {
        let clip = try await loadFixture(.tenBit)
        XCTAssertEqual(clip.info.codec, "hvc1")
        XCTAssertEqual(clip.info.bitsPerComponent, 10)
        XCTAssertTrue(clip.info.wantsHighPrecisionDecode)
        XCTAssertEqual(clip.timeline.count, 10)

        let result = try await render(clip, indices: Array(0..<10))
        XCTAssertEqual(result.framesComposited, 10)
        XCTAssertEqual(result.missingFrames, [])
        let levels = distinctLevels(result.image)
        XCTAssertGreaterThanOrEqual(levels, 300, "every one of the 320 columns has its own 10-bit code; got \(levels) distinct values")
        // Ramp ends: black, and white (code 940 → 1.0, allowing half-float rounding).
        XCTAssertEqual(result.image.pixels[(90 * 320) * 4], 0, accuracy: 0.002)
        XCTAssertEqual(result.image.pixels[(90 * 320 + 319) * 4], 1, accuracy: 0.003)
        // Monotonic along the row.
        var previous: Float = -1
        for x in 0..<320 {
            let v = result.image.pixels[(90 * 320 + x) * 4]
            XCTAssertGreaterThanOrEqual(v, previous - 1e-6, "column \(x)")
            previous = v
        }
        saveArtifact(result.image, name: "tenbit_ramp_average_halffloat")

        // 16-bit export carries the extra levels; 8-bit cannot.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackTenBit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ramp16.png")
        try ImageExporter.writePNG(result.image, to: url, bitDepth: .sixteen)
        let readBack = try readBackPixels(url, bitDepth: .sixteen)
        var fileLevels = Set<Int>()
        for x in 0..<320 { fileLevels.insert(Int((readBack.rgb[(90 * 320 + x) * 3] * 65_535).rounded())) }
        XCTAssertGreaterThanOrEqual(fileLevels.count, 300, "16-bit PNG keeps the 10-bit ramp: \(fileLevels.count) levels")
    }

    func testEightBitDecodeOfTheSameClipLosesLevels() async throws {
        CompositeRenderer.forceEightBitDecode = true
        let clip = try await loadFixture(.tenBit)
        let result = try await render(clip, indices: Array(0..<10))
        let levels = distinctLevels(result.image)
        XCTAssertLessThanOrEqual(levels, 220, "8-bit limited range has 219 codes; got \(levels)")
        XCTAssertGreaterThan(levels, 150)
        saveArtifact(result.image, name: "tenbit_ramp_average_8bit")
    }

    func testEightBitSourcesStillUseTheEightBitPath() async throws {
        let clip = try await loadFixture(.count)
        XCTAssertNil(clip.info.bitsPerComponent, "H.264 8-bit clips carry no BitsPerComponent extension; 8 is assumed")
        XCTAssertFalse(clip.info.wantsHighPrecisionDecode)
    }
}
