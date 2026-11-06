import CoreGraphics
import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// Display-referred source frames for the filmstrip and the playhead view.
final class SourceFramesTests: XCTestCase {
    /// Reads the 8-bit binary frame index from a display-referred CGImage of
    /// the count fixture (blocks are pure black/white, so a mid threshold
    /// on encoded values is enough).
    private func frameIndex(of image: CGImage) throws -> Int {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        try buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw MediaError.exportVerificationFailed("no context")
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let blockWidth = w / 8
        var value = 0
        for b in 0..<8 {
            let cx = b * blockWidth + blockWidth / 2
            let cy = h * 20 / 180
            var sum = 0, n = 0
            for y in (cy - 2)...(cy + 2) {
                for x in (cx - 2)...(cx + 2) {
                    sum += Int(buffer[(y * w + x) * 4])
                    n += 1
                }
            }
            if sum / n > 128 { value |= 1 << (7 - b) }
        }
        return value
    }

    func testExactFrameAtTimeIsThatFrame() async throws {
        let clip = try await loadFixture(.count)
        for k in [0, 1, 2, 74, 75, 149] {
            let image = try await SourceFrames.frame(for: clip.info, at: clip.timeline.frames[k], maxLongEdge: nil)
            XCTAssertEqual(image.width, 320)
            XCTAssertEqual(image.height, 180)
            XCTAssertEqual(try frameIndex(of: image), k, "frame \(k)")
        }
    }

    func testFrameIsBoundedAndOriented() async throws {
        let clip = try await loadFixture(.portrait)
        let image = try await SourceFrames.frame(for: clip.info, at: clip.timeline.frames[0], maxLongEdge: 160)
        XCTAssertEqual(image.height, 160, "long edge bounded")
        XCTAssertEqual(image.width, 90, "portrait after the display transform")
    }

    func testThumbnailsSpanTheClipInOrder() async throws {
        let clip = try await loadFixture(.count)
        let thumbs = try await SourceFrames.thumbnails(for: clip.info, timeline: clip.timeline, count: 10, maxHeight: 44)
        XCTAssertEqual(thumbs.count, 10)
        for (i, t) in thumbs.enumerated() {
            XCTAssertLessThanOrEqual(t.image.height, 44)
            XCTAssertEqual(Double(t.image.width) / Double(t.image.height), 320.0 / 180, accuracy: 0.05)
            XCTAssertTrue(clip.timeline.frames.contains(t.time), "thumbnail \(i) is a real frame time")
            if i > 0 { XCTAssertGreaterThan(t.time, thumbs[i - 1].time, "ascending") }
        }
        // Bin centres: first thumbnail from the first 10 % of the clip, last from the last 10 %.
        XCTAssertLessThan(thumbs.first!.time.seconds, 0.5)
        XCTAssertGreaterThan(thumbs.last!.time.seconds, 4.5)
    }

    func testThumbnailsOfPortraitClipAreUpright() async throws {
        let clip = try await loadFixture(.portrait)
        let thumbs = try await SourceFrames.thumbnails(for: clip.info, timeline: clip.timeline, count: 3, maxHeight: 64)
        XCTAssertEqual(thumbs.count, 3)
        for t in thumbs {
            XCTAssertEqual(t.image.height, 64)
            XCTAssertEqual(t.image.width, 36)
        }
    }
}
