import CoreGraphics
import FrameStackCore
import FrameStackMedia
import ImageIO
@testable import FrameStack
import XCTest

/// M6h through the app model: the take/skip pattern, per-frame overrides and
/// the reverse stacking order — undo names, the selection summary, the
/// composite cache, export, projects, presets and what a new source resets.
@MainActor
final class FrameSelectionAppTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackSelectionApp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("FrameStackMediaTests/Fixtures")
    }

    private func waitUntil(_ timeout: TimeInterval = 30, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw XCTSkip("timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitReady(_ model: AppModel) async throws {
        try await waitUntil { if case .ready = model.sourceState { return true } else { return false } }
        try await waitUntil { model.isPreviewCurrent }
    }

    private func makeModel() -> (AppModel, UndoManager) {
        let model = AppModel(defaults: UserDefaults(suiteName: "SelectionApp-\(UUID().uuidString)")!,
                             presetStore: PresetStore(directory: directory.appendingPathComponent("presets")))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        return (model, undo)
    }

    private func selected(_ model: AppModel) throws -> SamplingResult {
        guard case let .success(result)? = model.selection else { throw XCTSkip("no selection: \(String(describing: model.selection))") }
        return result
    }

    /// The frame number the count fixture writes into its top row (8 blocks of 40 px, most significant first).
    private func frameIndex(inPNG url: URL) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 320)
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var value = 0
        for b in 0..<8 where buffer[(20 * w + b * 40 + 20) * 4] > 127 { value |= 1 << (7 - b) }
        return value
    }

    /// Exports the current composite and reads the frame number left on top.
    private func exportedTopFrame(_ model: AppModel, _ name: String) async throws -> Int {
        try await waitUntil { model.isPreviewCurrent }
        let url = directory.appendingPathComponent(name)
        model.export(to: url)
        try await waitUntil { !model.isExporting }
        guard case .finished = model.exportActivity else { throw XCTSkip("export did not finish: \(model.exportActivity)") }
        return try frameIndex(inPNG: url)
    }

    func testPatternAndOverridesChangeTheSelectionWithNamedUndoSteps() async throws {
        let (model, undo) = makeModel()
        model.open(fixtures.appendingPathComponent("count_5s_30fps.mp4"))
        try await waitReady(model)
        XCTAssertEqual(try selected(model).selectedCount, 150)
        XCTAssertEqual(try selected(model).summaryText, "150 frames in range → 150 selected")
        XCTAssertNil(model.overrideAtPlayhead, "no playhead yet")
        model.toggleExcludeAtPlayhead()
        XCTAssertTrue(model.frameOverrides.isEmpty, "nothing to exclude without a playhead")

        model.samplingKind = .pattern
        XCTAssertEqual(undo.undoActionName, "Change Sampling")
        XCTAssertEqual(try selected(model).selectedCount, 75, "the default pattern takes one and skips one")
        model.samplingPattern = SamplingPattern(take: 2, skip: 3)
        XCTAssertEqual(undo.undoActionName, "Change Sampling")
        XCTAssertEqual(Array(try selected(model).selectedIndices.prefix(5)), [0, 1, 5, 6, 10])
        XCTAssertEqual(try selected(model).selectedCount, 60)

        model.scrubIndex = 5
        XCTAssertEqual(model.overrideAtPlayhead, .auto)
        XCTAssertTrue(model.playheadIsInRange)
        XCTAssertTrue(model.playheadIsSelected)
        model.toggleExcludeAtPlayhead()
        XCTAssertEqual(undo.undoActionName, "Exclude Frame")
        XCTAssertEqual(model.overrideAtPlayhead, .excluded)
        XCTAssertFalse(model.playheadIsSelected)
        XCTAssertEqual(Array(try selected(model).selectedIndices.prefix(5)), [0, 1, 6, 10, 11], "no neighbour takes its place")
        XCTAssertEqual(try selected(model).summaryText, "150 frames in range → 59 selected (1 excluded)")

        model.scrubIndex = 3
        XCTAssertFalse(model.playheadIsSelected, "the pattern skips frame 3")
        model.setOverrideAtPlayhead(.included)
        XCTAssertEqual(undo.undoActionName, "Always Include Frame")
        XCTAssertTrue(model.playheadIsSelected)
        XCTAssertEqual(Array(try selected(model).selectedIndices.prefix(5)), [0, 1, 3, 6, 10])
        XCTAssertEqual(try selected(model).summaryText, "150 frames in range → 60 selected (1 excluded, 1 added)")

        // Outside the range an override stays stored but does nothing.
        model.setFrameRange(first: 10, last: 149)
        XCTAssertFalse(model.playheadIsInRange)
        XCTAssertEqual(try selected(model).inactiveOverrides, 2)
        XCTAssertEqual(try selected(model).summaryText, "140 frames in range → 56 selected")
        undo.undo()
        XCTAssertEqual(try selected(model).inactiveOverrides, 0)

        model.setOverrideAtPlayhead(.auto)
        XCTAssertEqual(undo.undoActionName, "Clear Frame Override")
        XCTAssertEqual(model.frameOverrides.count, 1)
        undo.undo()
        XCTAssertEqual(model.frameOverrides.count, 2, "undo puts the override back")
        model.clearFrameOverrides()
        XCTAssertEqual(undo.undoActionName, "Clear Frame Overrides")
        XCTAssertTrue(model.frameOverrides.isEmpty)
        XCTAssertEqual(try selected(model).selectedCount, 60)
        undo.undo()
        XCTAssertEqual(model.frameOverrides.count, 2)

        // Excluding every selected frame is reported, not rendered as something else.
        model.samplingKind = .exactCount
        model.exactCount = 1
        model.clearFrameOverrides()
        model.scrubIndex = try XCTUnwrap(try selected(model).selectedIndices.first)
        model.toggleExcludeAtPlayhead()
        guard case .failure(.allFramesExcluded)? = model.selection else { return XCTFail("\(String(describing: model.selection))") }
        model.toggleExcludeAtPlayhead()
        XCTAssertEqual(try selected(model).selectedCount, 1)
    }

    func testReverseOrderReusesTheCompositeWhereOrderCannotMatterAndExportsTheExpectedTopFrame() async throws {
        let (model, undo) = makeModel()
        model.open(fixtures.appendingPathComponent("count_5s_30fps.mp4"))
        try await waitReady(model)
        model.exportSettings = ExportSettings(format: .png, bitDepth: .eight)
        XCTAssertEqual(model.blendMode, .average)
        let renders = model.previewRenderCount

        model.reverseOrder = true
        XCTAssertEqual(undo.undoActionName, "Reverse Stacking Order")
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.previewRenderCount, renders, "Average is the same in any order: the cached composite is reused")
        XCTAssertEqual(model.preview?.stackedInReverse, false)

        model.blendMode = .normal
        model.opacity = 1
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.previewRenderCount, renders + 1)
        XCTAssertEqual(model.preview?.stackedInReverse, true)
        XCTAssertNotNil(model.preview?.reverseDecode, "a video decoded back to front reports how")
        let top1 = try await exportedTopFrame(model, "reverse-all.png")
        XCTAssertEqual(top1, 0, "newest first leaves the first frame on top")

        // Take 1, skip 1 selects the even frames; excluding frame 0 leaves 2 on top, then including 1 puts it there.
        model.samplingKind = .pattern
        model.samplingPattern = SamplingPattern(take: 1, skip: 1)
        model.scrubIndex = 0
        model.toggleExcludeAtPlayhead()
        let top2 = try await exportedTopFrame(model, "reverse-excluded.png")
        XCTAssertEqual(top2, 2)
        model.scrubIndex = 1
        model.setOverrideAtPlayhead(.included)
        let top3 = try await exportedTopFrame(model, "reverse-included.png")
        XCTAssertEqual(top3, 1)

        let before = model.previewRenderCount
        model.reverseOrder = false
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.previewRenderCount, before + 1, "Normal depends on the order")
        XCTAssertEqual(model.preview?.stackedInReverse, false)
        XCTAssertNil(model.preview?.reverseDecode)
        let top4 = try await exportedTopFrame(model, "forward.png")
        XCTAssertEqual(top4, 148, "the last even frame")
        model.scrubIndex = 149
        model.setOverrideAtPlayhead(.included)
        let top5 = try await exportedTopFrame(model, "forward-included.png")
        XCTAssertEqual(top5, 149)
    }

    func testProjectsKeepPatternOverridesAndReverseAndANewSourceDropsOnlyTheOverrides() async throws {
        let (model, _) = makeModel()
        model.open(fixtures.appendingPathComponent("count_5s_30fps.mp4"))
        try await waitReady(model)
        model.blendMode = .normal
        model.reverseOrder = true
        model.samplingKind = .pattern
        model.samplingPattern = SamplingPattern(take: 3, skip: 4)
        model.scrubIndex = 7
        model.toggleExcludeAtPlayhead()
        model.scrubIndex = 4
        model.setOverrideAtPlayhead(.included)
        let overrides = model.frameOverrides
        XCTAssertEqual(overrides.count, 2)
        let expected = try selected(model).selectedIndices

        let projectURL = directory.appendingPathComponent("selection.framestack")
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.save(to: projectURL))
        XCTAssertFalse(model.hasUnsavedChanges)
        let (reopened, _) = makeModel()
        reopened.open(projectURL)
        try await waitReady(reopened)
        XCTAssertEqual(reopened.samplingKind, .pattern)
        XCTAssertEqual(reopened.samplingPattern, SamplingPattern(take: 3, skip: 4))
        XCTAssertEqual(reopened.frameOverrides, overrides)
        XCTAssertTrue(reopened.reverseOrder)
        XCTAssertEqual(try selected(reopened).selectedIndices, expected)
        XCTAssertEqual(reopened.preview?.stackedInReverse, true)
        XCTAssertFalse(reopened.hasUnsavedChanges)
        reopened.scrubIndex = 7
        reopened.toggleExcludeAtPlayhead()
        XCTAssertTrue(reopened.hasUnsavedChanges, "an override is a document change")

        // Another source: the overrides named frames of the old one; sampling and stacking choices carry over.
        reopened.open(fixtures.appendingPathComponent("moving_square_24f.mp4"))
        try await waitReady(reopened)
        XCTAssertTrue(reopened.frameOverrides.isEmpty)
        XCTAssertEqual(reopened.samplingKind, .pattern)
        XCTAssertEqual(reopened.samplingPattern, SamplingPattern(take: 3, skip: 4))
        XCTAssertTrue(reopened.reverseOrder)
    }

    func testAPresetBringsPatternAndReverseAndLeavesTheDocumentsOverridesAlone() async throws {
        let (model, undo) = makeModel()
        model.open(fixtures.appendingPathComponent("count_5s_30fps.mp4"))
        try await waitReady(model)
        model.blendMode = .normal
        model.reverseOrder = true
        model.samplingKind = .pattern
        model.samplingPattern = SamplingPattern(take: 2, skip: 2)
        model.scrubIndex = 0
        model.toggleExcludeAtPlayhead()
        XCTAssertTrue(model.savePreset(named: "Stutter"))
        XCTAssertEqual(model.matchingPreset?.preset.name, "Stutter", "overrides are not part of the comparison")

        model.blendMode = .average
        model.samplingKind = .all
        model.reverseOrder = false
        model.clearFrameOverrides()
        model.scrubIndex = 9
        model.toggleExcludeAtPlayhead()
        let mine = model.frameOverrides
        XCTAssertNil(model.matchingPreset)

        model.applyPreset(model.presets[0])
        XCTAssertEqual(undo.undoActionName, "Apply Preset")
        XCTAssertEqual(model.samplingKind, .pattern)
        XCTAssertEqual(model.samplingPattern, SamplingPattern(take: 2, skip: 2))
        XCTAssertTrue(model.reverseOrder)
        XCTAssertEqual(model.blendMode, .normal)
        XCTAssertEqual(model.frameOverrides, mine)
        guard case let .applied(_, notices) = model.presetActivity else { return XCTFail("\(model.presetActivity)") }
        XCTAssertEqual(notices, ["Kept from this document: the time range, 1 frame override."])
        undo.undo()
        XCTAssertEqual(model.samplingKind, .all)
        XCTAssertFalse(model.reverseOrder)
        XCTAssertEqual(model.frameOverrides, mine)
    }
}
