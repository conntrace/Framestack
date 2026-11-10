import CoreGraphics
import FrameStackCore
import FrameStackMedia
import ImageIO
@testable import FrameStack
import XCTest

/// M6i through the app model: a batch that splits the range into equal
/// parts, and the built-in starter presets.
@MainActor
final class SegmentAndStarterAppTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackSegmentsApp-\(UUID().uuidString)")
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
        let model = AppModel(defaults: UserDefaults(suiteName: "SegmentsApp-\(UUID().uuidString)")!,
                             presetStore: PresetStore(directory: directory.appendingPathComponent("presets")))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        return (model, undo)
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

    func testSplitBatchMakesOneVariantPerVersionAndPartAndWritesEachPartFromItsOwnFrames() async throws {
        let (model, _) = makeModel()
        model.open(fixtures.appendingPathComponent("count_5s_30fps.mp4"))
        try await waitReady(model)
        model.exportSettings = ExportSettings(format: .png, bitDepth: .eight)
        model.blendMode = .normal
        model.setFrameRange(first: 30, last: 149)
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.maximumBatchSegments, 99, "120 frames, capped")

        var choice = BatchChoice()
        choice.starterIDs = ["light-trails"]
        XCTAssertEqual(model.batchVariants(for: choice).map(\.id), ["current", "starter:light-trails"], "not split until asked")
        choice.splitsRange = true
        choice.segmentCount = 4
        XCTAssertEqual(model.batchSegments(for: choice).map(\.frameCount), [30, 30, 30, 30])
        var variants = model.batchVariants(for: choice)
        XCTAssertEqual(variants.map(\.id), [
            "current#part0", "current#part1", "current#part2", "current#part3",
            "starter:light-trails#part0", "starter:light-trails#part1", "starter:light-trails#part2", "starter:light-trails#part3",
        ])
        XCTAssertEqual(variants.map(\.name), [
            "Normal (opacity stack) part 1 of 4", "Normal (opacity stack) part 2 of 4", "Normal (opacity stack) part 3 of 4", "Normal (opacity stack) part 4 of 4",
            "Light Trails part 1 of 4", "Light Trails part 2 of 4", "Light Trails part 3 of 4", "Light Trails part 4 of 4",
        ])
        let timeline = try XCTUnwrap(model.timeline)
        XCTAssertEqual(try variants.map { try $0.settings.selection(in: timeline).selectedIndices.first }, [30, 60, 90, 120, 30, 60, 90, 120])
        XCTAssertEqual(try variants.map { try $0.settings.selection(in: timeline).selectedCount }, Array(repeating: 30, count: 8))
        XCTAssertEqual(variants[4].settings.blendMode, .lighten)
        XCTAssertEqual(variants[3].settings.rangeEnd, model.settings.rangeEnd, "the last part ends where the range ends")

        choice.includesWholeRange = true
        variants = model.batchVariants(for: choice)
        XCTAssertEqual(variants.count, 10)
        XCTAssertEqual(variants.prefix(2).map(\.id), ["current", "starter:light-trails"], "the whole range first")

        // More parts than the cap, and more parts than a short range has frames.
        choice.segmentCount = 500
        XCTAssertEqual(model.batchSegments(for: choice).count, 99)
        model.setFrameRange(first: 30, last: 32)
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.maximumBatchSegments, 3)
        XCTAssertEqual(model.batchSegments(for: choice).map(\.frameCount), [1, 1, 1])
        model.setFrameRange(first: 30, last: 30)
        try await waitUntil { model.isPreviewCurrent }
        choice.includesWholeRange = false
        XCTAssertEqual(model.batchVariants(for: choice).map(\.id), ["current", "starter:light-trails"], "one frame cannot be split")

        // Run it: the current settings over the whole range and in four parts.
        model.setFrameRange(first: 30, last: 149)
        try await waitUntil { model.isPreviewCurrent }
        choice = BatchChoice()
        choice.splitsRange = true
        choice.segmentCount = 4
        choice.includesWholeRange = true
        model.batchChoice = choice
        XCTAssertTrue(model.canStartBatch)
        let folder = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.startBatch(choice: choice, folder: folder)
        let names = [
            "count_5s_30fps Normal (opacity stack) 120f.png",
            "count_5s_30fps Normal (opacity stack) part 1 of 4 30f.png", "count_5s_30fps Normal (opacity stack) part 2 of 4 30f.png",
            "count_5s_30fps Normal (opacity stack) part 3 of 4 30f.png", "count_5s_30fps Normal (opacity stack) part 4 of 4 30f.png",
        ]
        XCTAssertEqual(model.batch?.outputs.map(\.url.lastPathComponent), names)
        try await waitUntil { model.batch?.summary != nil }
        let summary = try XCTUnwrap(model.batch?.summary)
        XCTAssertEqual(summary.finishedCount, 5, "\(summary.outputs.map(\.status))")
        XCTAssertEqual(summary.rendersPerformed, 5, "every part is its own composite")
        XCTAssertEqual(try names.map { try frameIndex(inPNG: folder.appendingPathComponent($0)) }, [149, 59, 89, 119, 149],
                       "Normal at 100 % leaves each part's last frame on top")
        XCTAssertEqual(model.settings.rangeStart, timeline.frames[30], "the document's own range is untouched")
    }

    func testStarterChangesOnlyTheLookInOneUndoStepAndKeepsTheExportSettings() async throws {
        let (model, undo) = makeModel()
        model.open(fixtures.appendingPathComponent("moving_square_24f.mp4"))
        try await waitReady(model)
        XCTAssertEqual(model.starterPresets.map(\.name), ["Long Exposure", "Light Trails", "Dark Trails", "Empty Scene", "Action Sequence", "Fading Echo"])
        XCTAssertEqual(model.matchingPresetName, "Long Exposure", "a new document is a plain average of every frame")

        let export = ExportSettings(format: .tiff, bitDepth: .sixteen)
        model.exportSettings = export
        model.color.exposure = 0.5
        model.geometry.rotationDegrees = 1.5
        model.setFrameRange(first: 4, last: 19)
        try await waitUntil { model.isPreviewCurrent }
        let before = model.settings
        XCTAssertEqual(model.matchingPresetName, "Long Exposure", "colour, geometry and the range are not part of a starter")

        let action = try XCTUnwrap(model.starterPresets.first { $0.id == "action-sequence" })
        model.applyStarterPreset(action)
        XCTAssertEqual(undo.undoActionName, "Apply Preset")
        XCTAssertEqual(model.samplingKind, .exactCount)
        XCTAssertEqual(model.exactCount, 8)
        XCTAssertEqual(model.blendMode, .normal)
        XCTAssertTrue(model.motionMask.enabled)
        XCTAssertEqual(model.motionMask.background, .median)
        XCTAssertEqual(model.color, before.color)
        XCTAssertEqual(model.geometry, before.geometry)
        XCTAssertEqual(model.settings.rangeStart, before.rangeStart)
        XCTAssertEqual(model.settings.rangeEnd, before.rangeEnd)
        XCTAssertEqual(model.exportSettings, export, "a starter never touches the export settings")
        XCTAssertEqual(model.matchingPresetName, "Action Sequence")
        XCTAssertEqual(model.presetActivity,
                       .applied("Action Sequence", notices: ["Kept from this document: everything but sampling, blend, weighting and the motion mask."]))
        try await waitUntil { model.isPreviewCurrent }
        if case let .success(result)? = model.selection { XCTAssertEqual(result.selectedCount, 8) } else { XCTFail("no selection") }

        // A starter that asks for more frames than the range has says so.
        let empty = try XCTUnwrap(model.starterPresets.first { $0.id == "empty-scene" })
        model.applyStarterPreset(empty)
        XCTAssertEqual(model.blendMode, .median)
        XCTAssertFalse(model.motionMask.enabled, "the next starter turns the motion mask back off")
        guard case let .applied(name, notices) = model.presetActivity else { return XCTFail("\(model.presetActivity)") }
        XCTAssertEqual(name, "Empty Scene")
        XCTAssertEqual(notices.first, "Exact Count 25 is more than the 16 frames in this range; all 16 are used.")

        undo.undo()
        XCTAssertEqual(model.matchingPresetName, "Action Sequence", "one step back per starter")
        undo.undo()
        XCTAssertEqual(model.settings, before)
        XCTAssertEqual(model.exportSettings, export)

        // A saved preset with the same look wins the menu label over the starter.
        XCTAssertTrue(model.savePreset(named: "Mine"))
        XCTAssertEqual(model.matchingPresetName, "Mine")
    }
}
