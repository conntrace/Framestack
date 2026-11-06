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
    /// Container type as identified by ImageIO when reading back ("public.png", …).
    public let typeIdentifier: String?

    public var format: ExportFormat? {
        switch typeIdentifier {
        case UTType.png.identifier: return .png
        case UTType.jpeg.identifier: return .jpeg
        case UTType.tiff.identifier: return .tiff
        default: return nil
        }
    }
}

/// Writes composites to disk and verifies the result by reading it back.
///
/// Output color: the linear working image is converted by `PixelEncoder` —
/// optional sRGB→P3 matrix, clamp, sRGB transfer, round — and tagged with the
/// matching ICC profile (sRGB IEC 61966-2-1 or Display P3). RGB only.
public enum ImageExporter {
    public static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func cgColorSpace(_ space: OutputColorSpace) -> CGColorSpace {
        switch space {
        case .sRGB: return outputColorSpace
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
        }
    }

    /// Builds a CGImage (used for both export and the on-screen preview,
    /// so they share the exact same conversion).
    public static func makeCGImage(_ image: LinearImage, bitDepth: ExportBitDepth,
                                   colorSpace: OutputColorSpace = .sRGB) throws -> CGImage {
        let width = image.width
        let height = image.height
        let data: Data
        switch bitDepth {
        case .eight:
            data = Data(PixelEncoder.encode8(image, colorSpace: colorSpace))
        case .sixteen:
            // CoreGraphics' default byte order for 16-bit components is big-endian.
            let samples = PixelEncoder.encode16(image, colorSpace: colorSpace).map { $0.bigEndian }
            data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: bitDepth.rawValue,
                bitsPerPixel: bitDepth.rawValue * 3,
                bytesPerRow: width * 3 * (bitDepth.rawValue / 8),
                space: cgColorSpace(colorSpace),
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

    /// Writes an sRGB PNG (convenience for tests and tools).
    @discardableResult
    public static func writePNG(_ image: LinearImage, to url: URL, bitDepth: ExportBitDepth) throws -> ExportReport {
        try write(image, to: url, settings: ExportSettings(format: .png, bitDepth: bitDepth))
    }

    /// Writes the image in `settings.format` atomically (temp file + replace)
    /// and verifies dimensions, bit depth, container type and color profile
    /// by reading the file back. `settings.sizing` is not applied here: the
    /// caller renders at the output size (see `OutputSizing.maxLongEdge`).
    @discardableResult
    public static func write(_ image: LinearImage, to url: URL, settings: ExportSettings) throws -> ExportReport {
        guard image.alphaRange.lowerBound >= 0.999 else {
            throw MediaError.transparencyNotSupported
        }
        let bitDepth = settings.effectiveBitDepth
        let cgImage = try makeCGImage(image, bitDepth: bitDepth, colorSpace: settings.colorSpace)

        let type: UTType
        var properties: [CFString: Any] = [:]
        switch settings.format {
        case .png:
            type = .png
        case .jpeg:
            type = .jpeg
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(settings.jpegQuality, 0), 1)
        case .tiff:
            type = .tiff
            // LZW: lossless, supported for 16-bit samples by every reader we know of.
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
        }

        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type.identifier as CFString, 1, nil) else {
            throw MediaError.exportFailed("Cannot create a \(settings.format.displayName) file in \(directory.path).")
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temp)
            throw MediaError.exportFailed("Writing the \(settings.format.displayName) data failed.")
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
        guard report.format == settings.format else {
            throw MediaError.exportVerificationFailed("expected \(settings.format.displayName), file reads back as \(report.typeIdentifier ?? "unknown")")
        }
        let expectedProfile = settings.colorSpace == .displayP3 ? "Display P3" : "sRGB"
        guard let profile = report.colorProfileName, profile.localizedCaseInsensitiveContains(expectedProfile) else {
            throw MediaError.exportVerificationFailed("expected a \(expectedProfile) profile, file has \(report.colorProfileName ?? "none")")
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
        let type = CGImageSourceGetType(source) as String?
        return ExportReport(url: url, width: width, height: height, bitDepth: depth, colorProfileName: profile,
                            fileSizeBytes: size, typeIdentifier: type)
    }
}
