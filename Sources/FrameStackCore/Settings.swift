import Foundation

/// How frames inside the time range are chosen (PRD §4.2).
public enum SamplingKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case all
    case everyNth
    case exactCount

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .everyNth: return "Every Nth"
        case .exactCount: return "Exact Count"
        }
    }
}

/// Every user-editable, non-destructive compositing setting — one value
/// that undo/redo snapshots and project files store.
public struct CompositeSettings: Sendable, Codable, Equatable {
    public var rangeStart: FrameTime
    public var rangeEnd: FrameTime
    public var samplingKind: SamplingKind
    public var nth: Int
    public var exactCount: Int
    public var blendMode: BlendMode
    /// 0…1; only modes with `BlendMode.usesOpacity` use it.
    public var opacity: Double

    public init(rangeStart: FrameTime, rangeEnd: FrameTime, samplingKind: SamplingKind, nth: Int, exactCount: Int,
                blendMode: BlendMode, opacity: Double) {
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.samplingKind = samplingKind
        self.nth = nth
        self.exactCount = exactCount
        self.blendMode = blendMode
        self.opacity = opacity
    }

    public var samplingMode: SamplingMode {
        switch samplingKind {
        case .all: return .all
        case .everyNth: return .everyNth(nth)
        case .exactCount: return .exactCount(exactCount)
        }
    }

    public var range: FrameTimeRange { FrameTimeRange(start: rangeStart, end: rangeEnd) }
}

// MARK: - Export settings

public enum ExportFormat: String, Sendable, Codable, CaseIterable, Identifiable {
    case png
    case jpeg
    case tiff

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tif"
        }
    }

    /// JPEG is 8-bit only; PNG and TIFF can carry 16 bits per channel.
    public var supportsSixteenBit: Bool { self != .jpeg }
}

/// The color space the composite is encoded into on export. The working
/// space is linear extended sRGB; both outputs share the sRGB transfer
/// curve and differ only in primaries (see `ColorPrimaries`).
public enum OutputColorSpace: String, Sendable, Codable, CaseIterable, Identifiable {
    case sRGB
    case displayP3

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        }
    }
}

/// Output dimensions relative to the source's display size. Downscaling only:
/// FrameStack never invents pixels (PRD §10.2 "native output dimensions by
/// default, output resizing selectable").
public enum OutputSizing: Sendable, Codable, Equatable {
    case native
    /// Long edge capped at this many pixels (clamped to the native size).
    case longEdge(Int)
    /// Percentage of the native size, 1…100.
    case percent(Int)

    /// Long-edge cap handed to the renderer; `nil` means native.
    public func maxLongEdge(for native: PixelSize) -> Int? {
        switch self {
        case .native:
            return nil
        case let .longEdge(pixels):
            return min(max(pixels, 1), native.longEdge)
        case let .percent(percent):
            let p = min(max(percent, 1), 100)
            if p == 100 { return nil }
            return max(1, Int((Double(native.longEdge) * Double(p) / 100).rounded()))
        }
    }

    /// Exact output size for a given native size.
    public func outputSize(for native: PixelSize) -> PixelSize {
        native.fitting(maxLongEdge: maxLongEdge(for: native))
    }

    // Stored as {"kind": "native" | "longEdge" | "percent", "value": n}
    // instead of the synthesized {"percent": {"_0": 50}}.
    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "native": self = .native
        case "longEdge": self = .longEdge(try c.decode(Int.self, forKey: .value))
        case "percent": self = .percent(try c.decode(Int.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown sizing kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .native:
            try c.encode("native", forKey: .kind)
        case let .longEdge(v):
            try c.encode("longEdge", forKey: .kind)
            try c.encode(v, forKey: .value)
        case let .percent(v):
            try c.encode("percent", forKey: .kind)
            try c.encode(v, forKey: .value)
        }
    }
}

/// What an export writes. Stored in project files; not part of undo.
public struct ExportSettings: Sendable, Codable, Equatable {
    public var format: ExportFormat
    public var bitDepth: ExportBitDepth
    /// 0…1, JPEG only.
    public var jpegQuality: Double
    public var sizing: OutputSizing
    public var colorSpace: OutputColorSpace

    public init(format: ExportFormat = .png, bitDepth: ExportBitDepth = .sixteen, jpegQuality: Double = 0.92,
                sizing: OutputSizing = .native, colorSpace: OutputColorSpace = .sRGB) {
        self.format = format
        self.bitDepth = bitDepth
        self.jpegQuality = jpegQuality
        self.sizing = sizing
        self.colorSpace = colorSpace
    }

    /// The bit depth that will actually be written (JPEG is always 8-bit).
    public var effectiveBitDepth: ExportBitDepth {
        format.supportsSixteenBit ? bitDepth : .eight
    }
}
