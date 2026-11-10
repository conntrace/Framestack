import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// Opt-in: prints the per-frame alignment shifts Vision finds on real footage.
///     FRAMESTACK_ALIGN_CLIP=/path/clip.mov FRAMESTACK_ALIGN_FRAMES=60 swift test --filter RealClipAlignmentProbe
final class RealClipAlignmentProbe: XCTestCase {
    func testPrintShifts() async throws {
        guard let path = ProcessInfo.processInfo.environment["FRAMESTACK_ALIGN_CLIP"] else {
            throw XCTSkip("Set FRAMESTACK_ALIGN_CLIP to run.")
        }
        let count = Int(ProcessInfo.processInfo.environment["FRAMESTACK_ALIGN_FRAMES"] ?? "60") ?? 60
        let info = try await VideoSourceLoader.load(url: URL(fileURLWithPath: path))
        let scan = try await FrameScanner.scan(info)
        let frames = Array(scan.timeline.frames.prefix(count))
        for mode in [AlignmentMode.translation] {
            let t0 = Date()
            let result = try await sharedRenderer.render(CompositeRequest(source: .video(info), frames: frames, blendMode: .average,
                                                                           maxLongEdge: 1080, alignment: AlignmentSettings(enabled: true, mode: mode)))
            let report = try XCTUnwrap(result.alignment)
            var line = "ALIGNPROBE \(mode) \(frames.count) frames in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s: \(report.summary); fromCache \(report.fromCache)\n"
            for t in frames {
                let d = report.transforms[t].map { $0.maxDisplacement(for: info.displaySize) } ?? -1
                if case let .translation(dx, dy)? = report.transforms[t] {
                    line += String(format: "  %.3f s: (%.1f, %.1f) |%.1f|\n", t.seconds, dx, dy, d)
                } else {
                    line += String(format: "  %.3f s: %@ |%.1f|\n", t.seconds, String(describing: report.transforms[t]), d)
                }
            }
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
