@testable import FrameStackCore
import XCTest

final class PaintedMaskTests: XCTestCase {
    func testFalloff() {
        XCTAssertEqual(PaintedMaskRasterizer.falloff(distance: 0, radius: 10, softness: 0.5), 1)
        XCTAssertEqual(PaintedMaskRasterizer.falloff(distance: 5, radius: 10, softness: 0.5), 1, "hard core")
        XCTAssertEqual(PaintedMaskRasterizer.falloff(distance: 7.5, radius: 10, softness: 0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(PaintedMaskRasterizer.falloff(distance: 10, radius: 10, softness: 0.5), 0)
        XCTAssertEqual(PaintedMaskRasterizer.falloff(distance: 9, radius: 10, softness: 0), 1, "hard brush")
        XCTAssertEqual(PaintedMaskRasterizer.falloff(distance: 5, radius: 10, softness: 1), 0.5, accuracy: 1e-6, "fully soft is linear")
    }

    func testStampsResolutionIndependentDiscs() {
        let size = PixelSize(width: 100, height: 50)
        // A dot at the centre with radius 0.1 of the long edge (10 px), hard.
        let dot = PaintedMaskSettings(enabled: true, strokes: [MaskStroke(points: [.init(x: 0.5, y: 0.5)], radius: 0.1, softness: 0)])
        let m = PaintedMaskRasterizer.raster(dot, size: size)
        XCTAssertEqual(m[25 * 100 + 50], 1)
        XCTAssertEqual(m[25 * 100 + 58], 1, "8 px away: inside")
        XCTAssertEqual(m[25 * 100 + 62], 0, "12 px away: outside")
        XCTAssertEqual(m[0], 0)
        // Twice the output size → the disc scales with it.
        let big = PaintedMaskRasterizer.raster(dot, size: PixelSize(width: 200, height: 100))
        XCTAssertEqual(big[50 * 200 + 118], 1, "18 px away of a 20 px radius")
        XCTAssertEqual(big[50 * 200 + 122], 0)
        let area = m.reduce(0, +), bigArea = big.reduce(0, +)
        XCTAssertEqual(Double(bigArea) / Double(area), 4, accuracy: 0.15, "area scales with the square of the size")
    }

    func testPolylineIsContinuousAndEraseSubtracts() {
        let size = PixelSize(width: 200, height: 100)
        let line = MaskStroke(points: [.init(x: 0.1, y: 0.5), .init(x: 0.9, y: 0.5)], radius: 0.03, softness: 0)
        var settings = PaintedMaskSettings(enabled: true, strokes: [line])
        let m = PaintedMaskRasterizer.raster(settings, size: size)
        // Every column between the ends is painted at the centre row.
        for x in 20...180 { XCTAssertEqual(m[50 * 200 + x], 1, "x \(x)") }
        XCTAssertEqual(m[50 * 200 + 5], 0)
        XCTAssertEqual(m[10 * 200 + 100], 0, "far from the line")
        // Erase the middle.
        settings.strokes.append(MaskStroke(points: [.init(x: 0.5, y: 0.5)], radius: 0.05, softness: 0, erase: true))
        let erased = PaintedMaskRasterizer.raster(settings, size: size)
        XCTAssertEqual(erased[50 * 200 + 100], 0, "erased at the centre")
        XCTAssertEqual(erased[50 * 200 + 40], 1, "untouched elsewhere")
        // Invert.
        settings.invert = true
        let inv = PaintedMaskRasterizer.raster(settings, size: size)
        XCTAssertEqual(inv[50 * 200 + 100], 1)
        XCTAssertEqual(inv[50 * 200 + 40], 0)
        XCTAssertEqual(inv[0], 1)
    }

    func testSoftEdgeAndCodable() throws {
        let size = PixelSize(width: 100, height: 100)
        let soft = PaintedMaskSettings(enabled: true, strokes: [MaskStroke(points: [.init(x: 0.5, y: 0.5)], radius: 0.2, softness: 1)])
        let m = PaintedMaskRasterizer.raster(soft, size: size)
        XCTAssertEqual(m[50 * 100 + 50], 1, accuracy: 0.05)
        XCTAssertEqual(m[50 * 100 + 60], 0.5, accuracy: 0.05, "halfway out of a fully soft 20 px brush")
        XCTAssertEqual(m[50 * 100 + 71], 0, accuracy: 0.01)
        let data = try JSONEncoder().encode(soft)
        XCTAssertEqual(try JSONDecoder().decode(PaintedMaskSettings.self, from: data), soft)
        let json = """
        {"rangeStart":{"value":0,"timescale":1},"rangeEnd":{"value":1,"timescale":1},"samplingKind":"all","nth":1,"exactCount":1,"blendMode":"average","opacity":1}
        """
        XCTAssertEqual(try JSONDecoder().decode(CompositeSettings.self, from: Data(json.utf8)).paintedMask, .off)
        XCTAssertTrue(PaintedMaskSettings.off.isEmpty)
    }
}
