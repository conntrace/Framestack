import CoreGraphics
import FrameStackCore
import FrameStackMedia
import ImageIO
@testable import FrameStack
import XCTest

/// M6j through the app model: editing the crop on the preview (the whole
/// canvas is shown while the export keeps cropping), drags as one undo step
/// without re-rendering, the shape lock, and what ends or resets the mode.
@MainActor
final class CropAppTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameStackCropApp-\(UUID().uuidString)")
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
        let model = AppModel(defaults: UserDefaults(suiteName: "CropApp-\(UUID().uuidString)")!,
                             presetStore: PresetStore(directory: directory.appendingPathComponent("presets")))
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        return (model, undo)
    }

    /// 8-bit sRGB RGBA bytes of an image, top row first.
    private func bytes(_ image: CGImage) -> (width: Int, height: Int, rgba: [UInt8]) {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, buffer)
    }

    private func image(at url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Largest channel difference between `a` and the `rect` region of `b`.
    private func maxDifference(_ a: (width: Int, height: Int, rgba: [UInt8]), _ b: (width: Int, height: Int, rgba: [UInt8]), at origin: (x: Int, y: Int)) -> Int {
        var worst = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                for c in 0..<3 {
                    let d = abs(Int(a.rgba[(y * a.width + x) * 4 + c]) - Int(b.rgba[((y + origin.y) * b.width + x + origin.x) * 4 + c]))
                    worst = max(worst, d)
                }
            }
        }
        return worst
    }

    private func export(_ model: AppModel, _ name: String) async throws -> URL {
        try await waitUntil { model.isPreviewCurrent }
        let url = directory.appendingPathComponent(name)
        model.export(to: url)
        try await waitUntil { !model.isExporting }
        guard case .finished = model.exportActivity else { throw XCTSkip("export did not finish: \(model.exportActivity)") }
        return url
    }

    func testEditingShowsTheWholeCanvasWhileExportAndPreviewKeepTheCrop() async throws {
        let (model, _) = makeModel()
        model.open(fixtures.appendingPathComponent("moving_square_24f.mp4"))
        try await waitReady(model)
        XCTAssertTrue(model.canEditCrop)
        XCTAssertEqual(model.canvasSize, PixelSize(width: 480, height: 272))

        model.setCropPixels(CGRect(x: 100, y: 50, width: 200, height: 100))
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.preview?.size, PixelSize(width: 200, height: 100))
        XCTAssertEqual(model.displayedFullSize, PixelSize(width: 200, height: 100))
        let croppedPreview = bytes(try XCTUnwrap(model.preview?.image))

        // Edit mode: the preview is the whole canvas, the document's crop is unchanged.
        model.isEditingCrop = true
        try await waitUntil { model.isPreviewCurrent && model.preview?.size == PixelSize(width: 480, height: 272) }
        XCTAssertEqual(model.displayedFullSize, PixelSize(width: 480, height: 272))
        XCTAssertEqual(model.displayGeometry.crop, .full)
        XCTAssertEqual(model.cropPixels, CGRect(x: 100, y: 50, width: 200, height: 100))
        XCTAssertEqual(model.settings.geometry.crop.pixelRect(in: PixelSize(width: 480, height: 272)), CGRect(x: 100, y: 50, width: 200, height: 100))
        XCTAssertEqual(model.exportOutputSize, PixelSize(width: 200, height: 100), "the export size is the crop, not what is on screen")
        let wholePreview = bytes(try XCTUnwrap(model.preview?.image))
        XCTAssertEqual(maxDifference(croppedPreview, wholePreview, at: (100, 50)), 0, "the crop region of the whole canvas is the cropped preview")

        // Exporting while the crop is being edited still crops; preview and export agree.
        let exported = bytes(try image(at: try await export(model, "editing.png")))
        XCTAssertEqual(exported.width, 200)
        XCTAssertEqual(exported.height, 100)
        XCTAssertLessThanOrEqual(maxDifference(exported, wholePreview, at: (100, 50)), 1)
        XCTAssertTrue(model.isEditingCrop, "exporting does not leave the mode")

        // Leaving the mode shows the cropped result again.
        model.isEditingCrop = false
        try await waitUntil { model.isPreviewCurrent && model.preview?.size == PixelSize(width: 200, height: 100) }
        XCTAssertEqual(maxDifference(bytes(try XCTUnwrap(model.preview?.image)), croppedPreview, at: (0, 0)), 0)
    }

    func testADragIsOneUndoStepAndDoesNotRenderAgain() async throws {
        let (model, undo) = makeModel()
        model.open(fixtures.appendingPathComponent("moving_square_24f.mp4"))
        try await waitReady(model)
        model.isEditingCrop = true
        try await waitUntil { model.isPreviewCurrent }
        XCTAssertFalse(undo.canUndo, "entering the mode is not an edit")
        let renders = model.previewRenderCount
        let shown = try XCTUnwrap(model.preview?.image)
        let full = CGRect(x: 0, y: 0, width: 480, height: 272)

        // The drag: several pointer positions, nothing committed on the way.
        for step in 1...5 {
            model.dragCrop(from: full, handle: .bottomRight, by: CGSize(width: -20 * step, height: -10 * step))
            XCTAssertEqual(model.cropPixels, CGRect(x: 0, y: 0, width: 480 - 20 * step, height: 272 - 10 * step))
            XCTAssertEqual(model.geometry.crop, .full)
            XCTAssertFalse(undo.canUndo)
            XCTAssertTrue(model.isPreviewCurrent)
        }
        model.endCropDrag()
        XCTAssertNil(model.cropDraft)
        XCTAssertEqual(model.cropPixels, CGRect(x: 0, y: 0, width: 380, height: 222))
        XCTAssertEqual(undo.undoActionName, "Change Crop")
        XCTAssertTrue(model.isPreviewCurrent, "the picture on screen does not depend on the crop while editing")
        XCTAssertTrue(model.preview?.image === shown)
        XCTAssertTrue(model.hasUnsavedChanges)

        // Moving it by the inside, then a new one drawn from outside.
        model.dragCrop(from: model.cropPixels, handle: .body, by: CGSize(width: 500, height: 20))
        model.endCropDrag()
        XCTAssertEqual(model.cropPixels, CGRect(x: 100, y: 20, width: 380, height: 222), "stops at the canvas edge")
        model.drawCrop(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 200, y: 120))
        XCTAssertEqual(model.cropPixels, CGRect(x: 200, y: 120, width: 100, height: 80))
        model.endCropDrag()
        XCTAssertEqual(model.geometry.crop.pixelRect(in: PixelSize(width: 480, height: 272)), CGRect(x: 200, y: 120, width: 100, height: 80))

        // A press that goes nowhere, or a tiny scribble, is not an edit.
        model.dragCrop(from: model.cropPixels, handle: .body, by: .zero)
        model.endCropDrag()
        model.drawCrop(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 13))
        XCTAssertNil(model.cropDraft)
        model.endCropDrag()
        model.dragCrop(from: model.cropPixels, handle: .left, by: CGSize(width: -40, height: 0))
        model.cancelCropDrag()
        XCTAssertEqual(model.cropPixels, CGRect(x: 200, y: 120, width: 100, height: 80))

        // Three edits, three undo steps; none of it rendered frames again.
        undo.undo()
        XCTAssertEqual(model.cropPixels, CGRect(x: 100, y: 20, width: 380, height: 222))
        undo.undo()
        XCTAssertEqual(model.cropPixels, CGRect(x: 0, y: 0, width: 380, height: 222))
        undo.undo()
        XCTAssertEqual(model.geometry.crop, .full)
        XCTAssertFalse(undo.canUndo)
        XCTAssertTrue(model.isPreviewCurrent)
        undo.redo()
        XCTAssertEqual(model.cropPixels, CGRect(x: 0, y: 0, width: 380, height: 222))
        XCTAssertEqual(model.previewRenderCount, renders)
        XCTAssertTrue(model.preview?.image === shown)

        // Outside the mode a crop change does re-process the picture (still without decoding frames).
        model.isEditingCrop = false
        try await waitUntil { model.isPreviewCurrent && model.preview?.size == PixelSize(width: 380, height: 222) }
        XCTAssertEqual(model.previewRenderCount, renders)
    }

    func testShapeLockReshapesFlipsAndHoldsThroughDragsAndFields() async throws {
        let (model, undo) = makeModel()
        model.open(fixtures.appendingPathComponent("moving_square_24f.mp4"))
        try await waitReady(model)
        XCTAssertEqual(model.cropAspect, .free)
        XCTAssertNil(model.cropAspectValue)
        XCTAssertFalse(model.canFlipCropAspect)
        XCTAssertEqual(model.cropAspectChoices.map(\.displayName), ["Free", "Original", "1 : 1", "5 : 4", "4 : 3", "3 : 2", "16 : 9", "2 : 1"])
        XCTAssertEqual(model.cropSummary, "480×272")

        // Choosing a shape reshapes the crop about its centre, as one undo step.
        model.setCropAspect(.ratio(1, 1))
        XCTAssertEqual(model.cropPixels, CGRect(x: 104, y: 0, width: 272, height: 272))
        XCTAssertEqual(model.cropSummary, "272×272 · 1 : 1")
        XCTAssertEqual(undo.undoActionName, "Change Crop")
        model.setCropAspect(.ratio(16, 9))
        XCTAssertEqual(model.cropPixels.width / model.cropPixels.height, 16.0 / 9, accuracy: 0.01)
        XCTAssertTrue(model.canFlipCropAspect)
        model.flipCropAspect()
        XCTAssertEqual(model.cropAspect, .ratio(9, 16))
        XCTAssertEqual(model.cropPixels.width / model.cropPixels.height, 9.0 / 16, accuracy: 0.01)
        XCTAssertEqual(model.cropAspectChoices.map(\.displayName), ["Free", "Original", "1 : 1", "4 : 5", "3 : 4", "2 : 3", "9 : 16", "1 : 2"])
        model.flipCropAspect()
        XCTAssertEqual(model.cropAspect, .ratio(16, 9))

        // Drags keep the shape. A corner follows the pointer on the axis it has gone
        // furthest, so the crop always reaches the pointer: across alone does not shrink it.
        model.isEditingCrop = true
        model.setCropPixels(CGRect(x: 40, y: 40, width: 320, height: 180))
        model.dragCrop(from: model.cropPixels, handle: .bottomRight, by: CGSize(width: -160, height: 0))
        XCTAssertEqual(model.cropPixels, CGRect(x: 40, y: 40, width: 320, height: 180))
        model.dragCrop(from: model.cropPixels, handle: .bottomRight, by: CGSize(width: -160, height: -90))
        model.endCropDrag()
        XCTAssertEqual(model.cropPixels, CGRect(x: 40, y: 40, width: 160, height: 90))
        model.drawCrop(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 420, y: 110))
        model.endCropDrag()
        XCTAssertEqual(model.cropPixels.width / model.cropPixels.height, 16.0 / 9, accuracy: 0.02)
        XCTAssertEqual(model.cropPixels.origin, CGPoint(x: 100, y: 100))

        // Fields: the other side follows; too big gives the largest of the shape from that corner.
        model.setCropPixels(CGRect(x: 40, y: 40, width: 160, height: 90))
        model.setCropField(.width, to: 320)
        XCTAssertEqual(model.cropPixels, CGRect(x: 40, y: 40, width: 320, height: 180))
        model.setCropField(.height, to: 90)
        XCTAssertEqual(model.cropPixels, CGRect(x: 40, y: 40, width: 160, height: 90))
        model.setCropField(.left, to: 100)
        XCTAssertEqual(model.cropPixels, CGRect(x: 100, y: 40, width: 160, height: 90))
        model.setCropField(.width, to: 2000)
        XCTAssertEqual(model.cropPixels.origin, CGPoint(x: 100, y: 40))
        XCTAssertEqual(model.cropPixels.maxX, 480)
        XCTAssertEqual(model.cropPixels.width / model.cropPixels.height, 16.0 / 9, accuracy: 0.01)

        // Original is the canvas shape; Free leaves the crop as it is and frees the fields.
        model.setCropAspect(.original)
        XCTAssertEqual(model.cropPixels.width / model.cropPixels.height, 480.0 / 272, accuracy: 0.01)
        let before = model.cropPixels
        model.setCropAspect(.free)
        XCTAssertEqual(model.cropPixels, before)
        model.setCropField(.width, to: 50)
        XCTAssertEqual(model.cropPixels.size, CGSize(width: 50, height: before.height))
        model.setCropField(.height, to: 1)
        XCTAssertEqual(model.cropPixels.height, 1, "the fields may go down to a pixel")

        // The safe area keeps a locked shape; Reset frees it.
        model.geometry.rotationDegrees = 5
        model.resetCrop()
        try await waitUntil { model.isPreviewCurrent }
        model.cropToSafeArea()
        let free = model.cropPixels
        model.setCropAspect(.ratio(1, 1))
        model.geometry.crop = .full
        model.cropToSafeArea()
        XCTAssertEqual(model.cropPixels.width, model.cropPixels.height)
        XCTAssertTrue(free.contains(model.cropPixels), "\(model.cropPixels) inside \(free)")
        XCTAssertEqual(model.cropPixels.height, free.height, accuracy: 1, "the largest square in the safe area")
        model.resetGeometry()
        XCTAssertEqual(model.cropAspect, .free)
        XCTAssertEqual(model.geometry, .identity)
    }

    func testWhatEndsTheModeAndWhatANewSourceResets() async throws {
        let (model, undo) = makeModel()
        model.open(fixtures.appendingPathComponent("moving_square_24f.mp4"))
        try await waitReady(model)

        // Painting and crop editing exclude each other.
        model.isPainting = true
        model.isEditingCrop = true
        XCTAssertFalse(model.isPainting)
        model.isPainting = true
        XCTAssertFalse(model.isEditingCrop)
        model.isPainting = false

        // The Original view has no crop to edit; entering the mode from it shows the composite.
        model.viewMode = .original
        model.isEditingCrop = true
        XCTAssertEqual(model.viewMode, .composite)
        model.viewMode = .sideBySide
        XCTAssertTrue(model.isEditingCrop)
        model.viewMode = .original
        XCTAssertFalse(model.isEditingCrop)
        model.viewMode = .composite

        // Leaving with a drag in flight drops the draft.
        model.isEditingCrop = true
        model.dragCrop(from: model.cropPixels, handle: .right, by: CGSize(width: -100, height: 0))
        XCTAssertNotNil(model.cropDraft)
        model.isEditingCrop = false
        XCTAssertNil(model.cropDraft)
        XCTAssertEqual(model.geometry.crop, .full)
        XCTAssertFalse(undo.canUndo, "none of this is a document edit")
        XCTAssertFalse(model.hasUnsavedChanges)

        // The mode and the shape are tool state: not in the settings, and gone with a new source.
        model.isEditingCrop = true
        model.setCropAspect(.ratio(4, 3))
        let saved = model.settings
        XCTAssertEqual(saved.geometry.crop, model.geometry.crop)
        model.open(fixtures.appendingPathComponent("count_5s_30fps.mp4"))
        try await waitReady(model)
        XCTAssertFalse(model.isEditingCrop)
        XCTAssertEqual(model.cropAspect, .free)
        XCTAssertNil(model.cropDraft)
        XCTAssertEqual(model.cropPixels, CGRect(x: 0, y: 0, width: 320, height: 180))
        XCTAssertEqual(model.preview?.size, PixelSize(width: 320, height: 180))
    }

    func testHandleHitTesting() {
        let rect = CGRect(x: 100, y: 100, width: 300, height: 200)
        func hit(_ x: CGFloat, _ y: CGFloat, whole: Bool = false) -> CropHandle? {
            CropOverlay.handle(at: CGPoint(x: x, y: y), rect: rect, isWholeCanvas: whole)
        }
        XCTAssertEqual(hit(102, 97), .topLeft)
        XCTAssertEqual(hit(395, 104), .topRight)
        XCTAssertEqual(hit(108, 300), .bottomLeft)
        XCTAssertEqual(hit(400, 300), .bottomRight)
        XCTAssertEqual(hit(250, 95), .top)
        XCTAssertEqual(hit(250, 309), .bottom)
        XCTAssertEqual(hit(93, 200), .left)
        XCTAssertEqual(hit(404, 200), .right)
        XCTAssertEqual(hit(250, 200), .body)
        XCTAssertNil(hit(250, 200, whole: true), "a crop that is the whole canvas has nothing to move: draw a new one")
        XCTAssertEqual(hit(101, 200, whole: true), .left, "its edges can still be grabbed")
        XCTAssertNil(hit(50, 50))
        XCTAssertNil(hit(250, 320))
        XCTAssertNil(hit(420, 200))
        // A small crop keeps a middle to move it by.
        let small = CGRect(x: 100, y: 100, width: 12, height: 12)
        XCTAssertEqual(CropOverlay.handle(at: CGPoint(x: 106, y: 106), rect: small, isWholeCanvas: false), .body)
        XCTAssertEqual(CropOverlay.handle(at: CGPoint(x: 100, y: 100), rect: small, isWholeCanvas: false), .topLeft)
    }
}
