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

/// Where a project's media lives, with enough redundancy to find it again
/// after a move, a rename or a copy of the whole folder.
public struct SourceReference: Sendable, Codable, Equatable {
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

    public init(bookmark: Data?, absolutePath: String, relativePath: String?, identity: SourceIdentity,
                duration: FrameTime, displaySize: PixelSize, frameCount: Int) {
        self.bookmark = bookmark
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.identity = identity
        self.duration = duration
        self.displaySize = displaySize
        self.frameCount = frameCount
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
            switch check(url, against: reference.identity) {
            case .found:
                return .found(url)
            case let other:
                if changed == nil { changed = other }
            }
        }
        return changed ?? .missing
    }

    /// Compares one file (e.g. chosen in a relink panel) with the saved identity.
    public static func check(_ url: URL, against identity: SourceIdentity) -> SourceResolution {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let current = try? SourceIdentity.compute(for: url) else {
            return .changed(url, differences: ["unreadable"])
        }
        let differences = current.differences(from: identity)
        return differences.isEmpty ? .found(url) : .changed(url, differences: differences)
    }
}

/// The `.framestack` document: a single JSON file (DECISIONS.md D-019).
public struct ProjectFile: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
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
