@testable import FrameStackCore
import XCTest

final class GeometrySettingsTests: XCTestCase {
    let canvas = PixelSize(width: 400, height: 300)

    func testNormalizedRectClampingAndPixels() {
        let r = NormalizedRect(x: 0.5, y: -0.2, width: 0.8, height: 0.5).clamped(in: canvas)
        XCTAssertEqual(r.width, 0.8)
        XCTAssertEqual(r.x, 0.2, accuracy: 1e-12, "pushed back inside")
        XCTAssertEqual(r.y, 0)
        XCTAssertEqual(r.height, 0.5)
        XCTAssertEqual(NormalizedRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25).pixelRect(in: canvas), CGRect(x: 100, y: 150, width: 200, height: 75))
        XCTAssertEqual(NormalizedRect(x: 0, y: 0, width: 0.0001, height: 0.0001).clamped(in: canvas).pixelRect(in: canvas).width, 1, "never empty")
        XCTAssertEqual(NormalizedRect.from(pixels: CGRect(x: 100, y: 150, width: 200, height: 75), in: canvas),
                       NormalizedRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        XCTAssertTrue(NormalizedRect.full.isFull)
    }

    func testOutputSizeFollowsTheCrop() {
        var g = GeometrySettings()
        XCTAssertTrue(g.isIdentity)
        XCTAssertEqual(g.outputSize(for: canvas), canvas)
        g.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        XCTAssertEqual(g.outputSize(for: canvas), PixelSize(width: 200, height: 150))
        XCTAssertEqual(g.outputSize(for: PixelSize(width: 4000, height: 3000)), PixelSize(width: 2000, height: 1500), "scales with the output size")
        XCTAssertTrue(g.hasTransform)
    }

    func testLargestInscribedRectangle() {
        // No rotation: the rectangle itself.
        let (w0, h0) = GeometrySettings.largestInscribedSize(width: 400, height: 300, angle: 0)
        XCTAssertEqual(w0, 400, accuracy: 1e-9)
        XCTAssertEqual(h0, 300, accuracy: 1e-9)
        // 90°: swapped.
        let (w90, h90) = GeometrySettings.largestInscribedSize(width: 400, height: 300, angle: .pi / 2)
        XCTAssertEqual(w90, 300, accuracy: 1e-6)
        XCTAssertEqual(h90, 400, accuracy: 1e-6)
        // 10°: strictly smaller than the original and inside it; the formula's known value.
        let a = 10 * Double.pi / 180
        let (w10, h10) = GeometrySettings.largestInscribedSize(width: 400, height: 300, angle: a)
        XCTAssertLessThan(w10, 400)
        XCTAssertLessThan(h10, 300)
        let cos2 = cos(a) * cos(a) - sin(a) * sin(a)
        XCTAssertEqual(w10, (400 * cos(a) - 300 * sin(a)) / cos2, accuracy: 1e-9)
        XCTAssertEqual(h10, (300 * cos(a) - 400 * sin(a)) / cos2, accuracy: 1e-9)
        // Square at 45°: half-constrained case, side/√2.
        let (w45, h45) = GeometrySettings.largestInscribedSize(width: 100, height: 100, angle: .pi / 4)
        XCTAssertEqual(w45, 100 / sqrt(2), accuracy: 1e-9)
        XCTAssertEqual(h45, 100 / sqrt(2), accuracy: 1e-9)
    }

    func testCropToValidAreaWithAndWithoutRotation() {
        var g = GeometrySettings()
        // No rotation: the valid area itself, normalised.
        let valid = CGRect(x: 20, y: 30, width: 300, height: 200)
        XCTAssertEqual(g.largestValidCrop(valid: valid, canvas: canvas), NormalizedRect(x: 0.05, y: 0.1, width: 0.75, height: 200.0 / 300))
        XCTAssertEqual(g.largestValidCrop(valid: nil, canvas: canvas), .full)
        // Rotation: the crop shrinks and stays inside the canvas.
        g.rotationDegrees = 5
        let c = g.largestValidCrop(valid: nil, canvas: canvas)
        XCTAssertLessThan(c.width, 1)
        XCTAssertLessThan(c.height, 1)
        XCTAssertGreaterThanOrEqual(c.x, 0)
        XCTAssertLessThanOrEqual(c.x + c.width, 1 + 1e-9)
        let (w5, h5) = GeometrySettings.largestInscribedSize(width: 400, height: 300, angle: 5 * .pi / 180)
        XCTAssertEqual(c.width * 400, w5, accuracy: 1)
        XCTAssertEqual(c.height * 300, h5, accuracy: 1)
        XCTAssertEqual(c.x + c.width / 2, 0.5, accuracy: 0.01, "centred when the whole canvas is valid")
    }

    func testCodableDefaultsAndEdgeFill() throws {
        let json = """
        {"rangeStart":{"value":0,"timescale":1},"rangeEnd":{"value":1,"timescale":1},"samplingKind":"all","nth":1,"exactCount":1,"blendMode":"average","opacity":1}
        """
        let settings = try JSONDecoder().decode(CompositeSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.geometry, .identity)
        let g = GeometrySettings(rotationDegrees: -2.5, crop: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), edgeFill: .white)
        let data = try JSONEncoder().encode(g)
        XCTAssertEqual(try JSONDecoder().decode(GeometrySettings.self, from: data), g)
        XCTAssertEqual(EdgeFill.white.linearColor, SIMD3(1, 1, 1))
        XCTAssertNil(EdgeFill.transparent.linearColor)
    }
}
