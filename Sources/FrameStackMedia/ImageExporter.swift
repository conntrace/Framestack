import CoreGraphics
import Foundation
import FrameStackCore
import ImageIO
import UniformTypeIdentifiers

/// What was actually written, as read back from the file.
public struct ExportReport: Sendable, Equatable {
    public let url: URL
    public let width: Int
    public let height: Int
    public let bitDepth: Int
    public let colorProfileName: String?
    public let fileSizeBytes: Int64
}

/// Writes composites to disk and verifies the result by reading it back.
///
/// Output color: the linear working image is converted to sRGB
/// (IEC 61966-2-1) by `PixelEncoder` — clamp, sRGB transfer, round — and
/// tagged with the sRGB ICC profile. RGB only (no alpha channel).
public enum ImageExporter {
    public static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Builds an sRGB CGImage (used for both export and the on-screen preview,
    /// so they share the exact same conversion).
    public static func makeCGImage(_ image: LinearImage, bitDepth: ExportBitDepth) throws -> CGImage {
        let width = image.width
        let height = image.height
        let data: Data
        switch bitDepth {
        case .eight:
            data = Data(PixelEncoder.encodeSRGB8(image))
        case .sixteen:
            // CoreGraphics' default byte order for 16-bit components is big-endian.
            let samples = PixelEncoder.encodeSRGB16(image).map { $0.bigEndian }
            data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: bitDepth.rawValue,
                bitsPerPixel: bitDepth.rawValue * 3,
                bytesPerRow: width * 3 * (bitDepth.rawValue / 8),
                space: outputColorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw MediaError.exportFailed("Could not create a \(bitDepth.rawValue)-bit RGB image.")
        }
        return cgImage
    }

    /// Writes a PNG atomically (temp file + replace) and verifies dimensions
    /// and bit depth by reading the file back.
    @discardableResult
    public static func writePNG(_ image: LinearImage, to url: URL, bitDepth: ExportBitDepth) throws -> ExportReport {
        guard image.alphaRange.lowerBound >= 0.999 else {
            throw MediaError.transparencyNotSupported
        }
        let cgImage = try makeCGImage(image, bitDepth: bitDepth)

        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MediaError.exportFailed("Cannot create a PNG file in \(directory.path).")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temp)
            throw MediaError.exportFailed("Writing the PNG data failed.")
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw MediaError.exportFailed(error.localizedDescription)
        }

        let report = try inspect(url)
        guard report.width == image.width, report.height == image.height else {
            throw MediaError.exportVerificationFailed("expected \(image.width)×\(image.height), file is \(report.width)×\(report.height)")
        }
        guard report.bitDepth == bitDepth.rawValue else {
            throw MediaError.exportVerificationFailed("expected \(bitDepth.rawValue)-bit, file is \(report.bitDepth)-bit")
        }
        return report
    }

    /// Reads an image file's header properties.
    public static func inspect(_ url: URL) throws -> ExportReport {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw MediaError.exportVerificationFailed("cannot read \(url.lastPathComponent)")
        }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let depth = (props[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 0
        let profile = props[kCGImagePropertyProfileName] as? String
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ExportReport(url: url, width: width, height: height, bitDepth: depth, colorProfileName: profile, fileSizeBytes: size)
    }
}
