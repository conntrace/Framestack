import Foundation
import FrameStackCore

public enum PresetError: Error, LocalizedError, Equatable {
    case exists(name: String)
    case unreadable(path: String, reason: String)
    case corrupt(path: String, reason: String)
    case newerFormat(path: String, version: Int)

    public var errorDescription: String? {
        switch self {
        case let .exists(name):
            return "A preset named “\(name)” already exists."
        case let .unreadable(path, reason):
            return "The preset “\((path as NSString).lastPathComponent)” could not be read. \(reason)"
        case let .corrupt(path, reason):
            return "The preset “\((path as NSString).lastPathComponent)” is not a valid FrameStack preset. \(reason)"
        case let .newerFormat(path, version):
            return "The preset “\((path as NSString).lastPathComponent)” was saved by a newer version of FrameStack (format \(version); this version reads format \(SettingsPreset.currentFormatVersion))."
        }
    }
}

/// A preset as found on disk.
public struct StoredPreset: Sendable, Equatable, Identifiable {
    public var url: URL
    public var preset: SettingsPreset
    public var id: URL { url }

    public init(url: URL, preset: SettingsPreset) {
        self.url = url
        self.preset = preset
    }
}

/// What a directory of presets contains, including files that failed to load.
public struct PresetListing: Sendable, Equatable {
    public var presets: [StoredPreset]
    public var problems: [String]
    public static let empty = PresetListing(presets: [], problems: [])
}

/// One JSON file per preset in a directory (by default
/// `~/Library/Application Support/FrameStack/Presets`). Files are the whole
/// state: the listing is re-read from disk, so presets copied in from
/// another Mac appear and deleted files disappear.
public struct PresetStore: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/FrameStack/Presets`.
    public static func defaultDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("FrameStack/Presets", isDirectory: true)
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(SettingsPreset.fileStem(for: name)).appendingPathExtension(SettingsPreset.fileExtension)
    }

    public func exists(name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path)
    }

    /// All readable presets sorted by name (Finder order), plus one line per file that could not be read.
    public func list() -> PresetListing {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return .empty
        }
        var listing = PresetListing.empty
        for url in files where url.pathExtension.lowercased() == SettingsPreset.fileExtension {
            do {
                listing.presets.append(StoredPreset(url: url, preset: try Self.read(from: url)))
            } catch {
                listing.problems.append(error.localizedDescription)
            }
        }
        listing.presets.sort { $0.preset.name.localizedStandardCompare($1.preset.name) == .orderedAscending }
        return listing
    }

    /// Writes the preset under its name. Refuses to overwrite a different
    /// file of the same name unless `replacing`.
    @discardableResult
    public func save(_ preset: SettingsPreset, replacing: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = url(for: preset.name)
        if !replacing, FileManager.default.fileExists(atPath: url.path) {
            throw PresetError.exists(name: preset.name)
        }
        try Self.write(preset, to: url)
        return url
    }

    public func delete(_ stored: StoredPreset) throws {
        try FileManager.default.removeItem(at: stored.url)
    }

    public static func read(from url: URL) throws -> SettingsPreset {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PresetError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PresetError.corrupt(path: url.path, reason: "The file is not a JSON object.")
        }
        if let version = object["formatVersion"] as? Int, version > SettingsPreset.currentFormatVersion {
            throw PresetError.newerFormat(path: url.path, version: version)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SettingsPreset.self, from: data)
        } catch {
            throw PresetError.corrupt(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Atomic write of pretty, key-sorted JSON.
    public static func write(_ preset: SettingsPreset, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(preset).write(to: url, options: .atomic)
    }
}
