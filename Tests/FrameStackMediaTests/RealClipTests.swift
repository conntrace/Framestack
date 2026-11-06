import AVFoundation
import CoreGraphics
import Darwin
import FrameStackCore
@testable import FrameStackMedia
import XCTest

/// Opt-in acceptance run on the owner's own footage (PRD §11.2).
///
///     FRAMESTACK_REAL_CLIPS="/path/a.mov:/path/b.mp4" \
///     FRAMESTACK_ARTIFACTS_DIR=/tmp/framestack-renders swift test --filter RealClipTests
///
/// For every clip it imports, scans, renders a 1080 px preview and a
/// full-resolution Average of every frame, exports a 16-bit PNG, and prints
/// frame counts, timings, process memory footprint, missing-frame warnings
/// and a color cross-check of a single frame against AVAssetImageGenerator
/// (the same decode + display-transform path QuickTime Player uses). The
/// numbers are printed, not asserted, because they depend on the footage;
/// only hard failures (errors, dimension mismatches) fail the test.
final class RealClipTests: XCTestCase {
    func testOwnerClips() async throws {
        guard let list = ProcessInfo.processInfo.environment["FRAMESTACK_REAL_CLIPS"], !list.isEmpty else {
            throw XCTSkip("Set FRAMESTACK_REAL_CLIPS=path1:path2 to run on real footage.")
        }
        let artifacts = ProcessInfo.processInfo.environment["FRAMESTACK_ARTIFACTS_DIR"].map { URL(fileURLWithPath: $0) }
        var report: [String] = []
        func log(_ s: String) {
            // stderr is unbuffered, so lines survive a crash mid-run.
            FileHandle.standardError.write(Data("REALCLIP  \(s)\n".utf8))
            report.append(s)
        }

        for path in list.split(separator: ":").map(String.init) {
            let url = URL(fileURLWithPath: path)
            log("=== \(url.lastPathComponent)")
            let baseline = MemoryFootprint.current()

            // Import
            let t0 = Date()
            let info = try await VideoSourceLoader.load(url: url)
            log(String(format: "import %.2f s · %@ encoded %@ display %@ · %@ · %.3f s · nominal %@ fps · est. %@ frames · HDR %@ · PAR %@",
                       Date().timeIntervalSince(t0), info.codec, info.encodedSize.description, info.displaySize.description,
                       info.orientation.displayName, info.duration.seconds,
                       info.nominalFrameRate.map { String(format: "%.3f", $0) } ?? "unknown",
                       info.estimatedFrameCount.map(String.init) ?? "unknown",
                       info.isHDR ? "yes" : "no", info.pixelAspectRatio.map { String(format: "%.3f", $0) } ?? "square"))
            log("color: \(info.colorDescription)")
            for w in info.warnings { log("warning: \(w)") }

            // Scan
            let scan = try await FrameScanner.scan(info)
            log(String(format: "scan %.2f s · %d frames (%@)%@ · %d outside edits · %d non-displayed · %d duplicate timestamps",
                       scan.elapsedSeconds, scan.timeline.count, scan.method.rawValue,
                       scan.fallbackReason.map { " fallback: \($0)" } ?? "",
                       scan.samplesOutsideEdits, scan.nonDisplayedSamplesSkipped, scan.timeline.duplicateTimestampsDropped))
            if let first = scan.timeline.frames.first, let last = scan.timeline.frames.last, scan.timeline.count > 1 {
                let deltas = zip(scan.timeline.frames.dropFirst(), scan.timeline.frames).map { $0.seconds - $1.seconds }
                log(String(format: "timestamps %@ … %@ · frame interval min %.5f s max %.5f s (%@)",
                           first.description, last.description, deltas.min()!, deltas.max()!,
                           deltas.max()! - deltas.min()! > 1e-4 ? "variable" : "constant"))
            }
            let all = scan.timeline.frames

            // Preview (1080 px long edge)
            let preview = try await sharedRenderer.render(CompositeRequest(source: info, frames: all, blendMode: .average, maxLongEdge: 1080))
            log(String(format: "preview 1080 · %@ · %d/%d frames · %.2f s (%.1f fps) · missing %d · in order %@ · footprint now %@ (peak %@)",
                       preview.image.size.description, preview.framesComposited, all.count, preview.elapsedSeconds,
                       Double(preview.framesComposited) / preview.elapsedSeconds, preview.missingFrames.count,
                       preview.deliveredInPresentationOrder ? "yes" : "NO",
                       MemoryFootprint.format(MemoryFootprint.current() - baseline), MemoryFootprint.format(MemoryFootprint.peak() - baseline)))
            XCTAssertEqual(preview.image.size.longEdge, min(1080, info.displaySize.longEdge))

            // Full-resolution render + 16-bit export
            let full = try await sharedRenderer.render(CompositeRequest(source: info, frames: all, blendMode: .average, maxLongEdge: nil))
            XCTAssertEqual(full.image.size, info.displaySize)
            log(String(format: "full %@ · %d/%d frames · %.2f s (%.1f fps) · missing %d · footprint now %@ (peak %@)",
                       full.image.size.description, full.framesComposited, all.count, full.elapsedSeconds,
                       Double(full.framesComposited) / full.elapsedSeconds, full.missingFrames.count,
                       MemoryFootprint.format(MemoryFootprint.current() - baseline), MemoryFootprint.format(MemoryFootprint.peak() - baseline)))
            if !full.missingFrames.isEmpty {
                log("MISSING frames: \(full.missingFrames.prefix(10).map(\.description).joined(separator: ", "))")
                log("decode failure: \(full.decodeFailureSummary ?? "none")")
            }
            if let artifacts {
                let base = (url.lastPathComponent as NSString).deletingPathExtension
                let out = artifacts.appendingPathComponent("\(base) Average \(full.framesComposited)f.png")
                let t1 = Date()
                let exported = try ImageExporter.writePNG(full.image, to: out, bitDepth: .sixteen)
                log(String(format: "export 16-bit %.2f s · %dx%d %d-bit %@ · %@ · %@",
                           Date().timeIntervalSince(t1), exported.width, exported.height, exported.bitDepth,
                           exported.colorProfileName ?? "untagged", MemoryFootprint.format(exported.fileSizeBytes), out.path))
            }

            // Color cross-check: one frame through FrameStack (N = 1 Average
            // reproduces the frame) vs AVAssetImageGenerator, both as 8-bit sRGB.
            let mid = all[all.count / 2]
            let single: CompositeResult
            let reference: (width: Int, height: Int, rgb: [UInt8], cgImage: CGImage)
            do {
                single = try await sharedRenderer.render(CompositeRequest(source: info, frames: [mid], blendMode: .average, maxLongEdge: nil))
                reference = try await referenceFrame(url: url, at: mid.cmTime)
            } catch {
                log("color check skipped: frame \(mid) could not be decoded (\(error.localizedDescription))")
                continue
            }
            let ours = PixelEncoder.encodeSRGB8(single.image)
            if reference.width == single.image.width, reference.height == single.image.height {
                var sumAbs = 0, maxAbs = 0, n = 0
                let w = single.image.width
                for y in stride(from: 8, to: single.image.height - 8, by: 23) {
                    for x in stride(from: 8, to: w - 8, by: 29) {
                        for c in 0..<3 {
                            let d = abs(Int(ours[(y * w + x) * 3 + c]) - Int(reference.rgb[(y * w + x) * 3 + c]))
                            sumAbs += d
                            maxAbs = max(maxAbs, d)
                            n += 1
                        }
                    }
                }
                log(String(format: "color check frame %@ vs AVAssetImageGenerator: mean |Δ| %.2f/255, max |Δ| %d/255 over %d samples",
                           mid.description, Double(sumAbs) / Double(n), maxAbs, n))
                if let artifacts {
                    let base = (url.lastPathComponent as NSString).deletingPathExtension
                    try ImageExporter.writePNG(single.image, to: artifacts.appendingPathComponent("\(base) frame.png"), bitDepth: .eight)
                    try writeReferencePNG(reference.cgImage, to: artifacts.appendingPathComponent("\(base) frame reference.png"))
                }
            } else {
                log("color check skipped: reference \(reference.width)×\(reference.height) vs ours \(single.image.size)")
            }
        }
        if let artifacts {
            try report.joined(separator: "\n").write(to: artifacts.appendingPathComponent("real-clips-report.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Decodes one frame with AVAssetImageGenerator (display transform
    /// applied, exact time) and returns it as 8-bit sRGB samples.
    private func referenceFrame(url: URL, at time: CMTime) async throws -> (width: Int, height: Int, rgb: [UInt8], cgImage: CGImage) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, actual) = try await generator.image(at: time)
        XCTAssertEqual(CMTimeCompare(actual, time), 0, "generator returned a different time")
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
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for p in 0..<(w * h) {
            rgb[p * 3] = buffer[p * 4]
            rgb[p * 3 + 1] = buffer[p * 4 + 1]
            rgb[p * 3 + 2] = buffer[p * 4 + 2]
        }
        return (w, h, rgb, image)
    }

    private func writeReferencePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

/// Process physical memory footprint (what Activity Monitor's "Memory" column shows).
enum MemoryFootprint {
    private static func info() -> rusage_info_v4 {
        // The kernel may write a newer, larger rusage_info flavor than the
        // one requested; give it a generous buffer and read the V4 prefix.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
        // The C signature is `rusage_info_t *` (void **), but the kernel
        // writes the struct at the pointer itself, so pass the buffer cast.
        _ = proc_pid_rusage(getpid(), RUSAGE_INFO_V4, buffer.assumingMemoryBound(to: rusage_info_t?.self))
        return buffer.load(as: rusage_info_v4.self)
    }

    static func current() -> Int64 { Int64(info().ri_phys_footprint) }
    static func peak() -> Int64 { Int64(info().ri_lifetime_max_phys_footprint) }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
