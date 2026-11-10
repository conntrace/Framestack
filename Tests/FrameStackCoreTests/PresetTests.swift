@testable import FrameStackCore
import XCTest

final class PresetTests: XCTestCase {
    private var richSettings: CompositeSettings {
        CompositeSettings(
            rangeStart: FrameTime(seconds: 1.5), rangeEnd: FrameTime(seconds: 4.25), samplingKind: .everyNth, nth: 3, exactCount: 40,
            blendMode: .normal, opacity: 0.35,
            alignment: AlignmentSettings(enabled: true, mode: .perspective, reference: .frame(FrameTime(seconds: 2))),
            geometry: GeometrySettings(rotationDegrees: 2.5, crop: NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6), edgeFill: .white),
            weighting: WeightCurve(preset: .late),
            motionMask: MotionMaskSettings(enabled: true, background: .frame(FrameTime(seconds: 2)), threshold: 0.2, feather: 4, cleanup: 2, invert: true),
            paintedMask: PaintedMaskSettings(enabled: true, strokes: [MaskStroke(points: [.init(x: 0.2, y: 0.3)], radius: 0.05)], invert: true),
            color: ColorAdjustments(exposure: 0.7, contrast: -0.2, saturation: 0.4, temperature: 0.1, tint: -0.3)
        )
    }

    func testPresetCarriesCreativeChoicesAndNothingAboutTheDocument() throws {
        let export = ExportSettings(format: .tiff, bitDepth: .sixteen, jpegQuality: 0.8, sizing: .longEdge(2000), colorSpace: .displayP3)
        let preset = SettingsPreset(name: "Trails", settings: richSettings, export: export)
        let json = try JSONEncoder().encode(preset)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(text.contains("rangeStart"), "no timeline position")
        XCTAssertFalse(text.contains("strokes"), "no painted strokes")
        XCTAssertFalse(text.contains("crop"), "no crop")
        let back = try JSONDecoder().decode(SettingsPreset.self, from: json)
        XCTAssertEqual(back, preset, "round trip")
        XCTAssertEqual(back.export, export)
        XCTAssertEqual(back.motionMask.background, .median, "a frame background falls back to the median")
        XCTAssertEqual(back.alignment.reference, .middle, "a frame reference falls back to the middle")
        XCTAssertEqual(back.alignment.mode, .perspective)
    }

    func testApplyKeepsRangeCropAndStrokesAndReplacesTheRest() {
        let preset = SettingsPreset(name: "Trails", settings: richSettings, export: ExportSettings())
        let plain = CompositeSettings(rangeStart: .zero, rangeEnd: FrameTime(seconds: 0.8), samplingKind: .all, nth: 2, exactCount: 20,
                                      blendMode: .average, opacity: 1)
        var document = plain
        document.geometry.crop = NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
        document.paintedMask = PaintedMaskSettings(enabled: true, strokes: [MaskStroke(points: [.init(x: 0.9, y: 0.9)], radius: 0.1)], invert: false)

        let applied = preset.apply(to: document, framesInRange: 24)
        let s = applied.settings
        XCTAssertEqual(s.rangeStart, .zero)
        XCTAssertEqual(s.rangeEnd, FrameTime(seconds: 0.8))
        XCTAssertEqual(s.geometry.crop, document.geometry.crop)
        XCTAssertEqual(s.paintedMask.strokes, document.paintedMask.strokes)
        XCTAssertTrue(s.paintedMask.enabled)
        XCTAssertTrue(s.paintedMask.invert, "the invert switch comes from the preset")
        XCTAssertEqual(s.samplingKind, .everyNth)
        XCTAssertEqual(s.nth, 3)
        XCTAssertEqual(s.blendMode, .normal)
        XCTAssertEqual(s.opacity, 0.35)
        XCTAssertEqual(s.alignment, AlignmentSettings(enabled: true, mode: .perspective, reference: .middle))
        XCTAssertEqual(s.weighting, richSettings.weighting)
        XCTAssertEqual(s.motionMask.threshold, 0.2)
        XCTAssertEqual(s.motionMask.background, .median)
        XCTAssertEqual(s.geometry.rotationDegrees, 2.5)
        XCTAssertEqual(s.geometry.edgeFill, .white)
        XCTAssertEqual(s.color, richSettings.color)
        XCTAssertEqual(applied.notices, ["Kept from this document: the time range, the crop, the painted mask (1 stroke)."])
        XCTAssertTrue(preset.matches(s, export: ExportSettings()))
        XCTAssertFalse(preset.matches(plain, export: ExportSettings()))
    }

    func testNoticesForSamplingTheRangeCannotHonourAndIgnoredParameters() {
        let plain = CompositeSettings(rangeStart: .zero, rangeEnd: FrameTime(seconds: 1), samplingKind: .all, nth: 2, exactCount: 20,
                                      blendMode: .average, opacity: 1)
        var s = plain
        s.samplingKind = .exactCount
        s.exactCount = 300
        s.blendMode = .lighten
        s.weighting = WeightCurve(preset: .early)
        s.opacity = 0.5
        let notices = SettingsPreset(name: "Many", settings: s, export: ExportSettings()).apply(to: plain, framesInRange: 24).notices
        XCTAssertEqual(notices, [
            "Exact Count 300 is more than the 24 frames in this range; all 24 are used.",
            "Kept from this document: the time range.",
            "Lighten ignores the preset's weighting.",
            "Lighten ignores the preset's opacity.",
        ])
        s.samplingKind = .everyNth
        s.nth = 30
        let nth = SettingsPreset(name: "Sparse", settings: s, export: ExportSettings()).apply(to: plain, framesInRange: 24).notices
        XCTAssertEqual(nth.first, "Every 30th frame selects only the first frame of this 24-frame range.")
        XCTAssertEqual(SettingsPreset(name: "Sparse", settings: s, export: ExportSettings()).apply(to: plain, framesInRange: nil).notices.count, 3,
                       "without a known range only the generic notices")
    }

    func testDecodingToleratesMissingFieldsAndFileStemsAreSafe() throws {
        let minimal = Data(#"{"name":"Bare","blendMode":"lighten"}"#.utf8)
        let preset = try JSONDecoder().decode(SettingsPreset.self, from: minimal)
        XCTAssertEqual(preset.name, "Bare")
        XCTAssertEqual(preset.blendMode, .lighten)
        XCTAssertEqual(preset.samplingKind, .all)
        XCTAssertEqual(preset.opacity, 1)
        XCTAssertEqual(preset.color, .identity)
        XCTAssertEqual(preset.export, ExportSettings())
        XCTAssertEqual(preset.formatVersion, SettingsPreset.currentFormatVersion)
        XCTAssertThrowsError(try JSONDecoder().decode(SettingsPreset.self, from: Data(#"{"name":"NoMode"}"#.utf8)))

        XCTAssertEqual(SettingsPreset.fileStem(for: "  Light Trails / Night: v2  "), "Light Trails - Night- v2")
        XCTAssertEqual(SettingsPreset.fileStem(for: "..hidden"), "hidden")
        XCTAssertEqual(SettingsPreset.fileStem(for: "   "), "Preset")
        XCTAssertEqual(SettingsPreset.fileStem(for: String(repeating: "x", count: 300)).count, 100)
    }

    func testPresetCarriesPatternAndReverseButNotFrameOverrides() throws {
        var s = richSettings
        s.samplingKind = .pattern
        s.samplingPattern = SamplingPattern(take: 3, skip: 2)
        s.reverseOrder = true
        s.frameOverrides = FrameOverrides(excluded: [FrameTime(seconds: 2)], included: [FrameTime(seconds: 3)])
        let preset = SettingsPreset(name: "Stutter", settings: s, export: ExportSettings())
        let json = try JSONEncoder().encode(preset)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(text.contains("frameOverrides"), "overrides belong to a document")
        XCTAssertFalse(text.contains("excluded"))
        XCTAssertEqual(try JSONDecoder().decode(SettingsPreset.self, from: json), preset)
        XCTAssertEqual(preset.samplingPattern, SamplingPattern(take: 3, skip: 2))
        XCTAssertTrue(preset.reverseOrder)

        var document = CompositeSettings(rangeStart: .zero, rangeEnd: FrameTime(seconds: 1), samplingKind: .all, nth: 2, exactCount: 20,
                                         blendMode: .average, opacity: 1)
        document.frameOverrides = FrameOverrides(excluded: [FrameTime(seconds: 0.5)])
        let applied = preset.apply(to: document, framesInRange: 24)
        XCTAssertEqual(applied.settings.samplingKind, .pattern)
        XCTAssertEqual(applied.settings.samplingPattern, SamplingPattern(take: 3, skip: 2))
        XCTAssertTrue(applied.settings.reverseOrder)
        XCTAssertEqual(applied.settings.frameOverrides, document.frameOverrides, "the document keeps its own overrides")
        XCTAssertEqual(applied.notices, ["Kept from this document: the time range, 1 frame override."])
        XCTAssertTrue(preset.matches(applied.settings, export: ExportSettings()))

        // Reverse is meaningless for an order-independent mode and is not stored for one.
        s.blendMode = .lighten
        XCTAssertFalse(SettingsPreset(name: "Lighten", settings: s, export: ExportSettings()).reverseOrder)
        // Presets written before these fields existed.
        let bare = try JSONDecoder().decode(SettingsPreset.self, from: Data(#"{"name":"Bare","blendMode":"normal"}"#.utf8))
        XCTAssertEqual(bare.samplingPattern, .default)
        XCTAssertFalse(bare.reverseOrder)
    }

    func testBlendModeUsesWeightsMatchesItsReducer() {
        for mode in BlendMode.allCases where !mode.requiresFrameHistory {
            XCTAssertEqual(mode.usesWeights, mode.makeReducer(width: 1, height: 1).usesWeights, "\(mode)")
        }
        XCTAssertFalse(BlendMode.median.usesWeights)
    }
}
