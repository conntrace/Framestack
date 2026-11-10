import Foundation

/// A reusable bundle of creative choices (PRD §9.2): how to sample, blend,
/// weight, align, mask, straighten, colour and export — never *which* file
/// or *where* on its timeline. Applying one to a document keeps what belongs
/// to that picture: the time range, the crop and the painted strokes.
public struct SettingsPreset: Sendable, Codable, Equatable {
    public static let currentFormatVersion = 1
    public static let fileExtension = "framestackpreset"

    public var formatVersion: Int
    public var name: String
    public var created: Date
    public var samplingKind: SamplingKind
    public var nth: Int
    public var exactCount: Int
    public var samplingPattern: SamplingPattern
    public var blendMode: BlendMode
    public var opacity: Double
    /// Stack last to first; stored only for order-dependent blend modes.
    public var reverseOrder: Bool
    public var alignment: AlignmentSettings
    public var weighting: WeightCurve
    public var motionMask: MotionMaskSettings
    /// Painted strokes are drawn on one picture and are not carried; only
    /// the invert switch is.
    public var paintedMaskInverted: Bool
    public var rotationDegrees: Double
    public var edgeFill: EdgeFill
    public var color: ColorAdjustments
    public var export: ExportSettings

    public init(name: String, created: Date = Date(), settings: CompositeSettings, export: ExportSettings) {
        formatVersion = Self.currentFormatVersion
        self.name = name
        self.created = created
        samplingKind = settings.samplingKind
        nth = settings.nth
        exactCount = settings.exactCount
        samplingPattern = settings.samplingPattern
        blendMode = settings.blendMode
        opacity = settings.opacity
        reverseOrder = settings.reverseOrder && settings.blendMode.isOrderDependent
        // A reference or background *frame* is a position on one clip's
        // timeline; presets keep the documented automatic choices instead.
        alignment = settings.alignment
        if case .frame = alignment.reference { alignment.reference = .middle }
        weighting = settings.weighting
        motionMask = settings.motionMask
        if case .frame = motionMask.background { motionMask.background = .median }
        paintedMaskInverted = settings.paintedMask.invert
        rotationDegrees = settings.geometry.rotationDegrees
        edgeFill = settings.geometry.edgeFill
        color = settings.color
        self.export = export
    }

    /// The result of applying a preset: the new settings plus plain-language
    /// notes on what was kept or does not fit the current document.
    public struct Application: Sendable, Equatable {
        public var settings: CompositeSettings
        public var export: ExportSettings
        public var notices: [String]
    }

    /// Applies the preset over `settings`. `framesInRange` (the eligible
    /// frame count of the document's range, when known) drives the notices
    /// about sampling choices that the range cannot honour; the sampler
    /// itself clamps them, so the result always renders.
    public func apply(to settings: CompositeSettings, framesInRange: Int?) -> Application {
        var s = settings
        s.samplingKind = samplingKind
        s.nth = nth
        s.exactCount = exactCount
        s.samplingPattern = samplingPattern
        s.blendMode = blendMode
        s.opacity = opacity
        s.reverseOrder = reverseOrder
        s.alignment = alignment
        s.weighting = weighting
        s.motionMask = motionMask
        s.paintedMask.invert = paintedMaskInverted
        s.geometry.rotationDegrees = rotationDegrees
        s.geometry.edgeFill = edgeFill
        s.color = color

        var notices = Self.samplingNotices(kind: samplingKind, nth: nth, exactCount: exactCount, framesInRange: framesInRange)
        var kept = ["the time range"]
        if settings.geometry.crop != .full { kept.append("the crop") }
        if !settings.paintedMask.isEmpty { kept.append("the painted mask (\(settings.paintedMask.strokes.count) stroke\(settings.paintedMask.strokes.count == 1 ? "" : "s"))") }
        if !settings.frameOverrides.isEmpty {
            let n = settings.frameOverrides.count
            kept.append("\(n) frame override\(n == 1 ? "" : "s")")
        }
        notices.append("Kept from this document: " + kept.joined(separator: ", ") + ".")
        if !blendMode.usesWeights, weighting.preset != .flat {
            notices.append("\(blendMode.displayName) ignores the preset's weighting.")
        }
        if !blendMode.usesOpacity, opacity < 1 {
            notices.append("\(blendMode.displayName) ignores the preset's opacity.")
        }
        return Application(settings: s, export: export, notices: notices)
    }

    /// Notes on a sampling choice the range cannot honour (the sampler clamps
    /// it, so the result still renders). Empty when the frame count is unknown.
    public static func samplingNotices(kind: SamplingKind, nth: Int, exactCount: Int, framesInRange: Int?) -> [String] {
        guard let n = framesInRange else { return [] }
        var notices: [String] = []
        if kind == .exactCount, exactCount > n {
            notices.append("Exact Count \(exactCount) is more than the \(n) frames in this range; all \(n) are used.")
        }
        if kind == .everyNth, nth > max(n - 1, 1) {
            notices.append("Every \(ordinal(nth)) frame selects only the first frame of this \(n)-frame range.")
        }
        return notices
    }

    /// True when applying the preset to `settings` would change nothing.
    public func matches(_ settings: CompositeSettings, export: ExportSettings) -> Bool {
        let applied = apply(to: settings, framesInRange: nil)
        return applied.settings == settings && applied.export == export
    }

    /// A file-system-safe stem for the preset's name: slashes and colons
    /// become dashes, surrounding whitespace is dropped, the length is
    /// bounded, and an empty name becomes "Preset".
    public static func fileStem(for name: String) -> String {
        var stem = name.trimmingCharacters(in: .whitespacesAndNewlines)
        stem = String(stem.map { "/:\\".contains($0) ? "-" : $0 })
        while stem.hasPrefix(".") { stem.removeFirst() }
        if stem.count > 100 { stem = String(stem.prefix(100)) }
        return stem.isEmpty ? "Preset" : stem
    }

    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (1, let h) where h != 11: suffix = "st"
        case (2, let h) where h != 12: suffix = "nd"
        case (3, let h) where h != 13: suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, created, samplingKind, nth, exactCount, samplingPattern, blendMode, opacity, reverseOrder,
             alignment, weighting, motionMask, paintedMaskInverted, rotationDegrees, edgeFill, color, export
    }

    /// Missing optional parts fall back to their defaults so a hand-edited
    /// or trimmed preset still loads; the required core is name + blend.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.currentFormatVersion
        name = try c.decode(String.self, forKey: .name)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date(timeIntervalSince1970: 0)
        samplingKind = try c.decodeIfPresent(SamplingKind.self, forKey: .samplingKind) ?? .all
        nth = try c.decodeIfPresent(Int.self, forKey: .nth) ?? 2
        exactCount = try c.decodeIfPresent(Int.self, forKey: .exactCount) ?? 20
        samplingPattern = try c.decodeIfPresent(SamplingPattern.self, forKey: .samplingPattern) ?? .default
        reverseOrder = try c.decodeIfPresent(Bool.self, forKey: .reverseOrder) ?? false
        blendMode = try c.decode(BlendMode.self, forKey: .blendMode)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        alignment = try c.decodeIfPresent(AlignmentSettings.self, forKey: .alignment) ?? .off
        weighting = try c.decodeIfPresent(WeightCurve.self, forKey: .weighting) ?? .flat
        motionMask = try c.decodeIfPresent(MotionMaskSettings.self, forKey: .motionMask) ?? .off
        paintedMaskInverted = try c.decodeIfPresent(Bool.self, forKey: .paintedMaskInverted) ?? false
        rotationDegrees = try c.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
        edgeFill = try c.decodeIfPresent(EdgeFill.self, forKey: .edgeFill) ?? .transparent
        color = try c.decodeIfPresent(ColorAdjustments.self, forKey: .color) ?? .identity
        export = try c.decodeIfPresent(ExportSettings.self, forKey: .export) ?? ExportSettings()
    }
}
