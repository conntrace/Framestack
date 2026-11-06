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
    /// Pre-blend registration (M5b). Absent in older documents = off.
    public var alignment: AlignmentSettings
    /// Post-composite straighten/crop/edge fill (M5c). Absent = identity.
    public var geometry: GeometrySettings
    /// Temporal weighting (M6a). Absent = flat.
    public var weighting: WeightCurve
    /// Motion mask (M6c). Absent = off.
    public var motionMask: MotionMaskSettings
    /// Painted mask (M6d). Absent = off.
    public var paintedMask: PaintedMaskSettings
    /// Post-composite colour (M6e). Absent = identity.
    public var color: ColorAdjustments

    public init(rangeStart: FrameTime, rangeEnd: FrameTime, samplingKind: SamplingKind, nth: Int, exactCount: Int,
                blendMode: BlendMode, opacity: Double, alignment: AlignmentSettings = .off, geometry: GeometrySettings = .identity,
                weighting: WeightCurve = .flat, motionMask: MotionMaskSettings = .off, paintedMask: PaintedMaskSettings = .off,
                color: ColorAdjustments = .identity) {
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.samplingKind = samplingKind
        self.nth = nth
        self.exactCount = exactCount
        self.blendMode = blendMode
        self.opacity = opacity
        self.alignment = alignment
        self.geometry = geometry
        self.weighting = weighting
        self.motionMask = motionMask
        self.paintedMask = paintedMask
        self.color = color
    }

    /// The part of the settings that decides which frames are decoded and
    /// how they are reduced. Colour and geometry are applied afterwards to
    /// the cached composite (PRD §10.1).
    public var compositingPart: CompositeSettings {
        var s = self
        s.geometry = .identity
        s.color = .identity
        return s
    }

    private enum CodingKeys: String, CodingKey {
        case rangeStart, rangeEnd, samplingKind, nth, exactCount, blendMode, opacity, alignment, geometry, weighting, motionMask, paintedMask, color
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rangeStart = try c.decode(FrameTime.self, forKey: .rangeStart)
        rangeEnd = try c.decode(FrameTime.self, forKey: .rangeEnd)
        samplingKind = try c.decode(SamplingKind.self, forKey: .samplingKind)
        nth = try c.decode(Int.self, forKey: .nth)
        exactCount = try c.decode(Int.self, forKey: .exactCount)
        blendMode = try c.decode(BlendMode.self, forKey: .blendMode)
        opacity = try c.decode(Double.self, forKey: .opacity)
        alignment = try c.decodeIfPresent(AlignmentSettings.self, forKey: .alignment) ?? .off
        geometry = try c.decodeIfPresent(GeometrySettings.self, forKey: .geometry) ?? .identity
        weighting = try c.decodeIfPresent(WeightCurve.self, forKey: .weighting) ?? .flat
        motionMask = try c.decodeIfPresent(MotionMaskSettings.self, forKey: .motionMask) ?? .off
        paintedMask = try c.decodeIfPresent(PaintedMaskSettings.self, forKey: .paintedMask) ?? .off
        color = try c.decodeIfPresent(ColorAdjustments.self, forKey: .color) ?? .identity
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

// MARK: - Alignment

public enum AlignmentMode: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Global x/y shift per frame (camera drift, handheld jitter).
    case translation
    /// Projective (homography) per frame: adds rotation, scale and perspective.
    case perspective

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .translation: return "Shift only"
        case .perspective: return "Perspective"
        }
    }

    public var explanation: String {
        switch self {
        case .translation:
            return "Each frame is moved in x and y to match the reference. Robust for a steady hand; cannot fix rotation or zoom."
        case .perspective:
            return "Each frame is warped by a homography to match the reference. Handles rotation, zoom and tilt of a mostly flat or distant scene; parallax and moving subjects still cannot be aligned."
        }
    }
}

/// Which selected frame the others are aligned to.
public enum AlignmentReference: Sendable, Codable, Equatable {
    /// The middle of the selected frames (documented automatic choice).
    case middle
    /// A specific frame time; falls back to `middle` if it is not selected.
    case frame(FrameTime)

    private enum CodingKeys: String, CodingKey { case kind, time }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "middle": self = .middle
        case "frame": self = .frame(try c.decode(FrameTime.self, forKey: .time))
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown reference \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .middle:
            try c.encode("middle", forKey: .kind)
        case let .frame(time):
            try c.encode("frame", forKey: .kind)
            try c.encode(time, forKey: .time)
        }
    }

    /// The reference time for a given ascending selection.
    public func resolve(in selected: [FrameTime]) -> FrameTime? {
        guard !selected.isEmpty else { return nil }
        if case let .frame(time) = self, selected.contains(time) { return time }
        return selected[selected.count / 2]
    }
}

/// Optional pre-blend registration of every selected frame to a reference
/// (PRD §6.1). Off by default; part of the undoable, saved settings.
public struct AlignmentSettings: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var mode: AlignmentMode
    public var reference: AlignmentReference

    public init(enabled: Bool = false, mode: AlignmentMode = .translation, reference: AlignmentReference = .middle) {
        self.enabled = enabled
        self.mode = mode
        self.reference = reference
    }

    public static let off = AlignmentSettings()
}

// MARK: - Geometry (M5c)

/// A crop in canvas-normalised units (0…1 of the canvas width/height, origin
/// top-left), so it survives any output size.
public struct NormalizedRect: Sendable, Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    /// Clamped to the canvas and at least one pixel of a `reference` canvas.
    public func clamped(minimumPixels: Double = 1, in canvas: PixelSize) -> NormalizedRect {
        let minW = minimumPixels / Double(max(canvas.width, 1))
        let minH = minimumPixels / Double(max(canvas.height, 1))
        var r = self
        r.width = min(max(r.width, minW), 1)
        r.height = min(max(r.height, minH), 1)
        r.x = min(max(r.x, 0), 1 - r.width)
        r.y = min(max(r.y, 0), 1 - r.height)
        return r
    }

    /// Pixel rectangle for a canvas of `size` (origin top-left), rounded to
    /// whole pixels, never empty.
    public func pixelRect(in size: PixelSize) -> CGRect {
        let x0 = (x * Double(size.width)).rounded()
        let y0 = (y * Double(size.height)).rounded()
        let x1 = ((x + width) * Double(size.width)).rounded()
        let y1 = ((y + height) * Double(size.height)).rounded()
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }

    public static func from(pixels rect: CGRect, in size: PixelSize) -> NormalizedRect {
        NormalizedRect(x: rect.minX / Double(size.width), y: rect.minY / Double(size.height),
                       width: rect.width / Double(size.width), height: rect.height / Double(size.height))
    }

    public var isFull: Bool { self == .full }
}

/// What to put where the composite has no coverage (aligned frames that
/// moved away, letterboxed stills): keep the transparency or fill a colour.
public enum EdgeFill: String, Sendable, Codable, CaseIterable, Identifiable {
    case transparent
    case black
    case white

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .transparent: return "Transparent"
        case .black: return "Black"
        case .white: return "White"
        }
    }

    /// Linear fill colour, nil for transparent.
    public var linearColor: SIMD3<Float>? {
        switch self {
        case .transparent: return nil
        case .black: return SIMD3(0, 0, 0)
        case .white: return SIMD3(1, 1, 1)
        }
    }
}

/// Post-composite geometry (PRD §6.2): straighten, crop, edge fill. Applied
/// once to the finished composite, so the per-frame math is untouched and
/// preview equals export by construction.
public struct GeometrySettings: Sendable, Codable, Equatable {
    /// Counter-clockwise straighten angle in degrees, −45…45.
    public var rotationDegrees: Double
    public var crop: NormalizedRect
    public var edgeFill: EdgeFill

    public init(rotationDegrees: Double = 0, crop: NormalizedRect = .full, edgeFill: EdgeFill = .transparent) {
        self.rotationDegrees = rotationDegrees
        self.crop = crop
        self.edgeFill = edgeFill
    }

    public static let identity = GeometrySettings()
    public static let maximumRotation = 45.0

    public var isIdentity: Bool { self == .identity }
    public var hasTransform: Bool { rotationDegrees != 0 || !crop.isFull }

    /// Output size after crop, for a canvas rendered at `size`.
    public func outputSize(for size: PixelSize) -> PixelSize {
        let r = crop.clamped(in: size).pixelRect(in: size)
        return PixelSize(width: Int(r.width), height: Int(r.height))
    }

    /// Largest axis-aligned rectangle (canvas-normalised) that lies inside
    /// `valid` after the canvas is rotated by `rotationDegrees` about its
    /// centre — what "Crop to safe area" sets. `valid` is in canvas pixels
    /// (origin top-left); nil means the whole canvas.
    public func largestValidCrop(valid: CGRect?, canvas: PixelSize) -> NormalizedRect {
        let full = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let area = (valid ?? full).intersection(full)
        guard !area.isNull, area.width > 0, area.height > 0 else { return .full }
        let theta = rotationDegrees * .pi / 180
        let (w, h) = Self.largestInscribedSize(width: area.width, height: area.height, angle: theta)
        // The valid area's centre moves with the rotation about the canvas centre.
        let c = CGPoint(x: full.midX, y: full.midY)
        let v = CGPoint(x: area.midX - c.x, y: area.midY - c.y)
        // Screen coordinates have y down: a counter-clockwise rotation on
        // screen is a clockwise one in these coordinates.
        let rotated = CGPoint(x: v.x * cos(theta) + v.y * sin(theta), y: -v.x * sin(theta) + v.y * cos(theta))
        var rect = CGRect(x: c.x + rotated.x - w / 2, y: c.y + rotated.y - h / 2, width: w, height: h).intersection(full)
        if rect.isNull || rect.width < 1 || rect.height < 1 { rect = full }
        return NormalizedRect.from(pixels: rect, in: canvas).clamped(in: canvas)
    }

    /// Largest axis-aligned rectangle inscribed in a `width`×`height`
    /// rectangle rotated by `angle` (the classic closed form; centred).
    public static func largestInscribedSize(width: Double, height: Double, angle: Double) -> (Double, Double) {
        guard width > 0, height > 0 else { return (0, 0) }
        let sinA = abs(sin(angle)), cosA = abs(cos(angle))
        let widthIsLonger = width >= height
        let long = widthIsLonger ? width : height
        let short = widthIsLonger ? height : width
        if short <= 2 * sinA * cosA * long || abs(sinA - cosA) < 1e-10 {
            // Half-constrained: the rectangle touches the short side only.
            let x = 0.5 * short
            return widthIsLonger ? (x / sinA, x / cosA) : (x / cosA, x / sinA)
        }
        let cos2A = cosA * cosA - sinA * sinA
        return ((width * cosA - height * sinA) / cos2A, (height * cosA - width * sinA) / cos2A)
    }
}
