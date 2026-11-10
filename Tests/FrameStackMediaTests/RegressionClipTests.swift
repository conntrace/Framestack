import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// M6k (PRD §13): the two classic stacking subjects as synthetic clips with
/// known answers — a small light crossing the dark, and a dark shape crossing
/// a light wall — plus the transfer-tag warnings.
final class RegressionClipTests: XCTestCase {
    private let all = Array(0..<24)

    // MARK: Bright point on dark

    /// Trail interior: the point's rows away from its top and bottom edge,
    /// the columns every frame's point passes fully over.
    private let trail = (x: 24..<200, y: 90..<94)
    private let darkSky = (x: 0..<320, y: 0..<70)

    func testBrightPointLightenKeepsTheWholeTrail() async throws {
        let clip = try await loadFixture(.brightPoint)
        XCTAssertEqual(clip.timeline.count, 24)
        let single = try await render(clip, indices: [5]).image
        // One frame: the point where it is (x 56..<64), black elsewhere.
        XCTAssertEqual(single.mean(x: 58..<62, y: 90..<94).x, 1, accuracy: 0.04)
        XCTAssertLessThan(single.mean(x: 80..<200, y: 90..<94).x, 0.005)

        for mode in [BlendMode.lighten, .maxLuminance, .screen] {
            let image = try await render(clip, indices: all, mode: mode).image
            let t = image.mean(x: trail.x, y: trail.y)
            XCTAssertEqual(t.x, 1, accuracy: 0.04, "\(mode): the trail is as bright as the point")
            XCTAssertEqual(t.x, t.y, accuracy: 0.01)
            XCTAssertEqual(t.x, t.z, accuracy: 0.01)
            XCTAssertLessThan(image.mean(x: darkSky.x, y: darkSky.y).x, 0.005, "\(mode): the dark stays dark")
            // Past the last position (x ≥ 208) nothing was ever lit.
            XCTAssertLessThan(image.mean(x: 216..<320, y: 80..<104).x, 0.005, "\(mode)")
        }
    }

    func testBrightPointAverageDimsTheTrailToOneFrameInTwentyFour() async throws {
        let clip = try await loadFixture(.brightPoint)
        let average = try await render(clip, indices: all, mode: .average).image
        XCTAssertEqual(Double(average.mean(x: trail.x, y: trail.y).x), 1.0 / 24, accuracy: 0.004,
                       "each column is lit by one frame of 24")
        XCTAssertLessThan(average.mean(x: darkSky.x, y: darkSky.y).x, 0.002)
        // Half the frames: the trail is half as long and twice as bright.
        let half = try await render(clip, indices: Array(0..<12), mode: .average).image
        XCTAssertEqual(Double(half.mean(x: 24..<104, y: 90..<94).x), 1.0 / 12, accuracy: 0.008)
        XCTAssertLessThan(half.mean(x: 120..<200, y: 90..<94).x, 0.003)
    }

    func testBrightPointVanishesInDarkenAndMedian() async throws {
        let clip = try await loadFixture(.brightPoint)
        for mode in [BlendMode.darken, .median, .minLuminance, .multiply] {
            let image = try await render(clip, indices: all, mode: mode).image
            XCTAssertLessThan(image.mean(x: trail.x, y: trail.y).x, 0.005, "\(mode): something lit once is not kept")
            XCTAssertLessThan(image.pixels.max() ?? 1, 1.0001)
            XCTAssertLessThan(image.mean(x: 0..<320, y: 0..<180).x, 0.002, "\(mode)")
        }
    }

    // MARK: Moving silhouette on a light wall

    /// Columns covered by exactly three frames, rows inside the shape.
    private let band = (x: 40..<200, y: 48..<128)
    private let wall = (x: 0..<320, y: 144..<176)

    func testSilhouetteDarkenKeepsTheShapeLightenAndMedianRemoveIt() async throws {
        let clip = try await loadFixture(.silhouette)
        let single = try await render(clip, indices: [10]).image
        // Frame 10: shape at x 96..<120.
        let dark = single.mean(x: 100..<116, y: band.y).x
        let light = single.mean(x: wall.x, y: wall.y).x
        XCTAssertLessThan(dark, 0.02)
        XCTAssertEqual(Double(light), 0.58, accuracy: 0.06, "sRGB 200 in linear light")

        let darken = try await render(clip, indices: all, mode: .darken).image
        XCTAssertEqual(darken.mean(x: band.x, y: band.y).x, dark, accuracy: 0.01, "the shape smears into a dark band")
        XCTAssertEqual(darken.mean(x: wall.x, y: wall.y).x, light, accuracy: 0.01)
        XCTAssertEqual(darken.mean(x: 240..<320, y: band.y).x, light, accuracy: 0.01, "never covered: still wall")

        for mode in [BlendMode.lighten, .median, .maxLuminance] {
            let image = try await render(clip, indices: all, mode: mode).image
            XCTAssertEqual(image.mean(x: band.x, y: band.y).x, light, accuracy: 0.015, "\(mode): the wall without the passer-by")
            XCTAssertEqual(image.mean(x: wall.x, y: wall.y).x, light, accuracy: 0.01, "\(mode)")
        }
    }

    func testSilhouetteAverageIsTheLinearMixOfThreeFramesInTwentyFour() async throws {
        let clip = try await loadFixture(.silhouette)
        let single = try await render(clip, indices: [10]).image
        let dark = Double(single.mean(x: 100..<116, y: band.y).x)
        let light = Double(single.mean(x: wall.x, y: wall.y).x)
        let average = try await render(clip, indices: all, mode: .average).image
        let expected = (3 * dark + 21 * light) / 24
        XCTAssertEqual(Double(average.mean(x: band.x, y: band.y).x), expected, accuracy: 0.006)
        // A ghost, not a hole: clearly darker than the wall, far lighter than the shape.
        XCTAssertLessThan(expected, light - 0.05)
        XCTAssertEqual(Double(average.mean(x: wall.x, y: wall.y).x), light, accuracy: 0.005)
        // The same mix done on encoded values would be visibly different
        // (PRD §8.1: averaging happens in linear light).
        let encodedMix = SRGBTransfer.decode((3 * SRGBTransfer.encode(dark) + 21 * SRGBTransfer.encode(light)) / 24)
        XCTAssertGreaterThan(abs(encodedMix - expected), 0.02)
    }

    // MARK: Transfer-tag warnings

    func testLogTaggedClipIsWarnedAbout() async throws {
        let clip = try await loadFixture(.logTagged)
        XCTAssertEqual(clip.info.transferFunction, "TransferFunction#9")
        XCTAssertEqual(clip.info.transferKind, .logarithmic)
        XCTAssertFalse(clip.info.isHDR)
        XCTAssertEqual(clip.info.warnings.count, 1)
        XCTAssertTrue(clip.info.warnings[0].contains("logarithmic") && clip.info.warnings[0].contains("no log conversion"), clip.info.warnings[0])
        // It still stacks (as stored), so the owner can see what they have.
        let result = try await sharedRenderer.render(CompositeRequest(source: .video(clip.info), frames: clip.timeline.frames,
                                                                      blendMode: .average, maxLongEdge: nil))
        XCTAssertEqual(result.framesComposited, 8)
    }

    func testOrdinaryAndUntaggedClipsAreNotWarnedAbout() async throws {
        let tagged = try await loadFixture(.movingSquare)
        XCTAssertEqual(tagged.info.transferKind, .standard)
        XCTAssertTrue(tagged.info.warnings.isEmpty, "\(tagged.info.warnings)")
        let untagged = try await loadFixture(.handheld)
        XCTAssertEqual(untagged.info.transferKind, .untagged)
        XCTAssertTrue(untagged.info.warnings.isEmpty, "\(untagged.info.warnings)")
    }

    func testTransferTagClassification() async throws {
        let base = try await loadFixture(.movingSquare).info
        func kind(_ tag: String?) -> VideoSourceInfo.TransferKind { base.with(transferFunction: tag).transferKind }
        XCTAssertEqual(kind(nil), .untagged)
        for tag in ["ITU_R_709_2", "IEC_sRGB", "Linear", "ITU_R_2020", "SMPTE_240M_1995", "UseGamma"] { XCTAssertEqual(kind(tag), .standard, tag) }
        for tag in ["SMPTE_ST_2084_PQ", "ITU_R_2100_HLG"] { XCTAssertEqual(kind(tag), .hdr, tag) }
        for tag in ["TransferFunction#9", "TransferFunction#10", "AppleLog", "S-Log3"] { XCTAssertEqual(kind(tag), .logarithmic, tag) }
        XCTAssertEqual(kind("TransferFunction#12"), .unrecognised("TransferFunction#12"))
        XCTAssertTrue(base.with(transferFunction: "TransferFunction#12").warnings.contains { $0.contains("TransferFunction#12") })
    }
}

private extension VideoSourceInfo {
    /// The same clip with another transfer tag (classification only; nothing is decoded with it).
    func with(transferFunction tag: String?) -> VideoSourceInfo {
        VideoSourceInfo(url: url, fileSizeBytes: fileSizeBytes, trackID: trackID, encodedSize: encodedSize,
                        displaySize: displaySize, orientation: orientation, duration: duration,
                        nominalFrameRate: nominalFrameRate, codec: codec, colorPrimaries: colorPrimaries,
                        transferFunction: tag, yCbCrMatrix: yCbCrMatrix, isHDR: isHDR,
                        pixelAspectRatio: pixelAspectRatio, bitsPerComponent: bitsPerComponent)
    }
}
