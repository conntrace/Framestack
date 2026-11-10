import Foundation

/// A built-in starting point: which frames, how they are blended, how they
/// are weighted and whether only the moving parts are kept. Unlike a saved
/// preset (`SettingsPreset`) it leaves everything that corrects or finishes
/// the picture alone — alignment, straighten/crop, colour, painted mask,
/// frame overrides, the time range and the export settings — so trying one
/// never undoes work on the document.
public struct StarterPreset: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// One plain sentence for the menu's help and the batch sheet.
    public var summary: String
    public var samplingKind: SamplingKind
    /// Used when `samplingKind == .everyNth`.
    public var nth: Int
    /// Used when `samplingKind == .exactCount`.
    public var exactCount: Int
    public var blendMode: BlendMode
    public var opacity: Double
    public var weighting: WeightCurve
    /// Keep only what moves, over the Median of the selection.
    public var motionMask: Bool

    public init(id: String, name: String, summary: String, samplingKind: SamplingKind = .all, nth: Int = 2, exactCount: Int = 20,
                blendMode: BlendMode, opacity: Double = 1, weighting: WeightCurve = .flat, motionMask: Bool = false) {
        self.id = id
        self.name = name
        self.summary = summary
        self.samplingKind = samplingKind
        self.nth = nth
        self.exactCount = exactCount
        self.blendMode = blendMode
        self.opacity = opacity
        self.weighting = weighting
        self.motionMask = motionMask
    }

    /// Applies the starter over `settings`. Only the sampling choice (and the
    /// one parameter it uses), blend mode, opacity, stacking order, weighting
    /// and the motion mask's on/off state change; a motion mask that is
    /// turned on uses the Median background and is not inverted, with the
    /// document's threshold, feather and clean-up.
    public func apply(to settings: CompositeSettings, framesInRange: Int?) -> SettingsPreset.Application {
        var s = settings
        s.samplingKind = samplingKind
        switch samplingKind {
        case .everyNth: s.nth = nth
        case .exactCount: s.exactCount = exactCount
        case .all, .pattern: break
        }
        s.blendMode = blendMode
        s.opacity = opacity
        s.reverseOrder = false
        s.weighting = weighting
        s.motionMask.enabled = motionMask
        if motionMask {
            s.motionMask.background = .median
            s.motionMask.invert = false
        }
        var notices = SettingsPreset.samplingNotices(kind: samplingKind, nth: nth, exactCount: exactCount, framesInRange: framesInRange)
        notices.append("Kept from this document: everything but sampling, blend, weighting and the motion mask.")
        return SettingsPreset.Application(settings: s, export: ExportSettings(), notices: notices)
    }

    /// True when applying the starter to `settings` would change nothing.
    public func matches(_ settings: CompositeSettings) -> Bool {
        apply(to: settings, framesInRange: nil).settings == settings
    }

    /// The built-in set, in menu order.
    public static let all: [StarterPreset] = [
        StarterPreset(id: "long-exposure", name: "Long Exposure",
                      summary: "Every frame averaged equally: movement blurs away and noise drops.",
                      blendMode: .average),
        StarterPreset(id: "light-trails", name: "Light Trails",
                      summary: "The brightest value each pixel ever had: headlights, stars, sparks.",
                      blendMode: .lighten),
        StarterPreset(id: "dark-trails", name: "Dark Trails",
                      summary: "The darkest value each pixel ever had: dark subjects crossing a bright scene.",
                      blendMode: .darken),
        StarterPreset(id: "empty-scene", name: "Empty Scene",
                      summary: "The Median of 25 evenly spaced frames: whatever passes through disappears where the background shows most of the time.",
                      samplingKind: .exactCount, exactCount: 25, blendMode: .median),
        StarterPreset(id: "action-sequence", name: "Action Sequence",
                      summary: "Eight evenly spaced positions of whatever moves, laid over a clean background.",
                      samplingKind: .exactCount, exactCount: 8, blendMode: .normal, motionMask: true),
        StarterPreset(id: "fading-echo", name: "Fading Echo",
                      summary: "Twelve evenly spaced frames averaged with the latest counting most: earlier positions fade.",
                      samplingKind: .exactCount, exactCount: 12, blendMode: .average, weighting: WeightCurve(preset: .late)),
    ]
}
