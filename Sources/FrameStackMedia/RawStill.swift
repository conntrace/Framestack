import CoreGraphics
import CoreImage
import Foundation
import FrameStackCore

/// Camera RAW stills (PRD §4.2 "later exploration", D-035).
///
/// A RAW file holds sensor data, not a picture: something has to choose the
/// white balance, the tone curve and the gamut mapping. FrameStack uses
/// **Apple's default rendering** (`CIRAWFilter` with nothing changed: as-shot
/// white balance, default boost and tone, SDR, the same picture Preview and
/// Quick Look show) and offers no development controls. Which cameras decode
/// is whatever this version of macOS supports — there is no promise beyond
/// that; a file macOS cannot read is skipped and listed like any other.
public enum RawStill {
    /// Reduced decodes Apple's RAW pipeline does natively (demosaic at a
    /// fraction of the size). Measured on a 60 MP Sony ARW: a 1600 px
    /// preview decodes about 2× faster at 0.25 than at full size.
    static let decodeScales: [Double] = [0.125, 0.25, 0.5]

    /// The smallest native decode scale that still holds every pixel the
    /// output needs: `needed` is output long edge ÷ source long edge.
    public static func decodeScale(forOutputRatio needed: Double) -> Double {
        decodeScales.first { $0 >= needed } ?? 1
    }

    /// The default rendering in the file's **stored** orientation (the
    /// caller applies the header's orientation, as for every other still),
    /// with its origin at zero. At `decodeScale` 1 the extent is the stored
    /// size (for the cameras measured; a decoder that trims border pixels
    /// gives a slightly smaller one); below 1 it is about that fraction of
    /// it. Either way the picture covers the whole stored frame, so the
    /// compositor treats it as *representing* the stored size and resamples
    /// once, straight to the output. Nil when macOS cannot decode the file.
    public static func image(url: URL, decodeScale: Double = 1) -> CIImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        // CIRAWFilter would rotate the picture itself; CIImage(contentsOf:)
        // does not. Orientation is applied once, by the caller.
        filter.orientation = .up
        if decodeScale < 1 { filter.scaleFactor = Float(decodeScale) }
        guard let image = filter.outputImage, !image.extent.isInfinite, !image.extent.isEmpty else { return nil }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
