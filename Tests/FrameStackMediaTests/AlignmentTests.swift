import CoreGraphics
import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// M5b: Vision-based registration before blending (PRD §6.1).
///
/// The handheld fixtures show one static scene cut at known integer offsets
/// `HANDHELD_OFFSETS` (scripts/make_fixtures.py); frame 4 is the middle
/// (default reference) at (3, 1).
final class AlignmentTests: XCTestCase {
    /// (dx, dy) camera drift per frame, image coordinates with y down.
    static let offsets = [(0, 0), (6, -4), (-9, 3), (12, 8), (3, 1), (-5, -10), (8, -2), (-11, 6)]

    static var folder: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures/handheld_png_8f") }
    static var movie: URL { Bundle.module.url(forResource: "handheld_8f", withExtension: "mp4", subdirectory: "Fixtures")! }

    /// Expected transform of frame `i` onto reference `r` in Core Image
    /// coordinates (origin bottom-left): x as in the image, y flipped.
    static func expectedShift(_ i: Int, reference r: Int = 4) -> (dx: Double, dy: Double) {
        (Double(offsets[i].0 - offsets[r].0), -Double(offsets[i].1 - offsets[r].1))
    }

    private func sequence() async throws -> MediaSource {
        .imageSequence(try await ImageSequenceLoader.load([Self.folder]))
    }

    private func video() async throws -> (MediaSource, FrameTimeline) {
        let clip = try await loadFixture(.handheld)
        return (.video(clip.info), clip.timeline)
    }

    private func times(_ source: MediaSource, _ timeline: FrameTimeline? = nil) -> [FrameTime] {
        timeline?.frames ?? source.imageSequence!.timeline.frames
    }

    private func render(_ source: MediaSource, frames: [FrameTime], alignment: AlignmentSettings, mode: BlendMode = .average,
                        maxLongEdge: Int? = nil) async throws -> CompositeResult {
        try await sharedRenderer.render(CompositeRequest(source: source, frames: frames, blendMode: mode, maxLongEdge: maxLongEdge,
                                                         alignment: alignment))
    }

    private func assertTransform(_ t: AlignmentTransform?, matches i: Int, tolerance: Double, file: StaticString = #filePath, line: UInt = #line) {
        let e = Self.expectedShift(i)
        guard let t else { return XCTFail("no transform for frame \(i)", file: file, line: line) }
        switch t {
        case let .translation(dx, dy):
            XCTAssertEqual(dx, e.dx, accuracy: tolerance, "frame \(i) dx", file: file, line: line)
            XCTAssertEqual(dy, e.dy, accuracy: tolerance, "frame \(i) dy", file: file, line: line)
        case .homography:
            // Corner displacement should be a near-pure translation.
            let c = t.corners(of: CGRect(x: 0, y: 0, width: 320, height: 180))
            let shifts = zip(c, [CGPoint(x: 0, y: 0), CGPoint(x: 320, y: 0), CGPoint(x: 320, y: 180), CGPoint(x: 0, y: 180)])
                .map { (Double($0.x - $1.x), Double($0.y - $1.y)) }
            for (sx, sy) in shifts {
                XCTAssertEqual(sx, e.dx, accuracy: tolerance, "frame \(i) homography dx", file: file, line: line)
                XCTAssertEqual(sy, e.dy, accuracy: tolerance, "frame \(i) homography dy", file: file, line: line)
            }
        case .identity:
            XCTAssertEqual(0, e.dx, accuracy: tolerance, "frame \(i) identity", file: file, line: line)
            XCTAssertEqual(0, e.dy, accuracy: tolerance, "frame \(i) identity", file: file, line: line)
        }
    }

    /// Mean |Δ| of RGB between two same-size images inside `rect` (top-left origin).
    private func meanDifference(_ a: LinearImage, _ b: LinearImage, in rect: CGRect) -> Double {
        var sum = 0.0, n = 0.0
        for y in Int(rect.minY.rounded(.up))..<Int(rect.maxY.rounded(.down)) {
            for x in Int(rect.minX.rounded(.up))..<Int(rect.maxX.rounded(.down)) {
                let p = a.pixel(x: x, y: y), q = b.pixel(x: x, y: y)
                sum += Double(abs(p.x - q.x) + abs(p.y - q.y) + abs(p.z - q.z)) / 3
                n += 1
            }
        }
        return sum / max(n, 1)
    }

    // MARK: Stills (lossless)

    func testTranslationRecoversTheKnownShiftsAndSharpensTheAverage() async throws {
        let source = try await sequence()
        let frames = times(source)
        let aligned = try await render(source, frames: frames, alignment: AlignmentSettings(enabled: true))
        let report = try XCTUnwrap(aligned.alignment)
        XCTAssertEqual(report.mode, .translation)
        XCTAssertEqual(report.referenceTime, frames[4], "middle of 8 = index 4")
        XCTAssertEqual(report.alignedFrames, 7)
        XCTAssertEqual(report.failedFrames, [])
        XCTAssertEqual(report.analysisLongEdge, 320, "smaller than the 2048 analysis cap → native")
        XCTAssertFalse(report.fromCache)
        XCTAssertEqual(report.transforms.count, 8)
        for i in 0..<8 { assertTransform(report.transforms[frames[i]], matches: i, tolerance: 0.5) }
        XCTAssertEqual(report.maxShiftPixels, hypot(-14, 5), accuracy: 0.6)
        // Valid area: x from max shift 9 to 320−14, y (top-left) from 7 to 173.
        XCTAssertEqual(report.validArea.minX, 9, accuracy: 1)
        XCTAssertEqual(report.validArea.maxX, 306, accuracy: 1)
        XCTAssertEqual(report.validArea.minY, 7, accuracy: 1)      // top edge: 180 − (180 + min shift −7)
        XCTAssertEqual(report.validArea.maxY, 169, accuracy: 1)    // bottom edge: 180 − max shift 11
        XCTAssertEqual(aligned.framesComposited, 8)
        saveArtifact(aligned.image, name: "handheld_aligned_average")

        // Inside the valid area the aligned average *is* the scene: it matches the reference frame.
        let reference = try await render(source, frames: [frames[4]], alignment: .off)
        let inside = report.validArea.insetBy(dx: 2, dy: 2)
        XCTAssertLessThan(meanDifference(aligned.image, reference.image, in: inside), 0.002, "integer shifts of lossless PNGs align exactly")
        XCTAssertEqual(aligned.image.pixel(x: 100, y: 90).w, 1, accuracy: 0.001, "full coverage inside")
        XCTAssertLessThan(aligned.image.pixel(x: 2, y: 90).w, 1, "partial coverage at the left edge (shifted frames)")
        XCTAssertEqual(aligned.image.pixel(x: 2, y: 90).w, 5.0 / 8, accuracy: 0.01, "3 frames shifted right by > 2 px leave x = 2 uncovered")

        // Without alignment the same frames blur.
        let unaligned = try await render(source, frames: frames, alignment: .off)
        XCTAssertNil(unaligned.alignment)
        XCTAssertGreaterThan(meanDifference(unaligned.image, reference.image, in: inside), 0.03)
        saveArtifact(unaligned.image, name: "handheld_unaligned_average")
    }

    /// Perspective mode never does worse than the plain shift: a homography
    /// that disagrees with the shift by more than a few pixels is replaced
    /// by the shift and reported. On this block-noise fixture Vision's
    /// homographies are wild (−5 px where −12 is right), so most frames fall back.
    func testPerspectiveModeFallsBackToTheShiftWhenTheWarpIsImplausible() async throws {
        let source = try await sequence()
        let frames = times(source)
        let result = try await render(source, frames: frames, alignment: AlignmentSettings(enabled: true, mode: .perspective))
        let report = try XCTUnwrap(result.alignment)
        XCTAssertEqual(report.mode, .perspective)
        XCTAssertEqual(report.failedFrames, [])
        // Trusted warps may still be a pixel or two off on block noise (the shift is exact).
        for i in 0..<8 { assertTransform(report.transforms[frames[i]], matches: i, tolerance: 2.5) }
        XCTAssertFalse(report.fallbackFrames.isEmpty, "the guard must have rejected some warps on this content")
        XCTAssertTrue(report.summary.contains("plain shift"), report.summary)
        let reference = try await render(source, frames: [frames[4]], alignment: .off)
        // Trusted warps that are ~1–2 px off blur a little; still far sharper than unaligned (≈ 0.05+).
        XCTAssertLessThan(meanDifference(result.image, reference.image, in: report.validArea.insetBy(dx: 3, dy: 3)), 0.03)
        // The guard itself.
        let rect = CGRect(x: 0, y: 0, width: 320, height: 180)
        XCTAssertTrue(RegistrationEngine.agree(.homography([1, 0, 10.5, 0, 1, -4, 0, 0, 1]), .translation(dx: 10, dy: -4), in: rect, tolerance: 4))
        XCTAssertFalse(RegistrationEngine.agree(.homography([1, 0.05, 10, 0, 1, -4, 0, 0, 1]), .translation(dx: 10, dy: -4), in: rect, tolerance: 4))
    }

    func testReferenceChoiceAndFallback() async throws {
        let source = try await sequence()
        let frames = times(source)
        let first = try await render(source, frames: frames, alignment: AlignmentSettings(enabled: true, reference: .frame(frames[0])))
        let report = try XCTUnwrap(first.alignment)
        XCTAssertEqual(report.referenceTime, frames[0])
        // Frame 3 relative to frame 0: (12, −8) in CI coordinates.
        guard case let .translation(dx, dy)? = report.transforms[frames[3]] else { return XCTFail("expected translation") }
        XCTAssertEqual(dx, 12, accuracy: 0.5)
        XCTAssertEqual(dy, -8, accuracy: 0.5)
        XCTAssertEqual(report.transforms[frames[0]], .identity)

        // A reference that is not selected falls back to the middle.
        let subset = Array(frames[1...6])
        let fallback = try await render(source, frames: subset, alignment: AlignmentSettings(enabled: true, reference: .frame(frames[0])))
        XCTAssertEqual(fallback.alignment?.referenceTime, subset[3])
        XCTAssertEqual(AlignmentReference.frame(frames[0]).resolve(in: subset), subset[3])
        XCTAssertEqual(AlignmentReference.middle.resolve(in: []), nil)
    }

    func testPreviewAndExportShareTransformsAndTheCacheIsReused() async throws {
        let renderer = CompositeRenderer()
        let source = try await sequence()
        let frames = times(source)
        let settings = AlignmentSettings(enabled: true)
        let preview = try await renderer.render(CompositeRequest(source: source, frames: frames, blendMode: .average, maxLongEdge: 160, alignment: settings))
        let previewReport = try XCTUnwrap(preview.alignment)
        XCTAssertEqual(preview.image.size, PixelSize(width: 160, height: 90))
        XCTAssertFalse(previewReport.fromCache)
        // Transforms are in source pixels regardless of output size; the valid area scales.
        for i in 0..<8 { assertTransform(previewReport.transforms[frames[i]], matches: i, tolerance: 0.5) }
        XCTAssertEqual(previewReport.validArea.minX, 4.5, accuracy: 0.6)
        XCTAssertEqual(previewReport.validArea.width, 297 / 2, accuracy: 1)

        let export = try await renderer.render(CompositeRequest(source: source, frames: frames, blendMode: .average, maxLongEdge: nil, alignment: settings))
        let exportReport = try XCTUnwrap(export.alignment)
        XCTAssertTrue(exportReport.fromCache, "the export reuses the preview's registration")
        XCTAssertEqual(exportReport.transforms, previewReport.transforms)
        // Coverage in the preview matches the full-size coverage.
        XCTAssertEqual(preview.image.pixel(x: 1, y: 45).w, export.image.pixel(x: 2, y: 90).w, accuracy: 0.15)

        // A different reference or mode is a different cache entry; a reused
        // entry reports the same fallbacks (and failures) as the original run.
        let other = try await renderer.render(CompositeRequest(source: source, frames: frames, blendMode: .average, maxLongEdge: nil,
                                                               alignment: AlignmentSettings(enabled: true, mode: .perspective)))
        let otherReport = try XCTUnwrap(other.alignment)
        XCTAssertFalse(otherReport.fromCache)
        let again = try await renderer.render(CompositeRequest(source: source, frames: frames, blendMode: .average, maxLongEdge: 160,
                                                               alignment: AlignmentSettings(enabled: true, mode: .perspective)))
        let againReport = try XCTUnwrap(again.alignment)
        XCTAssertTrue(againReport.fromCache)
        XCTAssertEqual(againReport.fallbackFrames, otherReport.fallbackFrames)
        XCTAssertEqual(againReport.failedFrames, otherReport.failedFrames)
        XCTAssertEqual(againReport.alignedFrames, otherReport.alignedFrames)
    }

    func testSingleFrameAndDisabledSkipAlignment() async throws {
        let source = try await sequence()
        let frames = times(source)
        let one = try await render(source, frames: [frames[2]], alignment: AlignmentSettings(enabled: true))
        XCTAssertNil(one.alignment, "nothing to align a single frame to")
        XCTAssertEqual(one.image.alphaRange, 1...1)
        let off = try await render(source, frames: frames, alignment: AlignmentSettings(enabled: false))
        XCTAssertNil(off.alignment)
    }

    // MARK: Video (lossy)

    func testVideoFramesAlignWithinAPixel() async throws {
        let (source, timeline) = try await video()
        let frames = timeline.frames
        XCTAssertEqual(frames.count, 8)
        let aligned = try await render(source, frames: frames, alignment: AlignmentSettings(enabled: true))
        let report = try XCTUnwrap(aligned.alignment)
        XCTAssertEqual(report.alignedFrames, 7)
        XCTAssertEqual(report.failedFrames, [])
        for i in 0..<8 { assertTransform(report.transforms[frames[i]], matches: i, tolerance: 1.0) }
        let reference = try await render(source, frames: [frames[4]], alignment: .off)
        let inside = report.validArea.insetBy(dx: 3, dy: 3)
        let alignedDiff = meanDifference(aligned.image, reference.image, in: inside)
        let unalignedDiff = meanDifference(try await render(source, frames: frames, alignment: .off).image, reference.image, in: inside)
        XCTAssertLessThan(alignedDiff, 0.05, "compression noise only (crf 12 on block noise ≈ 0.03)")
        XCTAssertGreaterThan(unalignedDiff, alignedDiff * 3)
        saveArtifact(aligned.image, name: "handheld_video_aligned")
        // Export reads back with alpha because the shifted edges are uncovered.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackAlign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exported = try ImageExporter.writePNG(aligned.image, to: dir.appendingPathComponent("aligned.png"), bitDepth: .sixteen)
        XCTAssertTrue(exported.hasAlpha)
    }

    // MARK: Transform maths

    func testHomographyScalingAndInnerRect() {
        let t = AlignmentTransform.translation(dx: 10, dy: -4)
        XCTAssertEqual(t.scaled(by: 0.5), .translation(dx: 5, dy: -2))
        XCTAssertEqual(t.innerRect(of: CGRect(x: 0, y: 0, width: 100, height: 50)), CGRect(x: 10, y: -4, width: 100, height: 50))
        XCTAssertEqual(t.maxDisplacement(for: PixelSize(width: 100, height: 50)), hypot(10, 4), accuracy: 1e-9)

        // A pure translation written as a homography scales like one.
        let h = AlignmentTransform.homography([1, 0, 10, 0, 1, -4, 0, 0, 1])
        guard case let .homography(hs) = h.scaled(by: 2) else { return XCTFail() }
        XCTAssertEqual(hs, [1, 0, 20, 0, 1, -8, 0, 0, 1])
        XCTAssertEqual(h.corners(of: CGRect(x: 0, y: 0, width: 10, height: 10))[2], CGPoint(x: 20, y: 6))
        // A slight keystone: the inner rect is the conservative intersection.
        let k = AlignmentTransform.homography([1, 0.1, 0, 0, 1, 0, 0, 0, 1])   // x' = x + 0.1 y
        let inner = k.innerRect(of: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(inner.minX, 5, accuracy: 1e-9)   // left edge: max(0, 5)
        XCTAssertEqual(inner.maxX, 100, accuracy: 1e-9) // right edge: min(100, 105)
        XCTAssertEqual(AlignmentTransform.identity.innerRect(of: CGRect(x: 0, y: 0, width: 4, height: 4)), CGRect(x: 0, y: 0, width: 4, height: 4))

        // Plausibility: a shift that leaves less than half the frame overlapping is rejected.
        let frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        XCTAssertTrue(RegistrationEngine.plausible(.translation(dx: 150, dy: -80), in: frame))
        XCTAssertFalse(RegistrationEngine.plausible(.translation(dx: 170, dy: 0), in: frame))
        XCTAssertFalse(RegistrationEngine.plausible(.translation(dx: 0, dy: -100), in: frame))
        XCTAssertFalse(RegistrationEngine.plausible(.homography([0.2, 0, 0, 0, 0.2, 0, 0, 0, 1]), in: frame), "shrunk to a fifth")
        XCTAssertTrue(RegistrationEngine.plausible(.identity, in: frame))
    }
}
