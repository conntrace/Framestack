import CryptoKit
import Foundation
import FrameStackCore

public enum ProjectError: Error, LocalizedError, Equatable {
    case unreadable(path: String, reason: String)
    case corrupt(path: String, reason: String)
    /// Written by a newer FrameStack whose format this build does not know.
    case newerFormat(path: String, version: Int)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(path, reason):
            return "The project “\((path as NSString).lastPathComponent)” could not be read. \(reason)"
        case let .corrupt(path, reason):
            return "The project “\((path as NSString).lastPathComponent)” is not a valid FrameStack project. \(reason)"
        case let .newerFormat(path, version):
            return "The project “\((path as NSString).lastPathComponent)” was saved by a newer version of FrameStack (format \(version); this version reads format \(ProjectFile.currentFormatVersion)). Update FrameStack to open it."
        }
    }
}

/// A practical fingerprint of a media file: its size plus a SHA-256 of the
/// first and last mebibyte. Hashing whole multi-gigabyte clips would make
/// every save and open slow; edits that keep the size *and* both ends
/// unchanged are not detected (documented in DECISIONS.md D-019).
public struct SourceIdentity: Sendable, Codable, Equatable {
    public static let sampleBytes = 1 << 20

    public var fileName: String
    public var fileSizeBytes: Int64
    public var modificationDate: Date?
    /// "sha256:<hex>" over size ‖ head ‖ tail.
    public var fingerprint: String

    public init(fileName: String, fileSizeBytes: Int64, modificationDate: Date?, fingerprint: String) {
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
        self.modificationDate = modificationDate
        self.fingerprint = fingerprint
    }

    /// Identity of an image sequence: the folder name, the total size, the
    /// folder's modification date and a SHA-256 over every file's name and
    /// size in order. Reading each image's bytes is deliberately avoided
    /// (a sequence may be thousands of stills).
    public static func compute(forSequence sequence: ImageSequenceInfo) -> SourceIdentity {
        var hasher = SHA256()
        for file in sequence.files {
            hasher.update(data: Data("\(file.fileName)\t\(file.fileSizeBytes)\n".utf8))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let modified = (try? sequence.folderURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        return SourceIdentity(fileName: sequence.fileName, fileSizeBytes: sequence.totalFileSizeBytes,
                              modificationDate: modified, fingerprint: "sha256-list:\(digest)")
    }

    public static func compute(for url: URL) throws -> SourceIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        // Whole seconds: the JSON encoding (ISO 8601) has no fractional part.
        let modified = (attributes[.modificationDate] as? Date).map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        let head = try handle.read(upToCount: sampleBytes) ?? Data()
        hasher.update(data: head)
        if size > Int64(sampleBytes) {
            try handle.seek(toOffset: UInt64(max(0, size - Int64(sampleBytes))))
            let tail = try handle.read(upToCount: sampleBytes) ?? Data()
            hasher.update(data: tail)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return SourceIdentity(fileName: url.lastPathComponent, fileSizeBytes: size, modificationDate: modified,
                              fingerprint: "sha256:\(digest)")
    }

    /// Human-readable differences that mean "this is not the same media".
    /// A rename alone is not a difference; a different modification date
    /// with identical content is not either.
    public func differences(from saved: SourceIdentity) -> [String] {
        var out: [String] = []
        if fileSizeBytes != saved.fileSizeBytes {
            out.append("size \(saved.fileSizeBytes) → \(fileSizeBytes) bytes")
        }
        if fingerprint != saved.fingerprint {
            out.append("contents differ (fingerprint)")
        }
        return out
    }
}

/// How an image sequence is rebuilt from its folder.
public struct SequenceReference: Sendable, Codable, Equatable {
    /// File names in natural order (the saved selection, not the whole folder).
    public var fileNames: [String]
    public var framesPerSecond: Double
    public var reversed: Bool
    /// Absent in documents written before Fit/Fill existed = strict.
    public var canvasPolicy: CanvasPolicy

    public init(fileNames: [String], framesPerSecond: Double, reversed: Bool, canvasPolicy: CanvasPolicy = .strict) {
        self.fileNames = fileNames
        self.framesPerSecond = framesPerSecond
        self.reversed = reversed
        self.canvasPolicy = canvasPolicy
    }

    public init(_ sequence: ImageSequenceInfo) {
        self.init(fileNames: sequence.files.map(\.fileName), framesPerSecond: sequence.framesPerSecond, reversed: sequence.reversed,
                  canvasPolicy: sequence.canvasPolicy)
    }

    private enum CodingKeys: String, CodingKey { case fileNames, framesPerSecond, reversed, canvasPolicy }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileNames = try c.decode([String].self, forKey: .fileNames)
        framesPerSecond = try c.decode(Double.self, forKey: .framesPerSecond)
        reversed = try c.decode(Bool.self, forKey: .reversed)
        canvasPolicy = try c.decodeIfPresent(CanvasPolicy.self, forKey: .canvasPolicy) ?? .strict
    }
}

public enum SourceKind: String, Sendable, Codable {
    case video
    case imageSequence
}

/// Where a project's media lives, with enough redundancy to find it again
/// after a move, a rename or a copy of the whole folder.
public struct SourceReference: Sendable, Codable, Equatable {
    /// Video file or image-sequence folder (format 2; absent in format 1 = video).
    public var kind: SourceKind
    /// Present for image sequences.
    public var sequence: SequenceReference?
    /// Alias-style bookmark (follows moves and renames on the same volume).
    public var bookmark: Data?
    public var absolutePath: String
    /// Path relative to the project file's folder, when both are on the same volume.
    public var relativePath: String?
    public var identity: SourceIdentity
    public var duration: FrameTime
    public var displaySize: PixelSize
    /// Scanned frame count when the project was saved.
    public var frameCount: Int

    public init(kind: SourceKind = .video, sequence: SequenceReference? = nil, bookmark: Data?, absolutePath: String,
                relativePath: String?, identity: SourceIdentity, duration: FrameTime, displaySize: PixelSize, frameCount: Int) {
        self.kind = kind
        self.sequence = sequence
        self.bookmark = bookmark
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.identity = identity
        self.duration = duration
        self.displaySize = displaySize
        self.frameCount = frameCount
    }

    enum CodingKeys: String, CodingKey {
        case kind, sequence, bookmark, absolutePath, relativePath, identity, duration, displaySize, frameCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(SourceKind.self, forKey: .kind) ?? .video
        sequence = try c.decodeIfPresent(SequenceReference.self, forKey: .sequence)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        absolutePath = try c.decode(String.self, forKey: .absolutePath)
        relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath)
        identity = try c.decode(SourceIdentity.self, forKey: .identity)
        duration = try c.decode(FrameTime.self, forKey: .duration)
        displaySize = try c.decode(PixelSize.self, forKey: .displaySize)
        frameCount = try c.decode(Int.self, forKey: .frameCount)
    }

    /// A reference to the open media (video file or sequence folder).
    public static func make(source: MediaSource, identity: SourceIdentity, frameCount: Int, projectURL: URL?) -> SourceReference {
        var reference = make(url: source.url, identity: identity, duration: source.duration, displaySize: source.displaySize,
                             frameCount: frameCount, projectURL: projectURL)
        if let sequence = source.imageSequence {
            reference.kind = .imageSequence
            reference.sequence = SequenceReference(sequence)
        }
        return reference
    }

    public static func make(url: URL, identity: SourceIdentity, duration: FrameTime, displaySize: PixelSize,
                            frameCount: Int, projectURL: URL?) -> SourceReference {
        let standardized = url.standardizedFileURL
        let bookmark = try? standardized.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        // Compare canonical paths so `/tmp` (a symlink to `/private/tmp`) and
        // `/private/tmp` still yield a relative path.
        let relative = projectURL.flatMap {
            Self.relativePath(to: standardized.resolvingSymlinksInPath(),
                              from: $0.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath())
        }
        return SourceReference(bookmark: bookmark, absolutePath: standardized.path, relativePath: relative,
                               identity: identity, duration: duration, displaySize: displaySize, frameCount: frameCount)
    }

    /// Candidate locations, most trustworthy first: the bookmark, the saved
    /// absolute path, then the path relative to the project file.
    public func candidates(projectURL: URL?) -> [URL] {
        var urls: [URL] = []
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                urls.append(url)
            }
        }
        urls.append(URL(fileURLWithPath: absolutePath))
        if let relativePath, let projectURL {
            urls.append(projectURL.deletingLastPathComponent().appendingPathComponent(relativePath).standardizedFileURL)
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }

    static func relativePath(to target: URL, from base: URL) -> String? {
        let t = target.pathComponents
        let b = base.pathComponents
        guard t.first == "/", b.first == "/" else { return nil }
        var common = 0
        while common < min(t.count, b.count), t[common] == b[common] { common += 1 }
        guard common > 1 else { return nil } // nothing but the root in common
        let ups = Array(repeating: "..", count: b.count - common)
        return (ups + t[common...]).joined(separator: "/")
    }
}

/// Outcome of locating a project's media.
public enum SourceResolution: Equatable, Sendable {
    /// A file with the saved fingerprint exists here.
    case found(URL)
    /// A file exists at a remembered location but is not the saved media.
    case changed(URL, differences: [String])
    /// No remembered location has a file.
    case missing
}

public enum SourceLocator {
    public static func resolve(_ reference: SourceReference, projectURL: URL?) -> SourceResolution {
        var changed: SourceResolution?
        for url in reference.candidates(projectURL: projectURL) where FileManager.default.fileExists(atPath: url.path) {
            switch check(url, against: reference) {
            case .found:
                return .found(url)
            case let other:
                if changed == nil { changed = other }
            }
        }
        return changed ?? .missing
    }

    /// Compares one file or folder (e.g. chosen in a relink panel) with the
    /// saved reference.
    public static func check(_ url: URL, against reference: SourceReference) -> SourceResolution {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let current: SourceIdentity
        if let saved = reference.sequence {
            guard ImageSequenceLoader.isDirectory(url) else {
                return .changed(url, differences: ["not a folder of images"])
            }
            // Header-only listing of exactly the saved file names.
            let files = saved.fileNames.compactMap { ImageSequenceLoader.describe(url.appendingPathComponent($0)) }
            let sequence = ImageSequenceInfo(folderURL: url, files: files, displaySize: files.first?.pixelSize ?? PixelSize(width: 0, height: 0),
                                             framesPerSecond: saved.framesPerSecond, reversed: saved.reversed, skippedFileNames: [])
            current = SourceIdentity.compute(forSequence: sequence)
            var differences = current.differences(from: reference.identity)
            if files.count != saved.fileNames.count {
                differences.insert("\(saved.fileNames.count - files.count) of \(saved.fileNames.count) images missing", at: 0)
            }
            return differences.isEmpty ? .found(url) : .changed(url, differences: differences)
        }
        guard let identity = try? SourceIdentity.compute(for: url) else {
            return .changed(url, differences: ["unreadable"])
        }
        let differences = identity.differences(from: reference.identity)
        return differences.isEmpty ? .found(url) : .changed(url, differences: differences)
    }

    /// Backwards-compatible form for a plain video file.
    public static func check(_ url: URL, against identity: SourceIdentity) -> SourceResolution {
        check(url, against: SourceReference(bookmark: nil, absolutePath: url.path, relativePath: nil, identity: identity,
                                            duration: .zero, displaySize: PixelSize(width: 0, height: 0), frameCount: 0))
    }
}

/// The `.framestack` document: a single JSON file (DECISIONS.md D-019).
public struct ProjectFile: Codable, Equatable, Sendable {
    /// 1: videos only. 2: adds `source.kind` and `source.sequence` (image
    /// sequences); format-1 files read unchanged.
    public static let currentFormatVersion = 2
    public static let fileExtension = "framestack"
    public static let typeIdentifier = "local.framestack.project"

    public struct UIState: Codable, Equatable, Sendable {
        public var previewQuality: String?
        public var viewMode: String?
        public var scrubIndex: Int?
        public init(previewQuality: String? = nil, viewMode: String? = nil, scrubIndex: Int? = nil) {
            self.previewQuality = previewQuality
            self.viewMode = viewMode
            self.scrubIndex = scrubIndex
        }
    }

    public var formatVersion: Int
    public var writer: String
    public var source: SourceReference
    public var settings: CompositeSettings
    public var export: ExportSettings
    public var ui: UIState

    public init(source: SourceReference, settings: CompositeSettings, export: ExportSettings, ui: UIState = UIState(),
                writer: String = "FrameStack") {
        self.formatVersion = Self.currentFormatVersion
        self.writer = writer
        self.source = source
        self.settings = settings
        self.export = export
        self.ui = ui
    }

    public static func read(from url: URL) throws -> ProjectFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProjectError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        // Check the version before decoding the whole document so a newer
        // schema produces a clear message instead of a decoding error.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProjectError.corrupt(path: url.path, reason: "The file is not a JSON object.")
        }
        guard let version = object["formatVersion"] as? Int else {
            throw ProjectError.corrupt(path: url.path, reason: "It has no formatVersion.")
        }
        guard version <= currentFormatVersion else {
            throw ProjectError.newerFormat(path: url.path, version: version)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        do {
            return try decoder.decode(ProjectFile.self, from: data)
        } catch {
            throw ProjectError.corrupt(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Atomic write (temp file + replace) of pretty, key-sorted JSON.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
