import Darwin
import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// Opt-in timing run for the M6 exit review: the expensive M6 features on
/// one long clip, each as a fresh render at preview and at full size.
///
///     FRAMESTACK_PERF_CLIP=/path/clip.mp4 FRAMESTACK_PERF_FRAMES=1200 FRAMESTACK_PERF_FULL_FRAMES=300 \
///         swift test -c release -Xswiftc -enable-testing --filter PerformanceProbe
///
/// `FRAMESTACK_PERF_FULL_FRAMES` bounds the full-size half (a full-size
/// Median decodes the selection once per band, so its cost grows with the
/// square of the frame count).
/// Numbers are printed, not asserted (they depend on the clip and the Mac).
final class PerformanceProbe: XCTestCase {
    func testAdvancedFeatureTimings() async throws {
        guard let path = ProcessInfo.processInfo.environment["FRAMESTACK_PERF_CLIP"], !path.isEmpty else {
            throw XCTSkip("Set FRAMESTACK_PERF_CLIP=/path/clip.mp4 to run the M6 timing table.")
        }
        func log(_ s: String) { FileHandle.standardError.write(Data("PERF  \(s)\n".utf8)) }
        let info = try await VideoSourceLoader.load(url: URL(fileURLWithPath: path))
        let scan = try await FrameScanner.scan(info)
        let limit = ProcessInfo.processInfo.environment["FRAMESTACK_PERF_FRAMES"].flatMap(Int.init) ?? scan.timeline.count
        let allFrames = Array(scan.timeline.frames.prefix(limit))
        let fullLimit = ProcessInfo.processInfo.environment["FRAMESTACK_PERF_FULL_FRAMES"].flatMap(Int.init) ?? allFrames.count
        log("\(info.fileName) \(info.displaySize) \(info.codec) · \(scan.timeline.count) frames scanned in \(String(format: "%.2f", scan.elapsedSeconds)) s · using \(allFrames.count) (full size: \(min(fullLimit, allFrames.count)))")

        let stroke = MaskStroke(points: [.init(x: 0.2, y: 0.5), .init(x: 0.8, y: 0.5)], radius: 0.1, softness: 0.5, erase: false)
        let cases: [(String, BlendMode, AlignmentSettings, WeightCurve, MotionMaskSettings, PaintedMaskSettings, Bool)] = [
            ("Average", .average, .off, .flat, .off, .off, false),
            ("Lighten", .lighten, .off, .flat, .off, .off, false),
            ("Average, Late weighting", .average, .off, WeightCurve(preset: .late), .off, .off, false),
            ("Max Luminance", .maxLuminance, .off, .flat, .off, .off, false),
            ("Median", .median, .off, .flat, .off, .off, false),
            ("Normal + motion mask (median background)", .normal, .off, .flat, MotionMaskSettings(enabled: true), .off, false),
            ("Lighten + painted mask", .lighten, .off, .flat, .off, PaintedMaskSettings(enabled: true, strokes: [stroke]), false),
            ("Normal, reverse stacking order", .normal, .off, .flat, .off, .off, true),
            ("Average + alignment (shift)", .average, AlignmentSettings(enabled: true), .flat, .off, .off, false),
        ]
        for size in [1080, nil] as [Int?] {
            let frames = size == nil ? Array(allFrames.prefix(fullLimit)) : allFrames
            for (name, mode, alignment, weighting, motion, painted, reverse) in cases {
                let before = MemoryFootprint.current()
                let result = try await sharedRenderer.render(CompositeRequest(
                    source: info, frames: frames, blendMode: mode, maxLongEdge: size, alignment: alignment,
                    weighting: weighting, motionMask: motion, paintedMask: painted, reverseOrder: reverse))
                var notes: [String] = []
                if let m = result.median { notes.append("\(m.passes) pass\(m.passes == 1 ? "" : "es")") }
                if let r = result.reverseDecode { notes.append("\(r.chunks) chunk\(r.chunks == 1 ? "" : "s")") }
                if let m = result.motionMask { notes.append(m.summary) }
                if !result.missingFrames.isEmpty { notes.append("\(result.missingFrames.count) missing") }
                // Frames the registration guard rejects are left out on purpose (D-023) and are
                // neither composited nor missing: they are counted in the alignment report.
                let rejected = result.alignment?.failedFrames.count ?? 0
                if let a = result.alignment { notes.append(a.summary) }
                let delta = MemoryFootprint.current() - before
                log(String(format: "%@ | %@ | %d of %d frames | %.2f s | %.0f fps decoded | footprint %@%@ (process peak %@) | %@",
                           size.map { "\($0) px" } ?? "full \(result.image.size)", name, result.framesComposited, frames.count,
                           result.elapsedSeconds, Double(frames.count) / result.elapsedSeconds,
                           delta < 0 ? "-" : "+", MemoryFootprint.format(abs(delta)), MemoryFootprint.format(MemoryFootprint.peak()),
                           notes.joined(separator: "; ")))
                XCTAssertEqual(result.framesComposited + result.missingFrames.count + rejected, frames.count)
            }
        }
    }
}
