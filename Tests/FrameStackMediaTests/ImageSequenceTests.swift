import CoreGraphics
import FrameStackCore
@testable import FrameStackMedia
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// M5a: folders of stills as frames on a synthetic ("sequence") time axis.
final class ImageSequenceTests: XCTestCase {
    static var folder: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/sequence_png_12f")
    }

    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackSeq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func renderSequence(_ sequence: ImageSequenceInfo, indices: [Int], mode: BlendMode = .average,
                                maxLongEdge: Int? = nil) async throws -> CompositeResult {
        let timeline = sequence.timeline
        let request = CompositeRequest(source: .imageSequence(sequence), frames: indices.map { timeline.frames[$0] },
                                       blendMode: mode, maxLongEdge: maxLongEdge)
        return try await sharedRenderer.render(request)
    }

    // MARK: Import

    func testFolderImportsInNaturalOrderAndSkipsNonImages() async throws {
        let seq = try await ImageSequenceLoader.load([Self.folder])
        XCTAssertEqual(seq.count, 12)
        XCTAssertEqual(seq.files.map(\.fileName), (0..<12).map { "frame_\($0).png" }, "frame_10 after frame_9, not after frame_1")
        XCTAssertEqual(seq.skippedFileNames, ["notes.txt"])
        XCTAssertEqual(seq.displaySize, PixelSize(width: 160, height: 90))
        XCTAssertEqual(seq.framesPerSecond, 30)
        XCTAssertFalse(seq.reversed)
        XCTAssertEqual(seq.fileName, "sequence_png_12f")
        XCTAssertEqual(seq.formatSummary, "PNG ×12")
        XCTAssertEqual(seq.bitsPerComponent, 8)
        XCTAssertFalse(seq.hasAlpha)
        XCTAssertEqual(seq.warnings.count, 1)
        XCTAssertTrue(seq.warnings[0].contains("notes.txt"), seq.warnings[0])

        // Sequence time: frame i at i/30 s, exact; duration one frame past the last.
        let timeline = seq.timeline
        XCTAssertEqual(timeline.count, 12)
        XCTAssertEqual(timeline.frames[0], .zero)
        XCTAssertEqual(timeline.frames[1], FrameTime(value: 1, timescale: 30))
        XCTAssertEqual(timeline.frames[11], FrameTime(value: 11, timescale: 30))
        XCTAssertEqual(seq.duration, FrameTime(value: 12, timescale: 30))
        XCTAssertEqual(seq.file(at: timeline.frames[7])?.fileName, "frame_7.png")
        XCTAssertNil(seq.file(at: FrameTime(seconds: 0.05)), "not a frame time (1.5 frames)")
        XCTAssertEqual(seq.file(at: FrameTime(seconds: 0.1))?.fileName, "frame_3.png", "0.1 s is exactly frame 3 at 30 fps")
        XCTAssertEqual(seq.index(of: FrameTime(value: 2, timescale: 60)), 1, "equal times in another timescale")
    }

    func testOneImageStandsForItsFolderAndExplicitFilesStayExplicit() async throws {
        let one = try await ImageSequenceLoader.load([Self.folder.appendingPathComponent("frame_3.png")])
        XCTAssertEqual(one.count, 12)
        let subset = try await ImageSequenceLoader.load([5, 2, 9].map { Self.folder.appendingPathComponent("frame_\($0).png") })
        XCTAssertEqual(subset.files.map(\.fileName), ["frame_2.png", "frame_5.png", "frame_9.png"], "sorted, not in pick order")
        XCTAssertEqual(subset.duration, FrameTime(value: 3, timescale: 30))
    }

    func testFractionalRateAndReverse() async throws {
        let seq = try await ImageSequenceLoader.load([Self.folder], framesPerSecond: 29.97, reversed: true)
        XCTAssertEqual(seq.orderedFiles.first?.fileName, "frame_11.png")
        XCTAssertEqual(seq.orderedFiles.last?.fileName, "frame_0.png")
        XCTAssertEqual(seq.files.first?.fileName, "frame_0.png", "`files` keeps natural order")
        XCTAssertEqual(seq.timeline.frames[1], FrameTime(value: 1000, timescale: 29970))
        XCTAssertEqual(seq.timeline.frames[3].seconds, 3 / 29.97, accuracy: 1e-9)
        XCTAssertEqual(seq.file(at: seq.timeline.frames[0])?.fileName, "frame_11.png", "frame 0 of the reversed sequence")
        let retimed = seq.with(framesPerSecond: 2, reversed: false)
        XCTAssertEqual(retimed.duration.seconds, 6, accuracy: 1e-9)
        XCTAssertEqual(retimed.files, seq.files)
        await XCTAssertThrowsErrorAsync(try await ImageSequenceLoader.load([Self.folder], framesPerSecond: 0)) { error in
            guard case .invalidSequenceRate? = error as? MediaError else { return XCTFail("\(error)") }
        }
    }

    func testEmptyAndMixedSizeFoldersAreRefusedWithReasons() async throws {
        let empty = scratch.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: empty.appendingPathComponent("readme.txt"))
        await XCTAssertThrowsErrorAsync(try await ImageSequenceLoader.load([empty])) { error in
            XCTAssertEqual(error as? MediaError, .noImagesFound(path: empty.path))
            XCTAssertTrue(error.localizedDescription.contains("contains no readable"), error.localizedDescription)
        }

        let mixed = scratch.appendingPathComponent("mixed")
        try FileManager.default.createDirectory(at: mixed, withIntermediateDirectories: true)
        for i in 0..<3 {
            try FileManager.default.copyItem(at: Self.folder.appendingPathComponent("frame_\(i).png"), to: mixed.appendingPathComponent("a_\(i).png"))
        }
        try writePNG(width: 80, height: 45, to: mixed.appendingPathComponent("a_3.png"))
        await XCTAssertThrowsErrorAsync(try await ImageSequenceLoader.load([mixed])) { error in
            guard case let .mixedImageSizes(canvas, canvasFile, offenders, count)? = error as? MediaError else { return XCTFail("\(error)") }
            XCTAssertEqual(canvas, PixelSize(width: 160, height: 90))
            XCTAssertEqual(canvasFile, "a_0.png")
            XCTAssertEqual(offenders, ["a_3.png 80×45"])
            XCTAssertEqual(count, 1)
            XCTAssertTrue(error.localizedDescription.contains("does not stretch"), error.localizedDescription)
        }
    }

    func testTruncatedImageIsSkippedAtImport() async throws {
        let folder = scratch.appendingPathComponent("damaged")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<4 {
            try FileManager.default.copyItem(at: Self.folder.appendingPathComponent("frame_\(i).png"), to: folder.appendingPathComponent("f_\(i).png"))
        }
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 0]).write(to: folder.appendingPathComponent("f_2.png"), options: .atomic)
        let seq = try await ImageSequenceLoader.load([folder])
        XCTAssertEqual(seq.files.map(\.fileName), ["f_0.png", "f_1.png", "f_3.png"])
        XCTAssertEqual(seq.skippedFileNames, ["f_2.png"])
    }

    // MARK: Decoding and compositing

    func testEveryFrameDecodesToItself() async throws {
        let seq = try await ImageSequenceLoader.load([Self.folder])
        for i in [0, 1, 5, 9, 10, 11] {
            let single = try await renderSequence(seq, indices: [i])
            XCTAssertEqual(single.image.size, PixelSize(width: 160, height: 90))
            XCTAssertEqual(decodeFrameIndex(single.image, blockWidth: 20), i, "frame \(i)")
            XCTAssertEqual(single.missingFrames, [])
        }
        let reversed = seq.with(reversed: true)
        let first = try await renderSequence(reversed, indices: [0])
        XCTAssertEqual(decodeFrameIndex(first.image, blockWidth: 20), 11, "reversed: frame 0 is the last image")
    }

    func testAverageOfAllTwelveMatchesReferenceValuesInLinearLight() async throws {
        let seq = try await ImageSequenceLoader.load([Self.folder])
        let result = try await renderSequence(seq, indices: Array(0..<12))
        XCTAssertEqual(result.framesComposited, 12)
        XCTAssertEqual(result.missingFrames, [])
        XCTAssertTrue(result.deliveredInPresentationOrder)
        XCTAssertEqual(result.decodeFailures, [])
        saveArtifact(result.image, name: "sequence_all12_average")
        // Block b is white in the frames whose bit (7-b) is set: for 0…11
        // bit 3 → 8,9,10,11 (4/12); bit 2 → 4…7 (4/12); bit 1 → 2,3,6,7,10,11 (6/12); bit 0 → 6/12.
        let expected: [Double] = [0, 0, 0, 0, 4.0 / 12, 4.0 / 12, 6.0 / 12, 6.0 / 12]
        for b in 0..<8 {
            let v = Double(result.image.mean(x: (b * 20 + 4)..<(b * 20 + 16), y: 8..<32).x)
            XCTAssertEqual(v, expected[b], accuracy: 0.01, "block \(b)")
        }
        // Gray bar sRGB 128 → linear 0.2158 in every frame.
        XCTAssertEqual(Double(result.image.mean(x: 10..<150, y: 64..<76).x), SRGBTransfer.decode(128.0 / 255), accuracy: 0.01)
        XCTAssertEqual(result.image.alphaRange, 1...1, "opaque PNGs stay opaque")

        // Same math at half size.
        let half = try await renderSequence(seq, indices: Array(0..<12), maxLongEdge: 80)
        XCTAssertEqual(half.image.size, PixelSize(width: 80, height: 45))
        XCTAssertEqual(Double(half.image.mean(x: 5..<75, y: 32..<38).x), SRGBTransfer.decode(128.0 / 255), accuracy: 0.01)
    }

    func testNormalBlendTakesTheLastSelectedImage() async throws {
        let seq = try await ImageSequenceLoader.load([Self.folder])
        let result = try await renderSequence(seq, indices: [2, 5, 7], mode: .normal)
        XCTAssertEqual(decodeFrameIndex(result.image, blockWidth: 20), 7)
    }

    func testUndecodableFileIsReportedMissingNotSubstituted() async throws {
        // Passes the header check (valid PNG header + IHDR) but has no pixel data.
        let folder = scratch.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<3 {
            try FileManager.default.copyItem(at: Self.folder.appendingPathComponent("frame_\(i).png"), to: folder.appendingPathComponent("f_\(i).png"))
        }
        let good = try Data(contentsOf: folder.appendingPathComponent("f_1.png"))
        try good.prefix(60).write(to: folder.appendingPathComponent("f_1.png"), options: .atomic)
        let seq = try await ImageSequenceLoader.load([folder])
        guard seq.count == 3 else {
            // ImageIO rejected the truncated header outright: that is the import-time skip, already tested.
            XCTAssertEqual(seq.skippedFileNames, ["f_1.png"])
            return
        }
        let result = try await renderSequence(seq, indices: [0, 1, 2])
        XCTAssertEqual(result.framesComposited, 2)
        XCTAssertEqual(result.missingFrames, [seq.timeline.frames[1]])
        XCTAssertEqual(result.decodeFailures.count, 1)
        XCTAssertTrue(result.decodeFailureSummary?.contains("f_1.png") ?? false, result.decodeFailureSummary ?? "nil")
    }

    func testEXIFOrientationIsApplied() async throws {
        // A 160×90 image tagged "rotate 90° CW to display" must come out 90×160 upright.
        let folder = scratch.appendingPathComponent("rotated")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = CGImageSourceCreateWithURL(Self.folder.appendingPathComponent("frame_1.png") as CFURL, nil)!
        let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        for i in 0..<2 {
            let url = folder.appendingPathComponent("r_\(i).jpg")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            // A homogeneous [CFString: Int] literal; a mixed-type literal made ImageIO drop the tag.
            let properties: [CFString: Int] = [kCGImagePropertyOrientation: 6]
            CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        let seq = try await ImageSequenceLoader.load([folder])
        XCTAssertEqual(seq.displaySize, PixelSize(width: 90, height: 160))
        XCTAssertEqual(seq.files[0].orientation, 6)
        XCTAssertEqual(seq.formatSummary, "JPEG ×2")
        let result = try await renderSequence(seq, indices: [0, 1])
        XCTAssertEqual(result.image.size, PixelSize(width: 90, height: 160))
        // Frame 1's single white block (bit 0 → block 7, x 140…160, y 0…40) rotates 90° CW to
        // the top-right corner: x 50…90, y 140…160.
        XCTAssertGreaterThan(result.image.mean(x: 55..<85, y: 142..<158).x, 0.9)
        // The gray bar (old rows 60–80) becomes the column band x 10…30; x 35…50 is black.
        XCTAssertLessThan(result.image.mean(x: 35..<50, y: 142..<158).x, 0.1)
        XCTAssertEqual(Double(result.image.mean(x: 12..<28, y: 20..<140).x), SRGBTransfer.decode(128.0 / 255), accuracy: 0.03)
        // Thumbnails and the exact frame come out upright too.
        let frame = try await SourceFrames.frame(for: .imageSequence(seq), at: seq.timeline.frames[0], maxLongEdge: 80)
        XCTAssertEqual(frame.width, 45)
        XCTAssertEqual(frame.height, 80)
        saveArtifact(result.image, name: "sequence_exif_rotated")
    }

    func testAlphaIsCompositedAndExportedHonestly() async throws {
        let folder = scratch.appendingPathComponent("alpha")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Two 20×10 PNGs: left half opaque mid-gray, right half fully transparent.
        for i in 0..<2 { try writePNG(width: 20, height: 10, alphaRight: true, to: folder.appendingPathComponent("a_\(i).png")) }
        let seq = try await ImageSequenceLoader.load([folder])
        XCTAssertTrue(seq.hasAlpha)
        XCTAssertTrue(seq.warnings.contains { $0.contains("transparency") })
        let result = try await renderSequence(seq, indices: [0, 1])
        XCTAssertEqual(result.image.pixel(x: 2, y: 5).w, 1, accuracy: 0.01)
        XCTAssertEqual(result.image.pixel(x: 17, y: 5).w, 0, accuracy: 0.01)
        XCTAssertTrue(ImageExporter.hasTransparency(result.image))

        let png = scratch.appendingPathComponent("alpha.png")
        let report = try ImageExporter.write(result.image, to: png, settings: ExportSettings(format: .png, bitDepth: .eight))
        XCTAssertTrue(report.hasAlpha)
        XCTAssertFalse(report.alphaFlattened)
        let rgba = try readRGBA8(png)
        XCTAssertEqual(rgba[(5 * 20 + 2) * 4 + 3], 255)
        XCTAssertEqual(rgba[(5 * 20 + 17) * 4 + 3], 0)
        XCTAssertEqual(Int(rgba[(5 * 20 + 2) * 4]), 128, accuracy: 1, "straight colour of the opaque half")

        let jpeg = scratch.appendingPathComponent("alpha.jpg")
        let flat = try ImageExporter.write(result.image, to: jpeg, settings: ExportSettings(format: .jpeg))
        XCTAssertFalse(flat.hasAlpha)
        XCTAssertTrue(flat.alphaFlattened)
        let read = try readBackPixels(jpeg, bitDepth: .eight)
        XCTAssertEqual(read.rgb[(5 * 20 + 17) * 3] * 255, 0, accuracy: 3, "transparent half flattened onto black")
    }

    func testWideGamutStillsAreColorManaged() async throws {
        // A Display P3–tagged JPEG of pure P3 red (1, 0, 0): in sRGB that is
        // out of gamut, so an sRGB export must clip while a P3 export keeps it.
        let folder = scratch.appendingPathComponent("p3")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let w = 32, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for p in 0..<(w * h) { pixels[p * 4] = 255; pixels[p * 4 + 3] = 255 }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        for i in 0..<2 {
            let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent("p3_\(i).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        let seq = try await ImageSequenceLoader.load([folder])
        let result = try await renderSequence(seq, indices: [0, 1])
        let linear = result.image.pixel(x: 10, y: 8)
        // P3 red in linear sRGB coordinates: red > 1, green negative (P3→sRGB inverse matrix).
        let expected = ColorPrimaries.apply(ColorPrimaries.displayP3ToSRGB, to: [1, 0, 0])
        XCTAssertEqual(Double(linear.x), expected[0], accuracy: 0.02)
        XCTAssertEqual(Double(linear.y), expected[1], accuracy: 0.02)
        XCTAssertGreaterThan(linear.x, 1.1)
        XCTAssertLessThan(linear.y, -0.03)

        let p3 = PixelEncoder.encode8(result.image, colorSpace: .displayP3)
        XCTAssertEqual(Array(p3[0..<3]), [255, 0, 0], "round trip to P3 coordinates")
        let srgb = PixelEncoder.encode8(result.image, colorSpace: .sRGB)
        XCTAssertEqual(Array(srgb[0..<3]), [255, 0, 0], "clipped per channel in sRGB (no gamut mapping)")
    }

    // MARK: Thumbnails

    func testThumbnailsAreDistinctAscendingAndSmall() async throws {
        let seq = try await ImageSequenceLoader.load([Self.folder])
        let thumbs = try await SourceFrames.thumbnails(for: .imageSequence(seq), timeline: seq.timeline, count: 6, maxHeight: 44)
        XCTAssertEqual(thumbs.count, 6)
        XCTAssertEqual(thumbs.map(\.time), [1, 3, 5, 7, 9, 11].map { FrameTime(value: Int64($0), timescale: 30) })
        XCTAssertLessThanOrEqual(thumbs[0].image.height, 88)
    }

    // MARK: Project references

    func testSequenceProjectReferenceRoundTripsAndDetectsChanges() async throws {
        let folder = scratch.appendingPathComponent("shoot")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<5 {
            try FileManager.default.copyItem(at: Self.folder.appendingPathComponent("frame_\(i).png"), to: folder.appendingPathComponent("IMG_\(i).png"))
        }
        let seq = try await ImageSequenceLoader.load([folder], framesPerSecond: 12, reversed: true)
        let identity = SourceIdentity.compute(forSequence: seq)
        XCTAssertTrue(identity.fingerprint.hasPrefix("sha256-list:"))
        XCTAssertEqual(identity.fileName, "shoot")
        let projectURL = scratch.appendingPathComponent("shoot.framestack")
        let reference = SourceReference.make(source: .imageSequence(seq), identity: identity, frameCount: 5, projectURL: projectURL)
        XCTAssertEqual(reference.kind, .imageSequence)
        XCTAssertEqual(reference.sequence, SequenceReference(fileNames: (0..<5).map { "IMG_\($0).png" }, framesPerSecond: 12, reversed: true))
        XCTAssertEqual(reference.relativePath, "shoot")
        let settings = CompositeSettings(rangeStart: .zero, rangeEnd: seq.duration, samplingKind: .all, nth: 1, exactCount: 1, blendMode: .average, opacity: 1)
        let project = ProjectFile(source: reference, settings: settings, export: ExportSettings())
        try project.write(to: projectURL)
        let read = try ProjectFile.read(from: projectURL)
        XCTAssertEqual(read.formatVersion, 2)
        XCTAssertEqual(read, project)
        guard case let .found(location) = SourceLocator.resolve(read.source, projectURL: projectURL) else { return XCTFail("expected found") }
        XCTAssertEqual(location.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)

        // Rebuilding from the saved names gives the same sequence.
        let rebuilt = try await ImageSequenceLoader.load(folder: folder, fileNames: read.source.sequence!.fileNames,
                                                         framesPerSecond: 12, reversed: true)
        XCTAssertEqual(rebuilt, seq)

        // A missing still → changed, with the count; a file instead of a folder → changed.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("IMG_3.png"))
        guard case let .changed(_, differences) = SourceLocator.resolve(read.source, projectURL: projectURL) else { return XCTFail("expected changed") }
        XCTAssertEqual(differences.first, "1 of 5 images missing")
        guard case .changed = SourceLocator.check(Self.folder.appendingPathComponent("frame_0.png"), against: read.source) else {
            return XCTFail("a file is not a folder of images")
        }
        try FileManager.default.removeItem(at: folder)
        XCTAssertEqual(SourceLocator.resolve(read.source, projectURL: projectURL), .missing)

        // Format-1 documents (videos) still read, defaulting to kind video.
        let v1 = scratch.appendingPathComponent("old.framestack")
        var text = try String(contentsOf: projectURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"formatVersion\" : 2", with: "\"formatVersion\" : 1")
        text = text.replacingOccurrences(of: "\"kind\" : \"imageSequence\",", with: "")
        try text.write(to: v1, atomically: true, encoding: .utf8)
        let old = try ProjectFile.read(from: v1)
        XCTAssertEqual(old.source.kind, .video)
        XCTAssertNotNil(old.source.sequence, "unknown-to-v1 keys are simply carried")
    }

    // MARK: Helpers

    private func writePNG(width: Int, height: Int, alphaRight: Bool = false, to url: URL) throws {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let transparent = alphaRight && x >= width / 2
                pixels[i] = transparent ? 0 : 128
                pixels[i + 1] = transparent ? 0 : 128
                pixels[i + 2] = transparent ? 0 : 128
                pixels[i + 3] = transparent ? 0 : 255
            }
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// Straight RGBA bytes of an 8-bit file.
    private func readRGBA8(_ url: URL) throws -> [UInt8] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        try buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw MediaError.exportVerificationFailed("no context")
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Un-premultiply.
        for p in 0..<(w * h) {
            let a = Int(buffer[p * 4 + 3])
            if a > 0, a < 255 {
                for c in 0..<3 { buffer[p * 4 + c] = UInt8(min(255, Int(buffer[p * 4 + c]) * 255 / a)) }
            }
        }
        return buffer
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line,
                                  _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
