import AVFoundation
import CoreMedia
import Foundation
import FrameStackCore

public enum MediaError: Error, LocalizedError, Equatable {
    case fileNotFound(path: String)
    /// The file is an iCloud placeholder whose contents are not on this Mac.
    case notDownloaded(path: String)
    case unreadable(path: String, reason: String)
    case noVideoTrack(path: String)
    case unsupportedTransform(String)
    case cannotDecode(codec: String, reason: String)
    case readerFailed(String)
    case noFramesSelected
    case noFramesDecoded
    case frameSizeChanged(expected: PixelSize, actual: PixelSize)
    case transparencyNotSupported
    case exportFailed(String)
    case exportVerificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            return "The file “\((path as NSString).lastPathComponent)” could not be found."
        case let .notDownloaded(path):
            return "“\((path as NSString).lastPathComponent)” is stored in iCloud and has not been downloaded to this Mac. Download it in Finder first, then open it again."
        case let .unreadable(path, reason):
            return "“\((path as NSString).lastPathComponent)” is not a readable movie. \(reason)"
        case let .noVideoTrack(path):
            return "“\((path as NSString).lastPathComponent)” has no video track."
        case let .unsupportedTransform(description):
            return "This video uses a display transform FrameStack cannot apply yet (\(description)). Only 90° rotations and mirroring are supported."
        case let .cannotDecode(codec, reason):
            return "This Mac cannot decode the video (codec \(codec)). \(reason)"
        case let .readerFailed(reason):
            return "Reading the video failed: \(reason)"
        case .noFramesSelected:
            return "No frames are selected."
        case .noFramesDecoded:
            return "None of the selected frames could be decoded."
        case let .frameSizeChanged(expected, actual):
            return "Frame size changed inside the clip (\(expected) → \(actual)); mixed-size sources are not supported yet."
        case .transparencyNotSupported:
            return "The composite has transparent pixels; PNG export with alpha is not implemented yet."
        case let .exportFailed(reason):
            return "Export failed: \(reason)"
        case let .exportVerificationFailed(reason):
            return "The exported file did not verify: \(reason)"
        }
    }
}

public extension FrameTime {
    init?(_ time: CMTime) {
        guard time.isNumeric, time.timescale > 0 else { return nil }
        self.init(value: time.value, timescale: time.timescale)
    }

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
}

/// Everything FrameStack knows about a video before decoding frames.
public struct VideoSourceInfo: Sendable, Equatable {
    public let url: URL
    public let fileSizeBytes: Int64?
    public let trackID: Int32
    /// Size of the encoded pixel buffers (`naturalSize`).
    public let encodedSize: PixelSize
    /// Size after applying the track's display orientation.
    public let displaySize: PixelSize
    public let orientation: ImageOrientation
    /// Max of asset duration and video track end time.
    public let duration: FrameTime
    /// From the container; may be absent or inexact for variable-frame-rate
    /// footage. Display only — never used to count or select frames.
    public let nominalFrameRate: Double?
    public let codec: String
    public let colorPrimaries: String?
    public let transferFunction: String?
    public let yCbCrMatrix: String?
    public let isHDR: Bool
    /// Non-square pixel aspect ratio (h-spacing / v-spacing) if signalled.
    public let pixelAspectRatio: Double?
    /// Bits per component of the encoded video (8 for most clips, 10 for
    /// HEVC Main10 / HDR); nil when the container does not say.
    public let bitsPerComponent: Int?

    public var fileName: String { url.lastPathComponent }

    /// Sources with more than 8 bits are decoded to half-float RGBA so the
    /// extra precision reaches the compositor (DECISIONS.md D-009/D-020).
    public var wantsHighPrecisionDecode: Bool { (bitsPerComponent ?? 8) > 8 || isHDR }

    /// `duration × nominal fps`, clearly an estimate (PRD §4.1). Shown only
    /// until the timestamp scan has produced the actual count.
    public var estimatedFrameCount: Int? {
        guard let fps = nominalFrameRate, fps > 0 else { return nil }
        return Int((duration.seconds * fps).rounded())
    }

    /// Human-readable color tag summary.
    public var colorDescription: String {
        func short(_ s: String?) -> String {
            guard let s else { return "untagged" }
            return s.replacingOccurrences(of: "ITU_R_", with: "")
                .replacingOccurrences(of: "_", with: ".")
        }
        return "primaries \(short(colorPrimaries)), transfer \(short(transferFunction)), matrix \(short(yCbCrMatrix))"
    }

    /// Warnings about source properties M1 does not fully handle.
    public var warnings: [String] {
        var w: [String] = []
        if isHDR {
            w.append("HDR video: frames are decoded at full precision and composited in linear light relative to SDR white; highlights above white are clipped on export (no tone mapping yet).")
        }
        if let par = pixelAspectRatio, abs(par - 1) > 0.001 {
            w.append(String(format: "Non-square pixels (%.3f:1) are not corrected yet; output keeps the encoded pixel grid.", par))
        }
        return w
    }
}

public enum VideoSourceLoader {
    static func makeAsset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    /// Reads metadata and decodes one frame to prove the codec is supported
    /// on this Mac (the container extension alone guarantees nothing).
    public static func load(url: URL) async throws -> VideoSourceInfo {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw MediaError.fileNotFound(path: path)
        }
        // An iCloud placeholder (Desktop & Documents sync, iCloud Drive) looks
        // like a normal file but AVFoundation would block on the download —
        // possibly forever. Say so instead.
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = values.ubiquitousItemDownloadingStatus, status == .notDownloaded {
            throw MediaError.notDownloaded(path: path)
        }
        let asset = makeAsset(url)

        let duration: CMTime
        let track: AVAssetTrack
        do {
            let (isReadable, assetDuration) = try await asset.load(.isReadable, .duration)
            guard isReadable else {
                throw MediaError.unreadable(path: path, reason: "AVFoundation reports it as unreadable.")
            }
            duration = assetDuration
            guard let first = try await asset.loadTracks(withMediaType: .video).first else {
                throw MediaError.noVideoTrack(path: path)
            }
            track = first
        } catch let error as MediaError {
            throw error
        } catch {
            throw MediaError.unreadable(path: path, reason: error.localizedDescription)
        }

        let (naturalSize, transform, fps, formats, timeRange, characteristics) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions, .timeRange, .mediaCharacteristics
        )

        guard let orientation = ImageOrientation.fromVideoTransform(
            a: Double(transform.a), b: Double(transform.b), c: Double(transform.c), d: Double(transform.d)
        ) else {
            throw MediaError.unsupportedTransform(
                String(format: "a=%.3f b=%.3f c=%.3f d=%.3f", transform.a, transform.b, transform.c, transform.d)
            )
        }

        let encoded = PixelSize(width: Int(naturalSize.width.rounded()), height: Int(naturalSize.height.rounded()))

        var codec = "unknown"
        var primaries: String?
        var transfer: String?
        var matrix: String?
        var par: Double?
        var bits: Int?
        if let format = formats.first {
            codec = fourCCString(CMFormatDescriptionGetMediaSubType(format))
            let ext = (CMFormatDescriptionGetExtensions(format) as? [String: Any]) ?? [:]
            primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
            transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            matrix = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
            if let aspect = ext[kCMFormatDescriptionExtension_PixelAspectRatio as String] as? [String: Any],
               let h = (aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber)?.doubleValue,
               let v = (aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber)?.doubleValue,
               v > 0 {
                par = h / v
            }
            bits = (ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber)?.intValue
        }

        let trackEnd = CMTimeRangeGetEnd(timeRange)
        let total = (trackEnd.isNumeric && CMTimeCompare(trackEnd, duration) > 0) ? trackEnd : duration
        guard let totalDuration = FrameTime(total), totalDuration > .zero else {
            throw MediaError.unreadable(path: path, reason: "The video has no duration.")
        }

        let info = VideoSourceInfo(
            url: url,
            fileSizeBytes: (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value,
            trackID: track.trackID,
            encodedSize: encoded,
            displaySize: orientation.displaySize(forEncoded: encoded),
            orientation: orientation,
            duration: totalDuration,
            nominalFrameRate: fps > 0 ? Double(fps) : nil,
            codec: codec,
            colorPrimaries: primaries,
            transferFunction: transfer,
            yCbCrMatrix: matrix,
            isHDR: characteristics.contains(.containsHDRVideo),
            pixelAspectRatio: par,
            bitsPerComponent: bits
        )

        try probeDecode(asset: asset, track: track, codec: codec, highPrecision: info.wantsHighPrecisionDecode)
        return info
    }

    /// Decodes the first frame; throws `.cannotDecode` if that is impossible.
    static func probeDecode(asset: AVAsset, track: AVAssetTrack, codec: String, highPrecision: Bool) throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaError.cannotDecode(codec: codec, reason: error.localizedDescription)
        }
        guard let output = CompositeRenderer.makeOutput(track: track, highPrecision: highPrecision, reader: reader) else {
            throw MediaError.cannotDecode(codec: codec, reason: "No decoder output is available for this track.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.cannotDecode(codec: codec, reason: reader.error?.localizedDescription ?? "The reader could not start.")
        }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { return }
        }
        throw MediaError.cannotDecode(
            codec: codec,
            reason: reader.error?.localizedDescription ?? "No frame could be decoded."
        )
    }

    static func videoTrack(of asset: AVAsset, trackID: Int32) async throws -> AVAssetTrack {
        if let track = try await asset.loadTrack(withTrackID: CMPersistentTrackID(trackID)) {
            return track
        }
        throw MediaError.noVideoTrack(path: (asset as? AVURLAsset)?.url.path ?? "")
    }
}

func fourCCString(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let s = String(bytes: bytes, encoding: .ascii) {
        return s.trimmingCharacters(in: .whitespaces)
    }
    return String(format: "0x%08X", code)
}
