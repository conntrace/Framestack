import CoreGraphics
import FrameStackCore

// MARK: - Crop handles and shapes (M6j, PRD §6.2)

/// The side of the crop a number field edits.
enum CropFieldKind {
    case left, top, width, height
}

extension AppModel {
    var canEditCrop: Bool { source != nil && preview != nil }

    /// Width ÷ height the crop is held to, or nil when it is free.
    var cropAspectValue: Double? {
        canvasSize.flatMap { cropAspect.value(canvas: $0) }
    }

    /// The choices of the Shape menu: Free, Original, then the presets the
    /// way up the current choice is (landscape unless a portrait one is chosen).
    var cropAspectChoices: [CropAspect] {
        let portrait: Bool
        if case let .ratio(w, h) = cropAspect, h > w { portrait = true } else { portrait = false }
        let canvas = canvasSize ?? PixelSize(width: 1, height: 1)
        return [.free, .original] + CropAspect.presets.map { portrait ? $0.flipped(canvas: canvas) : $0 }
    }

    /// Chooses the shape and reshapes the crop to it (one undo step): same
    /// centre and area where the canvas allows. Free changes nothing.
    func setCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        guard let canvas = canvasSize, let value = aspect.value(canvas: canvas) else { return }
        setCropPixels(CropEditing.fit(cropPixels, toAspect: value, canvas: canvas))
    }

    var canFlipCropAspect: Bool {
        canvasSize.map { cropAspect.canFlip(canvas: $0) } ?? false
    }

    /// Landscape ↔ portrait for the locked shape.
    func flipCropAspect() {
        guard let canvas = canvasSize, canFlipCropAspect else { return }
        setCropAspect(cropAspect.flipped(canvas: canvas))
    }

    /// A handle (or the inside) of the crop dragged by `translation` canvas
    /// pixels from where the drag began on `start`. Nothing is committed
    /// until `endCropDrag`, so a drag is one undo step and the preview is
    /// not re-processed on the way.
    func dragCrop(from start: CGRect, handle: CropHandle, by translation: CGSize) {
        guard let canvas = canvasSize else { return }
        cropDraft = CropEditing.drag(start, handle: handle, by: translation, canvas: canvas, aspect: cropAspectValue)
    }

    /// A new crop dragged out between two canvas points (a drag that starts
    /// outside the current crop). Too small a drag leaves the crop alone.
    func drawCrop(from anchor: CGPoint, to point: CGPoint) {
        guard let canvas = canvasSize else { return }
        cropDraft = CropEditing.drawn(from: anchor, to: point, canvas: canvas, aspect: cropAspectValue)
    }

    func endCropDrag() {
        guard let draft = cropDraft, let canvas = canvasSize else { return }
        // A drag that ended where it began is not an edit (no undo step).
        guard draft != geometry.crop.pixelRect(in: canvas) else {
            cropDraft = nil
            return
        }
        pendingActionName = "Change Crop"
        setCropPixels(draft)
        pendingActionName = nil
    }

    func cancelCropDrag() {
        cropDraft = nil
    }

    /// A number field edited: with a locked shape the other side follows
    /// (width ↔ height) about the same top-left corner.
    func setCropField(_ field: CropFieldKind, to value: Int) {
        guard let canvas = canvasSize else { return }
        var rect = cropPixels
        let v = Double(value)
        switch field {
        case .left: rect.origin.x = v
        case .top: rect.origin.y = v
        case .width:
            rect.size.width = max(1, v)
            if let a = cropAspectValue { rect.size.height = max(1, (rect.width / a).rounded()) }
        case .height:
            rect.size.height = max(1, v)
            if let a = cropAspectValue { rect.size.width = max(1, (rect.height * a).rounded()) }
        }
        if let a = cropAspectValue, field == .width || field == .height {
            // Too big for the canvas from this corner: the largest of the shape that fits there.
            let x = min(max(rect.minX, 0), Double(canvas.width) - 1), y = min(max(rect.minY, 0), Double(canvas.height) - 1)
            let (w, h) = (min(rect.width, Double(canvas.width) - x), min(rect.height, Double(canvas.height) - y))
            if w < rect.width || h < rect.height {
                rect = CropEditing.inscribed(aspect: a, in: CGRect(x: x, y: y, width: w, height: h), canvas: canvas)
                rect.origin = CGPoint(x: x, y: y)
            }
        }
        setCropPixels(rect)
    }

    /// "1920×1080 · 16 : 9" for the crop read-outs.
    var cropSummary: String {
        let r = cropPixels
        let size = PixelSize(width: Int(r.width), height: Int(r.height))
        return CropAspect.name(for: size).map { "\(size) · \($0)" } ?? "\(size)"
    }
}
