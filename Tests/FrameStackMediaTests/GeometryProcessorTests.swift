import CoreGraphics
import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// M5c: straighten, crop and edge fill applied once to the finished composite.
final class GeometryProcessorTests: XCTestCase {
    /// 100×100 black, a white 10×10 square whose top-left is at (10, 10), alpha 1.
    private func marker() -> LinearImage {
        var image = LinearImage(width: 100, height: 100, fill: SIMD4(0, 0, 0, 1))
        for y in 10..<20 { for x in 10..<20 { let i = (y * 100 + x) * 4; image.pixels[i] = 1; image.pixels[i + 1] = 1; image.pixels[i + 2] = 1 } }
        return image
    }

    func testCropOnlyIsExact() throws {
        let out = try GeometryProcessor.apply(GeometrySettings(crop: NormalizedRect(x: 0.05, y: 0.05, width: 0.3, height: 0.2)), to: marker())
        XCTAssertEqual(out.size, PixelSize(width: 30, height: 20))
        // The square now sits at (5, 5)…(15, 15).
        XCTAssertEqual(out.pixel(x: 10, y: 10).x, 1, accuracy: 1e-5)
        XCTAssertEqual(out.pixel(x: 4, y: 4).x, 0, accuracy: 1e-5)
        XCTAssertEqual(out.pixel(x: 16, y: 10).x, 0, accuracy: 1e-5)
        XCTAssertEqual(out.pixel(x: 10, y: 10).w, 1, accuracy: 1e-5)
    }

    func testRotationIsCounterClockwiseAboutTheCentreAndCornersBecomeTransparent() throws {
        let out = try GeometryProcessor.apply(GeometrySettings(rotationDegrees: 90), to: marker())
        XCTAssertEqual(out.size, PixelSize(width: 100, height: 100))
        // Top-left square → bottom-left after a 90° counter-clockwise turn.
        XCTAssertGreaterThan(out.pixel(x: 15, y: 85).x, 0.9)
        XCTAssertLessThan(out.pixel(x: 15, y: 15).x, 0.1)
        XCTAssertEqual(out.pixel(x: 50, y: 50).w, 1, accuracy: 1e-5)
        // A small angle leaves the corners uncovered.
        let tilted = try GeometryProcessor.apply(GeometrySettings(rotationDegrees: 10), to: marker())
        XCTAssertLessThan(tilted.pixel(x: 0, y: 0).w, 0.5)
        XCTAssertEqual(tilted.pixel(x: 50, y: 50).w, 1, accuracy: 1e-5)
        XCTAssertTrue(ImageExporter.hasTransparency(tilted))
        // The straighten crop removes them.
        var g = GeometrySettings(rotationDegrees: 10)
        g.crop = g.largestValidCrop(valid: nil, canvas: marker().size)
        let cropped = try GeometryProcessor.apply(g, to: marker())
        XCTAssertFalse(ImageExporter.hasTransparency(cropped), "largest inscribed rectangle has full coverage")
        XCTAssertLessThan(cropped.width, 100)
    }

    func testEdgeFillCompositesOverTheColour() throws {
        var image = LinearImage(width: 4, height: 1, fill: SIMD4(0.2, 0.2, 0.2, 1))
        image.pixels[0] = 0; image.pixels[1] = 0; image.pixels[2] = 0; image.pixels[3] = 0            // fully transparent
        image.pixels[4] = 0.1; image.pixels[5] = 0.1; image.pixels[6] = 0.1; image.pixels[7] = 0.5   // half coverage, straight gray 0.2
        let white = try GeometryProcessor.apply(GeometrySettings(edgeFill: .white), to: image)
        XCTAssertEqual(white.pixel(x: 0, y: 0), SIMD4(1, 1, 1, 1))
        XCTAssertEqual(white.pixel(x: 1, y: 0).x, 0.6, accuracy: 1e-6, "0.1 + 0.5 × 1")
        XCTAssertEqual(white.pixel(x: 1, y: 0).w, 1)
        XCTAssertEqual(white.pixel(x: 2, y: 0), SIMD4(0.2, 0.2, 0.2, 1), "opaque pixels untouched")
        let black = try GeometryProcessor.apply(GeometrySettings(edgeFill: .black), to: image)
        XCTAssertEqual(black.pixel(x: 1, y: 0).x, 0.1, accuracy: 1e-6)
        XCTAssertEqual(black.pixel(x: 1, y: 0).w, 1)
        let kept = try GeometryProcessor.apply(GeometrySettings(edgeFill: .transparent), to: image)
        XCTAssertEqual(kept.pixel(x: 1, y: 0).w, 0.5)
        XCTAssertEqual(try GeometryProcessor.apply(.identity, to: image).pixels, image.pixels, "identity is a no-op")
    }

    func testMixedSizeSequenceFitAndFill() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackFitFill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/sequence_png_12f")
        // a_0: 160×90 (the canvas); a_1: a 80×45 copy (half size); a_2: 60×90 (portrait-ish, same height).
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("frame_0.png"), to: scratch.appendingPathComponent("a_0.png"))
        try writeScaled(fixtures.appendingPathComponent("frame_1.png"), to: scratch.appendingPathComponent("a_1.png"), width: 80, height: 45)
        try writeScaled(fixtures.appendingPathComponent("frame_1.png"), to: scratch.appendingPathComponent("a_2.png"), width: 60, height: 90)

        await XCTAssertThrowsErrorAsync(try await ImageSequenceLoader.load([scratch])) { _ in }
        let fit = try await ImageSequenceLoader.load([scratch], canvasPolicy: .fit)
        XCTAssertEqual(fit.displaySize, PixelSize(width: 160, height: 90))
        XCTAssertEqual(fit.resizedFiles.map(\.fileName), ["a_1.png", "a_2.png"])
        XCTAssertTrue(fit.warnings.contains { $0.contains("scaled to fit") }, "\(fit.warnings)")
        XCTAssertEqual(fit.placement(for: PixelSize(width: 80, height: 45)).scale, 2)
        XCTAssertEqual(fit.placement(for: PixelSize(width: 60, height: 90)).scale, 1)
        XCTAssertEqual(fit.placement(for: PixelSize(width: 60, height: 90)).offset, CGPoint(x: 50, y: 0))

        let timeline = fit.timeline
        func render(_ seq: ImageSequenceInfo, _ i: Int) async throws -> LinearImage {
            try await sharedRenderer.render(CompositeRequest(source: .imageSequence(seq), frames: [timeline.frames[i]], blendMode: .average, maxLongEdge: nil)).image
        }
        let half = try await render(fit, 1)
        XCTAssertEqual(half.size, PixelSize(width: 160, height: 90), "canvas size kept")
        XCTAssertEqual(half.pixel(x: 80, y: 45).w, 1, "upscaled 2× covers the whole canvas")
        let narrow = try await render(fit, 2)
        XCTAssertEqual(narrow.pixel(x: 10, y: 45).w, 0, accuracy: 1e-5, "transparent bar on the left")
        XCTAssertEqual(narrow.pixel(x: 80, y: 45).w, 1, accuracy: 1e-5, "image in the middle")
        XCTAssertEqual(narrow.pixel(x: 150, y: 45).w, 0, accuracy: 1e-5, "transparent bar on the right")

        let fill = try await ImageSequenceLoader.load([scratch], canvasPolicy: .fill)
        XCTAssertEqual(fill.placement(for: PixelSize(width: 60, height: 90)).scale, 160.0 / 60, accuracy: 1e-9)
        let covered = try await render(fill, 2)
        XCTAssertEqual(covered.pixel(x: 10, y: 45).w, 1, accuracy: 1e-5, "fill covers the whole canvas")
        XCTAssertEqual(covered.pixel(x: 150, y: 45).w, 1, accuracy: 1e-5)
        // The reference wins with the policy; a format-1/2 document without it reads as strict.
        let ref = SequenceReference(fit)
        XCTAssertEqual(ref.canvasPolicy, .fit)
        let decoded = try JSONDecoder().decode(SequenceReference.self, from: Data("{\"fileNames\":[\"a\"],\"framesPerSecond\":30,\"reversed\":false}".utf8))
        XCTAssertEqual(decoded.canvasPolicy, .strict)
    }

    private func writeScaled(_ source: URL, to url: URL, width: Int, height: Int) throws {
        let src = CGImageSourceCreateWithURL(source as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let out = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, out, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
