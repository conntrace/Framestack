import CoreGraphics
import Foundation
import FrameStackCore
import ImageIO
import UniformTypeIdentifiers

/// One still in an image sequence, described without decoding its pixels.
public struct ImageSequenceFile: Sendable, Equatable {
    public let url: URL
    /// Size after applying the file's EXIF orientation.
    public let pixelSize: PixelSize
    /// EXIF orientation (1 = up).
    public let orientation: Int
    public let hasAlpha: Bool
    public let bitsPerComponent: Int
    public let fileSizeBytes: Int64
    public let typeIdentifier: String

    public var fileName: String { url.lastPathComponent }
}

/// How stills whose size differs from the canvas (the first image's size)
/// are placed. Never silent: `strict` refuses them, the others are the
/// user's explicit choice and are reported in the Source section.
public enum CanvasPolicy: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Every image must match the canvas (default).
    case strict
    /// Scale uniformly to fit inside the canvas, centred; the rest is transparent.
    case fit
    /// Scale uniformly to cover the canvas, centred; the overflow is cropped.
    case fill

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .strict: return "Same size only"
        case .fit: return "Fit"
        case .fill: return "Fill"
        }
    }
}

/// A folder (or chosen set) of stills treated as frames on a synthetic
/// time axis: frame *i* sits at `i / framesPerSecond` **sequence seconds**.
/// These are not recorded timestamps (PRD §4.2) and the UI labels them so.
public struct ImageSequenceInfo: Sendable, Equatable {
    public static let defaultFramesPerSecond = 30.0

    /// The folder the files live in (display name, bookmark, relink).
    public let folderURL: URL
    /// Files in natural (Finder) order of their names — never reversed here.
    public let files: [ImageSequenceFile]
    /// Canvas: every file matches this (oriented) size.
    public let displaySize: PixelSize
    public let framesPerSecond: Double
    /// Play the sequence last-to-first (PRD §4.3 "reverse sequence").
    public let reversed: Bool
    /// Names in the folder that are not decodable images and were ignored.
    public let skippedFileNames: [String]
    /// How images that are not the canvas size are placed.
    public let canvasPolicy: CanvasPolicy

    public init(folderURL: URL, files: [ImageSequenceFile], displaySize: PixelSize, framesPerSecond: Double,
                reversed: Bool, skippedFileNames: [String], canvasPolicy: CanvasPolicy = .strict) {
        self.folderURL = folderURL
        self.files = files
        self.displaySize = displaySize
        self.framesPerSecond = framesPerSecond
        self.reversed = reversed
        self.skippedFileNames = skippedFileNames
        self.canvasPolicy = canvasPolicy
    }

    /// Files whose oriented size differs from the canvas.
    public var resizedFiles: [ImageSequenceFile] { files.filter { $0.pixelSize != displaySize } }

    public var fileName: String { folderURL.lastPathComponent }
    public var count: Int { files.count }

    /// Files in playback order.
    public var orderedFiles: [ImageSequenceFile] { reversed ? files.reversed() : files }

    /// Exact rational time of frame `index` (playback order).
    public static func time(ofFrame index: Int, framesPerSecond: Double) -> FrameTime {
        // 1000 ticks per frame so fractional rates (29.97, 23.976) stay exact.
        let timescale = Int32((framesPerSecond * 1000).rounded())
        return FrameTime(value: Int64(index) * 1000, timescale: max(timescale, 1))
    }

    public var timeline: FrameTimeline {
        FrameTimeline(presentationTimes: (0..<files.count).map { Self.time(ofFrame: $0, framesPerSecond: framesPerSecond) })
    }

    /// One frame interval past the last frame, so `[0, duration)` holds every frame.
    public var duration: FrameTime { Self.time(ofFrame: files.count, framesPerSecond: framesPerSecond) }

    public var totalFileSizeBytes: Int64 { files.reduce(0) { $0 + $1.fileSizeBytes } }

    /// Playback-order file for a timeline time, if it is exactly a frame time.
    public func file(at time: FrameTime) -> ImageSequenceFile? {
        guard let index = index(of: time) else { return nil }
        return orderedFiles[index]
    }

    public func index(of time: FrameTime) -> Int? {
        let timescale = Int32((framesPerSecond * 1000).rounded())
        let reference = FrameTime(value: 0, timescale: max(timescale, 1))
        // time = i * 1000 / timescale  →  i = time * timescale / 1000
        let ticks = time.value * Int64(reference.timescale)
        guard ticks % (Int64(time.timescale) * 1000) == 0 else { return nil }
        let i = Int(ticks / (Int64(time.timescale) * 1000))
        return (0..<files.count).contains(i) ? i : nil
    }

    /// "JPEG ×24" / "PNG ×10, TIFF ×2".
    public var formatSummary: String {
        var counts: [String: Int] = [:]
        for f in files {
            let name = UTType(f.typeIdentifier)?.preferredFilenameExtension?.uppercased() ?? f.typeIdentifier
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
    }

    public var bitsPerComponent: Int { files.map(\.bitsPerComponent).max() ?? 8 }
    public var hasAlpha: Bool { files.contains { $0.hasAlpha } }

    public var warnings: [String] {
        var w: [String] = []
        if !skippedFileNames.isEmpty {
            let n = skippedFileNames.count
            let shown = skippedFileNames.prefix(3).joined(separator: ", ") + (n > 3 ? ", …" : "")
            w.append(n == 1
                ? "1 file in the folder is not a readable image and was ignored (\(shown))."
                : "\(n) files in the folder are not readable images and were ignored (\(shown)).")
        }
        if hasAlpha {
            w.append("Some images have transparency: transparent pixels count as no light in the composite; PNG/TIFF exports keep the alpha channel, JPEG flattens onto black.")
        }
        let resized = resizedFiles
        if !resized.isEmpty {
            let how = canvasPolicy == .fit ? "scaled to fit inside" : "scaled to fill"
            w.append("\(resized.count) image\(resized.count == 1 ? " is" : "s are") not \(displaySize) and \(resized.count == 1 ? "is" : "are") \(how) the canvas (\(canvasPolicy == .fit ? "transparent bars where they do not reach" : "overflow cropped")). Nothing is stretched.")
        }
        return w
    }

    /// Same files, different time axis / order.
    public func with(framesPerSecond: Double? = nil, reversed: Bool? = nil) -> ImageSequenceInfo {
        ImageSequenceInfo(folderURL: folderURL, files: files, displaySize: displaySize,
                          framesPerSecond: framesPerSecond ?? self.framesPerSecond,
                          reversed: reversed ?? self.reversed, skippedFileNames: skippedFileNames, canvasPolicy: canvasPolicy)
    }

    /// Uniform scale and offset that place a `size` still on the canvas
    /// under the policy (Core Image coordinates, origin bottom-left).
    public func placement(for size: PixelSize) -> (scale: Double, offset: CGPoint) {
        guard size != displaySize, canvasPolicy != .strict else { return (1, .zero) }
        let sx = Double(displaySize.width) / Double(size.width)
        let sy = Double(displaySize.height) / Double(size.height)
        let scale = canvasPolicy == .fit ? min(sx, sy) : max(sx, sy)
        let w = Double(size.width) * scale, h = Double(size.height) * scale
        return (scale, CGPoint(x: (Double(displaySize.width) - w) / 2, y: (Double(displaySize.height) - h) / 2))
    }
}

public enum ImageSequenceLoader {
    /// Still formats FrameStack accepts (what ImageIO decodes on every Mac;
    /// RAW is a later exploration, PRD §4.2).
    public static let imageTypes: [UTType] = [.jpeg, .png, .tiff, .heic, .heif]

    public static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return imageTypes.contains { type.conforms(to: $0) }
    }

    public static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    /// Loads a sequence from a folder, from one image (its whole folder) or
    /// from an explicit set of files. Reads only image headers.
    public static func load(_ urls: [URL], framesPerSecond: Double = ImageSequenceInfo.defaultFramesPerSecond,
                            reversed: Bool = false, canvasPolicy: CanvasPolicy = .strict) async throws -> ImageSequenceInfo {
        guard let first = urls.first else { throw MediaError.noImagesFound(path: "") }
        let folder: URL
        var candidates: [URL]
        if urls.count == 1, isDirectory(first) {
            folder = first
            candidates = try contents(of: folder)
        } else if urls.count == 1 {
            folder = first.deletingLastPathComponent()
            candidates = try contents(of: folder)
        } else {
            folder = first.deletingLastPathComponent()
            candidates = urls
        }
        return try await load(folder: folder, candidates: candidates, framesPerSecond: framesPerSecond, reversed: reversed,
                              canvasPolicy: canvasPolicy)
    }

    /// Rebuilds a saved sequence: exactly these file names inside `folder`.
    public static func load(folder: URL, fileNames: [String], framesPerSecond: Double, reversed: Bool,
                            canvasPolicy: CanvasPolicy = .strict) async throws -> ImageSequenceInfo {
        try await load(folder: folder, candidates: fileNames.map { folder.appendingPathComponent($0) },
                       framesPerSecond: framesPerSecond, reversed: reversed, canvasPolicy: canvasPolicy)
    }

    static func contents(of folder: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles])
        } catch {
            throw MediaError.unreadable(path: folder.path, reason: error.localizedDescription)
        }
    }

    private static func load(folder: URL, candidates: [URL], framesPerSecond: Double, reversed: Bool,
                             canvasPolicy: CanvasPolicy) async throws -> ImageSequenceInfo {
        guard framesPerSecond > 0, framesPerSecond.isFinite else {
            throw MediaError.invalidSequenceRate(framesPerSecond)
        }
        // Canonical paths throughout (`/tmp` → `/private/tmp`), so a folder
        // listed by FileManager and one built from saved names compare equal.
        let folder = folder.resolvingSymlinksInPath()
        let sorted = candidates.map { $0.resolvingSymlinksInPath() }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var files: [ImageSequenceFile] = []
        var skipped: [String] = []
        for url in sorted {
            try Task.checkCancellation()
            if isDirectory(url) { continue }
            guard isImageFile(url), let file = describe(url) else {
                skipped.append(url.lastPathComponent)
                continue
            }
            files.append(file)
        }
        guard let canvas = files.first?.pixelSize else {
            throw MediaError.noImagesFound(path: folder.path)
        }
        let mismatched = files.filter { $0.pixelSize != canvas }
        if !mismatched.isEmpty, canvasPolicy == .strict {
            throw MediaError.mixedImageSizes(
                canvas: canvas, canvasFile: files[0].fileName,
                offenders: mismatched.prefix(5).map { "\($0.fileName) \($0.pixelSize)" }, count: mismatched.count
            )
        }
        return ImageSequenceInfo(folderURL: folder, files: files, displaySize: canvas, framesPerSecond: framesPerSecond,
                                 reversed: reversed, skippedFileNames: skipped, canvasPolicy: canvasPolicy)
    }

    /// Header-only description; nil when ImageIO cannot read the file.
    static func describe(_ url: URL) -> ImageSequenceFile? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else {
            return nil
        }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let size = rotated ? PixelSize(width: h, height: w) : PixelSize(width: w, height: h)
        let depth = (props[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
        let alpha = (props[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ImageSequenceFile(url: url, pixelSize: size, orientation: orientation, hasAlpha: alpha,
                                 bitsPerComponent: depth, fileSizeBytes: bytes, typeIdentifier: type)
    }
}

/// A video or an image sequence — everything the compositor, the timeline
/// and the document need from a source.
public enum MediaSource: Sendable, Equatable {
    case video(VideoSourceInfo)
    case imageSequence(ImageSequenceInfo)

    public var video: VideoSourceInfo? {
        if case let .video(v) = self { return v } else { return nil }
    }

    public var imageSequence: ImageSequenceInfo? {
        if case let .imageSequence(s) = self { return s } else { return nil }
    }

    public var isImageSequence: Bool { imageSequence != nil }

    /// The movie file, or the sequence's folder.
    public var url: URL {
        switch self {
        case let .video(v): return v.url
        case let .imageSequence(s): return s.folderURL
        }
    }

    public var fileName: String {
        switch self {
        case let .video(v): return v.fileName
        case let .imageSequence(s): return s.fileName
        }
    }

    public var displaySize: PixelSize {
        switch self {
        case let .video(v): return v.displaySize
        case let .imageSequence(s): return s.displaySize
        }
    }

    public var duration: FrameTime {
        switch self {
        case let .video(v): return v.duration
        case let .imageSequence(s): return s.duration
        }
    }

    public var warnings: [String] {
        switch self {
        case let .video(v): return v.warnings
        case let .imageSequence(s): return s.warnings
        }
    }

    /// "s" for recorded video time, "sequence s" for a synthetic axis.
    public var timeUnitLabel: String { isImageSequence ? "sequence s" : "s" }
}
