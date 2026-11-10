import CoreGraphics
import CoreImage
import FrameStackCore
@testable import FrameStackMedia
import UniformTypeIdentifiers
import XCTest

/// M6k: camera RAW stills through Apple's default rendering (D-035), on
/// synthetic linear DNGs written at test time.
final class RawStillTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackRaw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A folder of DNGs; skips the test when this macOS will not decode the synthetic file.
    private func makeFolder(_ name: String, width: Int = 256, height: Int = 192, orientation: Int = 1,
                            gains: [Double]) async throws -> ImageSequenceInfo {
        let folder = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, gain) in gains.enumerated() {
            try SyntheticDNG.write(to: folder.appendingPathComponent("raw_\(i).dng"), width: width, height: height,
                                   orientation: orientation, pixel: SyntheticDNG.patches(width: width, height: height, gain: gain))
        }
        guard let seq = try? await ImageSequenceLoader.load([folder]), seq.count == gains.count else {
            throw XCTSkip("This macOS does not decode the synthetic linear DNG")
        }
        return seq
    }

    private func render(_ seq: ImageSequenceInfo, indices: [Int], mode: BlendMode = .average,
                        maxLongEdge: Int? = nil) async throws -> CompositeResult {
        let timeline = seq.timeline
        return try await sharedRenderer.render(CompositeRequest(source: .imageSequence(seq), frames: indices.map { timeline.frames[$0] },
                                                               blendMode: mode, maxLongEdge: maxLongEdge))
    }

    /// Linear extended-sRGB RGBA floats of a Core Image picture.
    private func floats(_ image: CIImage) -> [Float] {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var out = [Float](repeating: 0, count: w * h * 4)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        out.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 16, bounds: image.extent, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        return out
    }

    /// Opt-in run on the owner's own RAW files, read in place and never copied:
    ///
    ///     FRAMESTACK_REAL_RAW_FOLDER="/path/to/folder" FRAMESTACK_REAL_RAW_COUNT=8 swift test --filter RawStillTests
    ///
    /// Prints import time, preview and full-size render times and the memory
    /// footprint; only hard failures fail the test.
    func testOwnerRAWFolder() async throws {
        guard let path = ProcessInfo.processInfo.environment["FRAMESTACK_REAL_RAW_FOLDER"], !path.isEmpty else {
            throw XCTSkip("Set FRAMESTACK_REAL_RAW_FOLDER=/path to run on real RAW files.")
        }
        let limit = ProcessInfo.processInfo.environment["FRAMESTACK_REAL_RAW_COUNT"].flatMap(Int.init) ?? 8
        func log(_ s: String) { FileHandle.standardError.write(Data("REALRAW  \(s)\n".utf8)) }
        let folder = URL(fileURLWithPath: path)
        // Never open an iCloud placeholder: reading one downloads it. Only
        // files whose data is already on this disk are used (SF_DATALESS).
        func isLocal(_ name: String) -> Bool {
            var info = stat()
            guard lstat(folder.appendingPathComponent(name).path, &info) == 0 else { return false }
            return info.st_flags & 0x4000_0000 == 0
        }
        let listed = try FileManager.default.contentsOfDirectory(atPath: path)
            .filter { ["arw", "dng", "cr2", "cr3", "nef", "raf", "orf", "rw2"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let names = listed.filter(isLocal).prefix(limit)
        log("\(listed.count) RAW files listed, \(listed.count - listed.filter(isLocal).count) are iCloud placeholders and were not opened")
        guard !names.isEmpty else { throw XCTSkip("No RAW file in that folder is stored on this disk.") }
        var t = Date()
        let seq = try await ImageSequenceLoader.load(folder: folder, fileNames: Array(names), framesPerSecond: 30, reversed: false)
        log("\(seq.count) files, \(seq.formatSummary), \(seq.displaySize), \(seq.bitsPerComponent)-bit, headers read in \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
        XCTAssertEqual(seq.rawFileCount, seq.count)
        let all = Array(0..<seq.count)
        let baseline = MemoryFootprint.current()

        t = Date()
        let thumbs = try await SourceFrames.thumbnails(for: .imageSequence(seq), timeline: seq.timeline, count: min(32, seq.count), maxHeight: 44)
        log("filmstrip: \(thumbs.count) thumbnails in \(String(format: "%.2f", Date().timeIntervalSince(t))) s")

        t = Date()
        let preview = try await render(seq, indices: all, maxLongEdge: 1600)
        let previewSeconds = Date().timeIntervalSince(t)
        log("1600 px Average of \(seq.count): \(String(format: "%.2f", previewSeconds)) s (\(String(format: "%.0f", previewSeconds / Double(seq.count) * 1000)) ms per frame), failures \(preview.decodeFailures.count), footprint +\((MemoryFootprint.current() - baseline) / 1_048_576) MB")
        XCTAssertEqual(preview.framesComposited, seq.count)

        // One frame at preview size against ImageIO's own rendering of the same file.
        let single = try await render(seq, indices: [0], maxLongEdge: 1600).image
        let reference = try await SourceFrames.frame(for: .imageSequence(seq), at: seq.timeline.frames[0], maxLongEdge: 1600)
        var ref = [UInt8](repeating: 0, count: reference.width * reference.height * 4)
        ref.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: reference.width, height: reference.height, bitsPerComponent: 8,
                                bytesPerRow: reference.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(reference, in: CGRect(x: 0, y: 0, width: reference.width, height: reference.height))
        }
        var sum = SIMD3<Double>(repeating: 0), refSum = SIMD3<Double>(repeating: 0)
        for i in 0..<(single.width * single.height) {
            for c in 0..<3 { sum[c] += SRGBTransfer.encode(Double(min(max(single.pixels[i * 4 + c], 0), 1))) }
        }
        for i in 0..<(reference.width * reference.height) { for c in 0..<3 { refSum[c] += Double(ref[i * 4 + c]) / 255 } }
        let mean = sum / Double(single.width * single.height), refMean = refSum / Double(reference.width * reference.height)
        log(String(format: "frame 0 mean sRGB: compositor %.4f %.4f %.4f, ImageIO %.4f %.4f %.4f", mean.x, mean.y, mean.z, refMean.x, refMean.y, refMean.z))

        t = Date()
        let two = Array(all.prefix(2))
        let native = try await render(seq, indices: two)
        let nativeSeconds = Date().timeIntervalSince(t)
        log("full-size Average of \(two.count) (\(native.image.size)): \(String(format: "%.2f", nativeSeconds)) s, peak footprint +\((MemoryFootprint.peak() - baseline) / 1_048_576) MB")
        XCTAssertEqual(native.image.size, seq.displaySize)
    }

    func testFolderOfDNGsImportsAsRAW() async throws {
        let seq = try await makeFolder("import", gains: [1, 1.5])
        XCTAssertEqual(seq.displaySize, PixelSize(width: 256, height: 192))
        XCTAssertEqual(seq.files.map(\.fileName), ["raw_0.dng", "raw_1.dng"])
        XCTAssertTrue(seq.files.allSatisfy(\.isRAW))
        XCTAssertEqual(seq.files[0].typeIdentifier, "com.adobe.raw-image")
        XCTAssertEqual(seq.bitsPerComponent, 16)
        XCTAssertEqual(seq.formatSummary, "DNG ×2")
        XCTAssertEqual(seq.rawFileCount, 2)
        XCTAssertEqual(seq.warnings.count, 1)
        XCTAssertTrue(seq.warnings[0].contains("camera RAW") && seq.warnings[0].contains("default rendering"), seq.warnings[0])
        XCTAssertTrue(ImageSequenceLoader.isImageFile(URL(fileURLWithPath: "/x/DSC0001.ARW")))
        XCTAssertTrue(ImageSequenceLoader.isImageFile(URL(fileURLWithPath: "/x/IMG_1.CR3")))
        XCTAssertTrue(ImageSequenceLoader.isImageFile(URL(fileURLWithPath: "/x/a.nef")))
        XCTAssertFalse(ImageSequenceLoader.isImageFile(URL(fileURLWithPath: "/x/a.xmp")), "sidecars are not images")
    }

    func testRAWThatMacOSCannotReadIsSkippedAndListed() async throws {
        let seq = try await makeFolder("unreadable", gains: [1, 1])
        // A .dng that is not a DNG, and a JPEG-less sidecar: both ignored, the .dng named.
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: seq.folderURL.appendingPathComponent("broken.dng"))
        let again = try await ImageSequenceLoader.load([seq.folderURL])
        XCTAssertEqual(again.count, 2)
        XCTAssertEqual(again.skippedFileNames, ["broken.dng"])
        XCTAssertTrue(again.warnings.contains { $0.contains("broken.dng") }, "\(again.warnings)")
    }

    func testDefaultRenderingIsNeutralMonotonicAndKeepsHues() async throws {
        let seq = try await makeFolder("rendering", gains: [1, 2])
        let dark = try await render(seq, indices: [0]).image
        let bright = try await render(seq, indices: [1]).image
        XCTAssertEqual(dark.size, PixelSize(width: 256, height: 192))
        XCTAssertEqual(dark.alphaRange, 1...1)
        // 18 % grey: neutral stays neutral; Apple's default tone curve lifts
        // it (measured 0.379 linear on macOS 27), so only a loose range is asserted.
        let grey = dark.mean(x: 20..<108, y: 20..<172)
        XCTAssertEqual(grey.x, grey.y, accuracy: 0.004)
        XCTAssertEqual(grey.y, grey.z, accuracy: 0.004)
        XCTAssertGreaterThan(grey.y, 0.15)
        XCTAssertLessThan(grey.y, 0.6)
        // Twice the light renders brighter.
        XCTAssertGreaterThan(bright.mean(x: 20..<108, y: 20..<172).y, grey.y + 0.1)
        // Red, green and blue bands keep their dominant channel.
        let red = dark.mean(x: 148..<236, y: 10..<54), green = dark.mean(x: 148..<236, y: 74..<118)
        let blue = dark.mean(x: 148..<236, y: 138..<182)
        XCTAssertGreaterThan(red.x, 3 * max(red.y, red.z))
        XCTAssertGreaterThan(green.y, 3 * max(green.x, green.z))
        XCTAssertGreaterThan(blue.z, 3 * max(blue.x, blue.y))
        // The compositor's frame is the same picture `CIImage(contentsOf:)`
        // (ImageIO's and Preview's rendering) gives — the CIRAWFilter path changes nothing.
        let viaFilter = try XCTUnwrap(RawStill.image(url: seq.files[0].url))
        let viaImageIO = try XCTUnwrap(CIImage(contentsOf: seq.files[0].url))
        let a = floats(viaFilter), b = floats(viaImageIO)
        XCTAssertEqual(a.count, b.count)
        XCTAssertLessThan(zip(a, b).map { abs($0 - $1) }.max() ?? 1, 0.002)
        saveArtifact(dark, name: "raw_default_rendering")
    }

    func testAverageOfRAWFramesIsTheMeanOfTheDevelopedFrames() async throws {
        let seq = try await makeFolder("average", gains: [1, 2, 0.5])
        let singles = try await [0, 1, 2].asyncMap { try await self.render(seq, indices: [$0]).image }
        let result = try await render(seq, indices: [0, 1, 2])
        XCTAssertEqual(result.framesComposited, 3)
        XCTAssertTrue(result.decodeFailures.isEmpty)
        var worst: Float = 0
        for i in result.image.pixels.indices {
            let expected = (singles[0].pixels[i] + singles[1].pixels[i] + singles[2].pixels[i]) / 3
            worst = max(worst, abs(result.image.pixels[i] - expected))
        }
        XCTAssertLessThan(worst, 1e-4, "true equal-weight mean of the three developed frames")
        // Lighten picks the brightest frame everywhere.
        let lighten = try await render(seq, indices: [0, 1, 2], mode: .lighten).image
        var worstLighten: Float = 0
        for i in lighten.pixels.indices { worstLighten = max(worstLighten, abs(lighten.pixels[i] - singles[1].pixels[i])) }
        XCTAssertLessThan(worstLighten, 1e-4)
    }

    func testOrientationTagRotatesTheRAWOnce() async throws {
        // Stored 256×192 tagged "rotate 90° clockwise to display": the canvas is
        // 192×256, the stored left (grey) half is on top, and the stored
        // top-to-bottom red/green/blue bands run right to left below it.
        let seq = try await makeFolder("rotated", orientation: 6, gains: [1, 1])
        XCTAssertEqual(seq.displaySize, PixelSize(width: 192, height: 256))
        XCTAssertEqual(seq.files[0].orientation, 6)
        XCTAssertEqual(seq.files[0].storedSize, PixelSize(width: 256, height: 192))
        let image = try await render(seq, indices: [0, 1]).image
        XCTAssertEqual(image.size, PixelSize(width: 192, height: 256))
        let grey = image.mean(x: 20..<172, y: 20..<108)
        XCTAssertEqual(grey.x, grey.z, accuracy: 0.004)
        let left = image.mean(x: 10..<54, y: 148..<236), middle = image.mean(x: 74..<118, y: 148..<236)
        let right = image.mean(x: 138..<182, y: 148..<236)
        XCTAssertGreaterThan(left.z, 3 * max(left.x, left.y), "blue band on the left")
        XCTAssertGreaterThan(middle.y, 3 * max(middle.x, middle.z), "green band in the middle")
        XCTAssertGreaterThan(right.x, 3 * max(right.y, right.z), "red band on the right")
        // The frame view and the filmstrip are upright too.
        let frame = try await SourceFrames.frame(for: .imageSequence(seq), at: seq.timeline.frames[0], maxLongEdge: 128)
        XCTAssertEqual(frame.width, 96)
        XCTAssertEqual(frame.height, 128)
        let thumbs = try await SourceFrames.thumbnails(for: .imageSequence(seq), timeline: seq.timeline, count: 2, maxHeight: 44)
        XCTAssertEqual(thumbs.count, 2)
        XCTAssertGreaterThan(thumbs[0].image.height, thumbs[0].image.width)
    }

    func testReducedDecodeKeepsGeometryAndColour() async throws {
        XCTAssertEqual(RawStill.decodeScale(forOutputRatio: 1), 1)
        XCTAssertEqual(RawStill.decodeScale(forOutputRatio: 0.51), 1)
        XCTAssertEqual(RawStill.decodeScale(forOutputRatio: 0.5), 0.5)
        XCTAssertEqual(RawStill.decodeScale(forOutputRatio: 0.3), 0.5)
        XCTAssertEqual(RawStill.decodeScale(forOutputRatio: 0.25), 0.25)
        XCTAssertEqual(RawStill.decodeScale(forOutputRatio: 0.2), 0.25)
        XCTAssertEqual(RawStill.decodeScale(forOutputRatio: 0.01), 0.125)

        let seq = try await makeFolder("reduced", width: 1024, height: 768, gains: [1, 2])
        let file = seq.files[0]
        // Full size at scale 1; a quarter of it (give or take a pixel) at 0.25.
        let full = try XCTUnwrap(RawStill.image(url: file.url))
        let quarter = try XCTUnwrap(RawStill.image(url: file.url, decodeScale: 0.25))
        XCTAssertEqual(full.extent, CGRect(x: 0, y: 0, width: 1024, height: 768))
        XCTAssertEqual(quarter.extent.origin, .zero)
        XCTAssertEqual(quarter.extent.width, 256, accuracy: 1)
        XCTAssertEqual(quarter.extent.height, 192, accuracy: 1)
        // A 256 px preview (decoded at 0.25) shows what the full render shows:
        // patch interiors agree, and the boundaries are where they were.
        let preview = try await render(seq, indices: [0, 1], maxLongEdge: 256).image
        let native = try await render(seq, indices: [0, 1]).image
        XCTAssertEqual(preview.size, PixelSize(width: 256, height: 192))
        for (px, py) in [(64, 96), (192, 32), (192, 96), (192, 160)] {
            let a = preview.mean(x: (px - 20)..<(px + 20), y: (py - 12)..<(py + 12))
            let b = native.mean(x: (px - 20) * 4..<(px + 20) * 4, y: (py - 12) * 4..<(py + 12) * 4)
            for (u, v) in [(a.x, b.x), (a.y, b.y), (a.z, b.z)] { XCTAssertEqual(u, v, accuracy: 0.01, "patch at \(px),\(py)") }
        }
        // The grey/colour edge sits at x = 128 of 256: grey two pixels left of it, colour two pixels right.
        let leftOfEdge = preview.mean(x: 122..<126, y: 80..<112), rightOfEdge = preview.mean(x: 130..<134, y: 80..<112)
        XCTAssertEqual(leftOfEdge.x, leftOfEdge.y, accuracy: 0.03)
        XCTAssertGreaterThan(rightOfEdge.y, 2 * rightOfEdge.x)
    }

    func testRAWAndJPEGPairIsReported() async throws {
        let seq = try await makeFolder("pairs", gains: [1, 1])
        XCTAssertEqual(seq.rawPairCount, 0)
        // The camera's JPEG of the first shot, next to its RAW.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 256, height: 192, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 192))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(seq.folderURL.appendingPathComponent("RAW_0.JPG") as CFURL,
                                                                 UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let again = try await ImageSequenceLoader.load([seq.folderURL])
        XCTAssertEqual(again.count, 3)
        XCTAssertEqual(again.rawFileCount, 2)
        XCTAssertEqual(again.rawPairCount, 1)
        XCTAssertTrue(again.warnings.contains { $0.contains("1 shot is in the folder twice") }, "\(again.warnings)")
    }

    /// The reduced decode stands for the whole frame on the two paths that
    /// work in source pixels: alignment, and Fit placement of a smaller file.
    func testReducedDecodeWithAlignmentAndMixedSizes() async throws {
        let seq = try await makeFolder("reduced-align", width: 1024, height: 768, gains: [1, 2])
        let timeline = seq.timeline
        let plain = try await render(seq, indices: [0, 1], maxLongEdge: 256).image
        let aligned = try await sharedRenderer.render(CompositeRequest(
            source: .imageSequence(seq), frames: timeline.frames, blendMode: .average, maxLongEdge: 256,
            alignment: AlignmentSettings(enabled: true)))
        XCTAssertEqual(aligned.framesComposited, 2)
        XCTAssertEqual(aligned.image.size, plain.size)
        // The two frames differ only in brightness: registration finds no
        // movement, and the picture is the unaligned one.
        for (px, py) in [(64, 96), (192, 32), (192, 96), (192, 160)] {
            let a = aligned.image.mean(x: (px - 20)..<(px + 20), y: (py - 12)..<(py + 12))
            let b = plain.mean(x: (px - 20)..<(px + 20), y: (py - 12)..<(py + 12))
            for (u, v) in [(a.x, b.x), (a.y, b.y), (a.z, b.z)] { XCTAssertEqual(u, v, accuracy: 0.02, "aligned patch at \(px),\(py)") }
        }

        // A half-size RAW among full-size ones, fitted onto the canvas.
        try SyntheticDNG.write(to: seq.folderURL.appendingPathComponent("raw_2.dng"), width: 512, height: 384,
                               pixel: SyntheticDNG.patches(width: 512, height: 384, gain: 1))
        let mixed = try await ImageSequenceLoader.load([seq.folderURL], canvasPolicy: .fit)
        XCTAssertEqual(mixed.count, 3)
        XCTAssertEqual(mixed.displaySize, PixelSize(width: 1024, height: 768))
        let small = mixed.timeline.frames[2]
        let preview = try await sharedRenderer.render(CompositeRequest(source: .imageSequence(mixed), frames: [small],
                                                                       blendMode: .average, maxLongEdge: 256)).image
        let native = try await sharedRenderer.render(CompositeRequest(source: .imageSequence(mixed), frames: [small],
                                                                      blendMode: .average, maxLongEdge: nil)).image
        XCTAssertEqual(preview.size, PixelSize(width: 256, height: 192))
        for (px, py) in [(64, 96), (192, 32), (192, 96), (192, 160)] {
            let a = preview.mean(x: (px - 20)..<(px + 20), y: (py - 12)..<(py + 12))
            let b = native.mean(x: (px - 20) * 4..<(px + 20) * 4, y: (py - 12) * 4..<(py + 12) * 4)
            for (u, v) in [(a.x, b.x), (a.y, b.y), (a.z, b.z)] { XCTAssertEqual(u, v, accuracy: 0.01, "fitted patch at \(px),\(py)") }
        }
        // It fills the canvas (same shape), so nothing is left transparent.
        XCTAssertEqual(preview.alphaRange.lowerBound, 1, accuracy: 0.01)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
