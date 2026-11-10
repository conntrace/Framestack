import FrameStackCore
@testable import FrameStackMedia
import XCTest

final class RenderTests: XCTestCase {
    // MARK: Frame identity — the decoded frame for a timestamp is that frame.

    func testSelectedTimestampsDecodeToTheRightFrames() async throws {
        let clip = try await loadFixture(.count)
        // Includes B-frames, the first/last frame and GOP boundaries.
        for k in [0, 1, 2, 3, 29, 30, 37, 74, 75, 148, 149] {
            let result = try await render(clip, indices: [k])
            XCTAssertEqual(result.framesComposited, 1)
            XCTAssertEqual(result.image.size, PixelSize(width: 320, height: 180))
            XCTAssertEqual(decodeFrameIndex(result.image), k, "timestamp \(clip.timeline.frames[k]) decoded the wrong frame")
        }
    }

    func testExactCountOfOneRendersTheMidpointFrame() async throws {
        let clip = try await loadFixture(.count)
        let selection = try FrameSampler.select(
            from: clip.timeline,
            range: FrameTimeRange(start: .zero, end: clip.info.duration),
            mode: .exactCount(1)
        )
        let result = try await render(clip, indices: selection.selectedIndices)
        XCTAssertEqual(decodeFrameIndex(result.image), 74)
    }

    // MARK: Equal-weight average in linear light

    func testAllFramesOfFiveSecondClipAverageWithFixedReferenceValues() async throws {
        let clip = try await loadFixture(.count)
        let result = try await render(clip, indices: Array(0..<150))
        XCTAssertEqual(result.framesComposited, 150)
        XCTAssertEqual(result.missingFrames, [])
        XCTAssertTrue(result.deliveredInPresentationOrder)
        saveArtifact(result.image, name: "count_all150_average")

        // Block b is white in exactly the frames whose bit (7-b) is set, so
        // its equal-weight linear average is (#white frames)/150. These
        // reference values are independent of the renderer.
        for b in 0..<8 {
            let white = (0..<150).filter { ($0 >> (7 - b)) & 1 == 1 }.count
            let expected = Float(white) / 150
            let cx = b * 40 + 20
            let measured = result.image.mean(x: (cx - 8)..<(cx + 8), y: 10..<30)
            XCTAssertEqual(measured.x, expected, accuracy: 0.012, "block \(b)")
            XCTAssertEqual(measured.y, expected, accuracy: 0.012, "block \(b)")
            XCTAssertEqual(measured.z, expected, accuracy: 0.012, "block \(b)")
        }
        XCTAssertEqual(result.image.alphaRange, 1...1, "video composites are opaque")
    }

    func testAverageOfIdenticalContentReproducesTheFrame() async throws {
        let clip = try await loadFixture(.count)
        let single = try await render(clip, indices: [0])
        let all = try await render(clip, indices: Array(0..<150))
        // Everything below the code blocks is the same gray in every frame.
        for (x, y) in [(20, 60), (160, 100), (300, 170)] {
            let a = single.image.mean(x: (x - 4)..<(x + 4), y: (y - 4)..<(y + 4))
            let b = all.image.mean(x: (x - 4)..<(x + 4), y: (y - 4)..<(y + 4))
            XCTAssertEqual(a.x, b.x, accuracy: 0.004)
            XCTAssertEqual(a.y, b.y, accuracy: 0.004)
            XCTAssertEqual(a.z, b.z, accuracy: 0.004)
        }
    }

    func testMovingSquareIsAveragedInLinearLight() async throws {
        let clip = try await loadFixture(.movingSquare)
        XCTAssertEqual(clip.timeline.count, 24)
        let all = try await render(clip, indices: Array(0..<24))
        saveArtifact(all.image, name: "moving_square_all24_average")

        // Columns 192..<208 are covered by the square in exactly 2 of 24
        // frames → 2/24 of white in linear light.
        let trail = all.image.mean(x: 195..<205, y: 88..<104)
        XCTAssertEqual(trail.x, 1.0 / 12, accuracy: 0.01)
        // Encoded for display that is ~82/255; averaging encoded values
        // (the incorrect method) would give ~21/255.
        XCTAssertEqual(PixelEncoder.quantize(linear: trail.x, maxValue: 255), 82, accuracy: 3)

        // Background never covered stays black.
        XCTAssertLessThan(all.image.mean(x: 100..<300, y: 150..<190).x, 0.003)

        // Stationary bar: average equals any single frame.
        let single = try await render(clip, indices: [5])
        let barAll = all.image.mean(x: 100..<380, y: 210..<230)
        let barOne = single.image.mean(x: 100..<380, y: 210..<230)
        XCTAssertEqual(barAll.x, barOne.x, accuracy: 0.003)

        // Every 2nd frame: each column in 192..<208 is covered once in 12.
        let everyOther = try await render(clip, indices: Array(stride(from: 0, to: 24, by: 2)))
        XCTAssertEqual(everyOther.framesComposited, 12)
        XCTAssertEqual(everyOther.image.mean(x: 195..<205, y: 88..<104).x, 1.0 / 12, accuracy: 0.01)
    }

    func testBlackWhiteAlternationAveragesToHalfLinear() async throws {
        let clip = try await loadFixture(.blackWhite)
        let all = try await render(clip, indices: Array(0..<30))
        let center = all.image.mean(x: 60..<100, y: 30..<66)
        XCTAssertEqual(center.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(PixelEncoder.quantize(linear: center.x, maxValue: 255), 188, accuracy: 2)

        // Every 2nd frame starting with the first = only the black frames.
        let evens = try await render(clip, indices: Array(stride(from: 0, to: 30, by: 2)))
        XCTAssertLessThan(evens.image.mean(x: 60..<100, y: 30..<66).x, 0.005)
    }

    // MARK: Geometry

    func testPortraitClipIsRenderedUpright() async throws {
        let clip = try await loadFixture(.portrait)
        let result = try await render(clip, indices: Array(0..<clip.timeline.count))
        XCTAssertEqual(result.image.size, PixelSize(width: 180, height: 320))
        saveArtifact(result.image, name: "portrait_upright")

        // Encoded top-left red block must appear top-right after rotating 90° clockwise.
        let topRight = result.image.mean(x: 130..<170, y: 10..<50)
        XCTAssertGreaterThan(topRight.x, 0.6)
        XCTAssertLessThan(topRight.y, 0.1)
        XCTAssertLessThan(topRight.z, 0.1)
        let topLeft = result.image.mean(x: 10..<50, y: 10..<50)
        XCTAssertEqual(topLeft.x, topLeft.y, accuracy: 0.03, "top-left should be neutral gray")
        let bottomRight = result.image.mean(x: 130..<170, y: 270..<310)
        XCTAssertEqual(bottomRight.x, bottomRight.y, accuracy: 0.03, "bottom-right should be neutral gray")
    }

    // MARK: Preview vs export consistency

    func testReducedPreviewMatchesFullResolution() async throws {
        let clip = try await loadFixture(.movingSquare)
        let full = try await render(clip, indices: Array(0..<24))
        let preview = try await render(clip, indices: Array(0..<24), maxLongEdge: 240)
        XCTAssertEqual(preview.image.size, PixelSize(width: 240, height: 136))
        saveArtifact(preview.image, name: "moving_square_preview_240")
        // Same algorithm, different resampling: compare interior regions.
        let pairs: [((Range<Int>, Range<Int>), (Range<Int>, Range<Int>))] = [
            ((195..<205, 88..<104), (98..<102, 44..<52)),   // trail
            ((100..<380, 210..<230), (50..<190, 105..<115)), // bar
            ((100..<300, 150..<190), (50..<150, 75..<95)),   // black
        ]
        for ((fx, fy), (px, py)) in pairs {
            XCTAssertEqual(full.image.mean(x: fx, y: fy).x, preview.image.mean(x: px, y: py).x, accuracy: 0.01)
        }
    }

    // MARK: Cancellation

    func testRenderCanBeCancelledAndRendererStaysUsable() async throws {
        let clip = try await loadFixture(.count)
        let counter = Counter()
        let request = CompositeRequest(
            source: clip.info, frames: clip.timeline.frames, blendMode: .average, maxLongEdge: nil
        )
        let task = Task {
            try await sharedRenderer.render(request) { _ in
                counter.increment()
                usleep(20_000) // slow the loop down so cancellation lands mid-render
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while counter.value < 3, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("render should have been cancelled")
        } catch is CancellationError {
            // expected
        }
        XCTAssertGreaterThanOrEqual(counter.value, 3)
        XCTAssertLessThan(counter.value, 150, "cancellation must stop the render early")

        let after = try await render(clip, indices: [10])
        XCTAssertEqual(decodeFrameIndex(after.image), 10)
    }

    func testEmptySelectionIsAnError() async throws {
        let clip = try await loadFixture(.count)
        do {
            _ = try await sharedRenderer.render(CompositeRequest(source: clip.info, frames: [], blendMode: .average, maxLongEdge: nil))
            XCTFail("expected an error")
        } catch let error as MediaError {
            XCTAssertEqual(error, .noFramesSelected)
        }
    }

    // MARK: Damaged files (PRD §4.3 corrupt frames, §10.2 file read errors)

    func testCorruptFrameIsReportedMissingAndTheRestAreComposited() async throws {
        let clip = try await loadFixture(.corrupt)
        XCTAssertEqual(clip.timeline.count, 150, "the sample table still lists every frame")
        let corrupt = clip.timeline.frames[75]

        let all = try await render(clip, indices: Array(0..<150))
        saveArtifact(all.image, name: "corrupt_frame_75_average")
        XCTAssertTrue(all.missingFrames.contains(corrupt), "the damaged frame must be reported missing")
        XCTAssertEqual(all.framesComposited + all.missingFrames.count, 150, "every selected frame is either composited or reported")
        XCTAssertFalse(all.decodeFailures.isEmpty)
        XCTAssertNotNil(all.decodeFailureSummary)
        XCTAssertTrue(all.deliveredInPresentationOrder)
        // Observed on macOS 27 / Apple M4 Pro: frames 73…91 are lost — the two
        // B-frames shown before frame 75 reference it, and the decoder cannot
        // recover until the next keyframe (90) plus the reorder delay. The
        // guarantee tested here is weaker and decoder-independent: the loss is
        // confined to the damaged GOP and its neighbour (keyframes every 30
        // frames), and everything else decodes.
        XCTAssertLessThanOrEqual(all.missingFrames.count, 32, "lost more than one GOP: \(all.missingFrames)")
        for missing in all.missingFrames {
            let index = clip.timeline.frames.firstIndex(of: missing)!
            XCTAssertTrue((60..<120).contains(index), "frame \(index) outside the damaged GOP region was lost")
        }

        // Frames after the damage are the right frames (no substitution,
        // no drift), including the last one.
        for k in [100, 149] {
            let one = try await render(clip, indices: [k])
            XCTAssertEqual(one.framesComposited, 1)
            XCTAssertEqual(one.missingFrames, [])
            XCTAssertEqual(decodeFrameIndex(one.image), k)
        }
        // A selection that is entirely undecodable is an error, not an empty image.
        do {
            _ = try await render(clip, indices: [75])
            XCTFail("expected an error")
        } catch let error as MediaError {
            if case .readerFailed = error {} else if case .noFramesDecoded = error {} else {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testHealthyClipsReportNoDecodeFailures() async throws {
        let clip = try await loadFixture(.count)
        let result = try await render(clip, indices: Array(0..<150))
        XCTAssertEqual(result.decodeFailures, [])
        XCTAssertNil(result.decodeFailureSummary)
    }

    func testTimestampsNotInTheStreamAreReportedMissing() async throws {
        let clip = try await loadFixture(.count)
        let bogus = FrameTime(value: 1, timescale: 7) // between real frames
        let request = CompositeRequest(
            source: clip.info, frames: [clip.timeline.frames[0], bogus], blendMode: .average, maxLongEdge: 64
        )
        let result = try await sharedRenderer.render(request)
        XCTAssertEqual(result.framesComposited, 1)
        XCTAssertEqual(result.missingFrames, [bogus])
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
