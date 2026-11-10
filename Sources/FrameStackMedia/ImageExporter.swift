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
    /// The file carries an alpha channel.
    public let hasAlpha: Bool
    /// The composite had transparency but the format cannot store it; it
    /// was composited over black.
    public let alphaFlattened: Bool

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
    /// `alpha`: keep transparency as a straight alpha channel; otherwise the
    /// premultiplied colour is written as-is (= composited over black).
    public static func makeCGImage(_ image: LinearImage, bitDepth: ExportBitDepth,
                                   colorSpace: OutputColorSpace = .sRGB, alpha: Bool = false) throws -> CGImage {
        let width = image.width
        let height = image.height
        let channels = alpha ? 4 : 3
        let data: Data
        switch bitDepth {
        case .eight:
            data = Data(PixelEncoder.encode8(image, colorSpace: colorSpace, alpha: alpha))
        case .sixteen:
            // CoreGraphics' default byte order for 16-bit components is big-endian.
            let samples = PixelEncoder.encode16(image, colorSpace: colorSpace, alpha: alpha).map { $0.bigEndian }
            data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: bitDepth.rawValue,
                bitsPerPixel: bitDepth.rawValue * channels,
                bytesPerRow: width * channels * (bitDepth.rawValue / 8),
                space: cgColorSpace(colorSpace),
                bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last : CGImageAlphaInfo.none).rawValue),
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
        let transparent = Self.hasTransparency(image)
        let keepAlpha = transparent && settings.format != .jpeg
        let bitDepth = settings.effectiveBitDepth
        let cgImage = try makeCGImage(image, bitDepth: bitDepth, colorSpace: settings.colorSpace, alpha: keepAlpha)

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

        var report = try inspect(url)
        report = ExportReport(url: report.url, width: report.width, height: report.height, bitDepth: report.bitDepth,
                              colorProfileName: report.colorProfileName, fileSizeBytes: report.fileSizeBytes,
                              typeIdentifier: report.typeIdentifier, hasAlpha: report.hasAlpha, alphaFlattened: transparent && !keepAlpha)
        guard report.hasAlpha == keepAlpha else {
            throw MediaError.exportVerificationFailed(keepAlpha ? "the file lost its alpha channel" : "the file unexpectedly has an alpha channel")
        }
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
        let alpha = (props[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        return ExportReport(url: url, width: width, height: height, bitDepth: depth, colorProfileName: profile,
                            fileSizeBytes: size, typeIdentifier: type, hasAlpha: alpha, alphaFlattened: false)
    }

    /// Any pixel with alpha below 1 (within half an 8-bit step).
    public static func hasTransparency(_ image: LinearImage) -> Bool {
        image.alphaRange.lowerBound < 1 - 0.5 / 255
    }
}
