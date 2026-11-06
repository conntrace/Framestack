import CoreGraphics
import CoreImage
import Foundation
import FrameStackCore

/// Applies `GeometrySettings` to a finished composite: straighten (rotate
/// about the canvas centre, canvas size kept, corners become transparent),
/// crop, then edge fill. One resample on the final image instead of one per
/// frame — identical for preview and export because both go through here.
public enum GeometryProcessor {
    private static let context = CIContext(options: [
        .workingColorSpace: CompositeRenderer.workingColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false,
    ])

    public static func apply(_ geometry: GeometrySettings, to image: LinearImage) throws -> LinearImage {
        var result = image
        if geometry.rotationDegrees != 0 || !geometry.crop.isFull {
            result = try transform(result, rotationDegrees: geometry.rotationDegrees, crop: geometry.crop)
        }
        if let fill = geometry.edgeFill.linearColor, ImageExporter.hasTransparency(result) {
            result = filled(result, with: fill)
        }
        return result
    }

    /// Rotate (counter-clockwise on screen) about the canvas centre, then crop.
    static func transform(_ image: LinearImage, rotationDegrees: Double, crop: NormalizedRect) throws -> LinearImage {
        let canvas = image.size
        let cropPixels = crop.clamped(in: canvas).pixelRect(in: canvas)
        let outWidth = Int(cropPixels.width), outHeight = Int(cropPixels.height)
        guard outWidth > 0, outHeight > 0 else { throw MediaError.exportFailed("The crop is empty.") }

        var ci = ciImage(image)
        if rotationDegrees != 0 {
            // Core Image's y axis points up, so a positive (counter-clockwise
            // on screen) angle is a positive rotation here as well.
            let angle = rotationDegrees * .pi / 180
            let center = CGPoint(x: Double(canvas.width) / 2, y: Double(canvas.height) / 2)
            let t = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
                .translatedBy(x: -center.x, y: -center.y)
            ci = ci.transformed(by: t)
        }
        // Crop rectangle in Core Image coordinates (flip y).
        let rect = CGRect(x: cropPixels.minX, y: Double(canvas.height) - cropPixels.maxY,
                          width: cropPixels.width, height: cropPixels.height)
        ci = ci.cropped(to: rect)
        var pixels = [Float](repeating: 0, count: outWidth * outHeight * LinearImage.channelCount)
        pixels.withUnsafeMutableBytes { raw in
            context.render(ci, toBitmap: raw.baseAddress!, rowBytes: outWidth * LinearImage.channelCount * MemoryLayout<Float>.stride,
                           bounds: rect, format: .RGBAf, colorSpace: CompositeRenderer.workingColorSpace)
        }
        return LinearImage(width: outWidth, height: outHeight, pixels: pixels)
    }

    /// Composites the (premultiplied) image over an opaque colour.
    static func filled(_ image: LinearImage, with color: SIMD3<Float>) -> LinearImage {
        var pixels = image.pixels
        let n = image.width * image.height
        pixels.withUnsafeMutableBufferPointer { p in
            for i in 0..<n {
                let o = i * LinearImage.channelCount
                let a = p[o + 3]
                if a < 1 {
                    let k = 1 - max(a, 0)
                    p[o] += color.x * k
                    p[o + 1] += color.y * k
                    p[o + 2] += color.z * k
                    p[o + 3] = 1
                }
            }
        }
        return LinearImage(width: image.width, height: image.height, pixels: pixels)
    }

    /// A CIImage over the image's float pixels (row 0 at the top, so the
    /// image is flipped into Core Image's bottom-up space).
    static func ciImage(_ image: LinearImage) -> CIImage {
        let data = image.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let ci = CIImage(bitmapData: data, bytesPerRow: image.width * LinearImage.channelCount * MemoryLayout<Float>.stride,
                         size: CGSize(width: image.width, height: image.height), format: .RGBAf,
                         colorSpace: CompositeRenderer.workingColorSpace)
        return ci
    }
}
