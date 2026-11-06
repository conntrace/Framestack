import CoreGraphics
import Foundation
import FrameStackCore
@testable import FrameStackMedia
import ImageIO
import XCTest

enum Fixture: String {
    /// 150 frames, 320×180, B-frames; frame index as 8 binary blocks on top.
    case count = "count_5s_30fps"
    /// 24 frames, 480×272; white 32×32 square moving 16 px/frame; gray bar.
    case movingSquare = "moving_square_24f"
    /// 30 frames, 160×96; even frames black, odd frames white.
    case blackWhite = "black_white_30f"
    /// 10 frames encoded 320×180 with a 90° clockwise display matrix.
    case portrait = "portrait_rot90cw"
    /// Stream-copied cut of `count`: stores frames 30…106, edit list
    /// presents frames 45…106 (62 frames) starting at t = 0.
    case trimmed = "trimmed_editlist"
    /// The count clip with the NAL length of frame 75 (pts 2.5 s) overwritten
    /// with 0xFFFFFFFF, so the decoder fails on that sample.
    case corrupt = "corrupt_frame_75"
    /// 10 frames, 320×180, HEVC Main10 (lossless): a horizontal luma ramp
    /// from 10-bit code 64 to 940, one code step every ~0.37 px.
    case tenBit = "tenbit_ramp_10f"

    var url: URL {
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: "mp4", subdirectory: "Fixtures") else {
            fatalError("Missing fixture \(rawValue).mp4 — run scripts/make_fixtures.py")
        }
        return url
    }
}

struct LoadedFixture {
    let info: VideoSourceInfo
    let timeline: FrameTimeline
}

func loadFixture(_ fixture: Fixture) async throws -> LoadedFixture {
    let info = try await VideoSourceLoader.load(url: fixture.url)
    let scan = try await FrameScanner.scan(info)
    return LoadedFixture(info: info, timeline: scan.timeline)
}

/// Software rendering can be forced for headless CI machines without a GPU.
let sharedRenderer = CompositeRenderer(
    useSoftwareRenderer: ProcessInfo.processInfo.environment["FRAMESTACK_SOFTWARE_RENDER"] == "1"
)

func render(
    _ fixture: LoadedFixture,
    indices: [Int],
    mode: BlendMode = .average,
    opacity: Float = 1,
    maxLongEdge: Int? = nil
) async throws -> CompositeResult {
    let request = CompositeRequest(
        source: fixture.info,
        frames: indices.map { fixture.timeline.frames[$0] },
        blendMode: mode,
        opacity: opacity,
        maxLongEdge: maxLongEdge
    )
    return try await sharedRenderer.render(request)
}

/// Directory for rendered images that CI uploads for visual inspection.
/// Set FRAMESTACK_ARTIFACTS_DIR to enable.
func saveArtifact(_ image: LinearImage, name: String) {
    guard let dir = ProcessInfo.processInfo.environment["FRAMESTACK_ARTIFACTS_DIR"] else { return }
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try? ImageExporter.writePNG(image, to: url, bitDepth: .eight)
}

/// Reads back a PNG's pixels by drawing into a context with a known layout
/// (sRGB, RGBA, 8 or 16 bits). Returns RGB samples (alpha dropped),
/// normalized to 0…1.
func readBackPixels(_ url: URL, bitDepth: ExportBitDepth) throws -> (width: Int, height: Int, rgb: [Double], cgImage: CGImage) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw MediaError.exportVerificationFailed("cannot decode \(url.lastPathComponent)")
    }
    let w = image.width
    let h = image.height
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    var rgb: [Double] = []
    rgb.reserveCapacity(w * h * 3)
    switch bitDepth {
    case .eight:
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        try buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw MediaError.exportVerificationFailed("no 8-bit context")
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        for p in 0..<(w * h) {
            for c in 0..<3 { rgb.append(Double(buffer[p * 4 + c]) / 255) }
        }
    case .sixteen:
        var buffer = [UInt16](repeating: 0, count: w * h * 4)
        try buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else {
                throw MediaError.exportVerificationFailed("no 16-bit context")
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        for p in 0..<(w * h) {
            for c in 0..<3 { rgb.append(Double(UInt16(littleEndian: buffer[p * 4 + c])) / 65_535) }
        }
    }
    return (w, h, rgb, image)
}

/// Decodes the 8-bit frame index written into the count fixture's top row.
/// Block b (from the left, 40 px wide) is white when bit (7 - b) is set.
func decodeFrameIndex(_ image: LinearImage, blockWidth: Int = 40) -> Int {
    var value = 0
    for b in 0..<8 {
        let cx = b * blockWidth + blockWidth / 2
        let luminance = image.mean(x: (cx - 6)..<(cx + 6), y: 14..<26).x
        if luminance > 0.5 { value |= 1 << (7 - b) }
    }
    return value
}
