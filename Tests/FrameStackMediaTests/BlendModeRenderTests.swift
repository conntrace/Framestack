import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// Every blend mode on real decoded fixtures (PRD §11.2 acceptance
/// scenarios): bright/dark trails, last-frame-wins, order dependence, and
/// preview/export consistency. Tolerances cover codec noise (crf 8–12).
final class BlendModeRenderTests: XCTestCase {
    // MARK: Alternating black / white frames (30 frames, even = black)

    func testBlackWhiteClipFixedValuesPerMode() async throws {
        let clip = try await loadFixture(.blackWhite)
        let all = Array(0..<30)
        /// Mean of the central region after rendering `indices` with `mode`.
        func center(_ indices: [Int], _ mode: BlendMode, opacity: Float = 1) async throws -> Float {
            let r = try await render(clip, indices: indices, mode: mode, opacity: opacity)
            XCTAssertEqual(r.framesComposited, indices.count)
            return r.image.mean(x: 60..<100, y: 30..<66).x
        }

        let average = try await center(all, .average)
        XCTAssertEqual(average, 0.5, accuracy: 0.01)
        let lighten = try await center(all, .lighten)
        XCTAssertEqual(lighten, 1, accuracy: 0.01)
        let darken = try await center(all, .darken)
        XCTAssertEqual(darken, 0, accuracy: 0.01)
        let screen = try await center(all, .screen)
        XCTAssertEqual(screen, 1, accuracy: 0.01, "any white frame screens to white")
        let multiply = try await center(all, .multiply)
        XCTAssertEqual(multiply, 0, accuracy: 0.01, "any black frame multiplies to black")
        // Difference: 0,1,1,0,0,1,1,0,… → after frame 29: 1.
        let difference = try await center(all, .difference)
        XCTAssertEqual(difference, 1, accuracy: 0.02)
        // After frame 28 (0-based; (28−1) mod 4 = 3) the pattern gives 0.
        let difference29 = try await center(Array(0..<29), .difference)
        XCTAssertEqual(difference29, 0, accuracy: 0.02)
        // Normal 100 %: the last frame (29, white). Dropping the last frame: black.
        let normal = try await center(all, .normal)
        XCTAssertEqual(normal, 1, accuracy: 0.01)
        let normal29 = try await center(Array(0..<29), .normal)
        XCTAssertEqual(normal29, 0, accuracy: 0.01)
        // Normal 50 %: 0.5·f29 + 0.25·f28 + 0.125·f27 … = 0.5 (1 + 1/4 + 1/16 + …) = 2/3.
        let normalHalf = try await center(all, .normal, opacity: 0.5)
        XCTAssertEqual(normalHalf, 2.0 / 3, accuracy: 0.02)
        // Additive: 15 white frames → 15 (kept above 1).
        let additive = try await center(all, .additive)
        XCTAssertEqual(additive, 15, accuracy: 0.2)
        let additiveTenth = try await center(all, .additive, opacity: 0.1)
        XCTAssertEqual(additiveTenth, 1.5, accuracy: 0.05)
    }

    // MARK: Moving white square over black with a static gray bar (24 frames)

    func testMovingSquareTrailsPerMode() async throws {
        let clip = try await loadFixture(.movingSquare)
        let all = Array(0..<24)
        let trail = (x: 100..<300, y: 84..<108)      // columns covered by the square at some frame
        let never = (x: 100..<300, y: 150..<190)     // background never covered
        let bar = (x: 100..<380, y: 210..<230)

        let single = try await render(clip, indices: [5])
        let barOne = single.image.mean(x: bar.x, y: bar.y).x

        let lighten = try await render(clip, indices: all, mode: .lighten)
        saveArtifact(lighten.image, name: "moving_square_lighten")
        XCTAssertEqual(lighten.image.mean(x: trail.x, y: trail.y).x, 1, accuracy: 0.02, "bright trail fully preserved")
        XCTAssertLessThan(lighten.image.mean(x: never.x, y: never.y).x, 0.01)
        XCTAssertEqual(lighten.image.mean(x: bar.x, y: bar.y).x, barOne, accuracy: 0.01, "static content unchanged")

        let darken = try await render(clip, indices: all, mode: .darken)
        saveArtifact(darken.image, name: "moving_square_darken")
        XCTAssertLessThan(darken.image.mean(x: trail.x, y: trail.y).x, 0.01, "moving bright object vanishes")
        XCTAssertEqual(darken.image.mean(x: bar.x, y: bar.y).x, barOne, accuracy: 0.01)

        let average = try await render(clip, indices: all, mode: .average)
        XCTAssertEqual(average.image.mean(x: 195..<205, y: 88..<104).x, 1.0 / 12, accuracy: 0.01, "2 of 24 frames")

        let screen = try await render(clip, indices: all, mode: .screen)
        saveArtifact(screen.image, name: "moving_square_screen")
        XCTAssertEqual(screen.image.mean(x: trail.x, y: trail.y).x, 1, accuracy: 0.02, "screen with white gives white")
        // Screen of the bar with itself 24 times: 1 − (1 − g)^24.
        let g = Double(barOne)
        XCTAssertEqual(Double(screen.image.mean(x: bar.x, y: bar.y).x), 1 - pow(1 - g, 24), accuracy: 0.02)

        let multiply = try await render(clip, indices: all, mode: .multiply)
        saveArtifact(multiply.image, name: "moving_square_multiply")
        XCTAssertLessThan(multiply.image.mean(x: trail.x, y: trail.y).x, 0.01, "multiplied by black somewhere")
        XCTAssertEqual(Double(multiply.image.mean(x: bar.x, y: bar.y).x), pow(g, 24), accuracy: 0.01)

        let normal = try await render(clip, indices: all, mode: .normal)
        saveArtifact(normal.image, name: "moving_square_normal100")
        let last = try await render(clip, indices: [23])
        for (x, y) in [(50, 90), (380, 96), (200, 96), (300, 220)] {
            XCTAssertEqual(normal.image.mean(x: (x - 4)..<(x + 4), y: (y - 4)..<(y + 4)).x,
                           last.image.mean(x: (x - 4)..<(x + 4), y: (y - 4)..<(y + 4)).x, accuracy: 0.01,
                           "normal 100 % is the last frame at (\(x),\(y))")
        }

        let faded = try await render(clip, indices: all, mode: .normal, opacity: 0.5)
        saveArtifact(faded.image, name: "moving_square_normal50")
        // Each column is covered by two consecutive frames. Last position
        // (frame 23, x 384..416): columns only it covers → 0.5; columns also
        // covered by frame 22 → 0.5 + 0.25 = 0.75; frames 21+22 only → 0.375.
        XCTAssertEqual(faded.image.mean(x: 402..<414, y: 88..<104).x, 0.5, accuracy: 0.02)
        XCTAssertEqual(faded.image.mean(x: 386..<398, y: 88..<104).x, 0.75, accuracy: 0.02)
        XCTAssertEqual(faded.image.mean(x: 370..<382, y: 88..<104).x, 0.375, accuracy: 0.02)

        let additive = try await render(clip, indices: all, mode: .additive)
        saveArtifact(additive.image, name: "moving_square_additive")
        XCTAssertEqual(additive.image.mean(x: 195..<205, y: 88..<104).x, 2, accuracy: 0.05, "covered twice → 2.0, not clipped")
        XCTAssertEqual(Double(additive.image.mean(x: bar.x, y: bar.y).x), 24 * g, accuracy: 0.1)

        let difference = try await render(clip, indices: all, mode: .difference)
        saveArtifact(difference.image, name: "moving_square_difference")
        XCTAssertLessThan(difference.image.mean(x: bar.x, y: bar.y).x, 0.01, "static content cancels to black")
    }

    // MARK: Frame identity with order-dependent modes (150-frame count clip)

    func testCountClipNormalIsLastFrameLightenIsAllBitsDarkenIsNone() async throws {
        let clip = try await loadFixture(.count)
        let normal = try await render(clip, indices: Array(0..<150), mode: .normal)
        XCTAssertEqual(decodeFrameIndex(normal.image), 149)
        XCTAssertTrue(normal.deliveredInPresentationOrder)

        let subset = try await render(clip, indices: [3, 77, 120], mode: .normal)
        XCTAssertEqual(decodeFrameIndex(subset.image), 120, "last *selected* frame, not last in file")

        let lighten = try await render(clip, indices: Array(0..<150), mode: .lighten)
        XCTAssertEqual(decodeFrameIndex(lighten.image), 255, "every bit is set in some frame")
        let darken = try await render(clip, indices: Array(0..<150), mode: .darken)
        XCTAssertEqual(decodeFrameIndex(darken.image), 0)
    }

    // MARK: Preview and export agree for every mode

    func testReducedPreviewMatchesFullResolutionForEveryMode() async throws {
        let clip = try await loadFixture(.movingSquare)
        for mode in BlendMode.allCases {
            let full = try await render(clip, indices: Array(0..<24), mode: mode, opacity: 0.6)
            let preview = try await render(clip, indices: Array(0..<24), mode: mode, opacity: 0.6, maxLongEdge: 240)
            XCTAssertEqual(preview.image.size, PixelSize(width: 240, height: 136))
            let pairs: [((Range<Int>, Range<Int>), (Range<Int>, Range<Int>))] = [
                ((100..<300, 84..<108), (50..<150, 42..<54)),    // trail band
                ((100..<380, 210..<230), (50..<190, 105..<115)), // bar
                ((100..<300, 150..<190), (50..<150, 75..<95)),   // black
            ]
            for ((fx, fy), (px, py)) in pairs {
                XCTAssertEqual(full.image.mean(x: fx, y: fy).x, preview.image.mean(x: px, y: py).x, accuracy: 0.02, "\(mode)")
            }
        }
    }
}
