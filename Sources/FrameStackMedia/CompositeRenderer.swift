import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import FrameStackCore

public struct CompositeRequest: Sendable {
    public var source: MediaSource
    /// Presentation timestamps of the selected frames, ascending.
    public var frames: [FrameTime]
    public var blendMode: BlendMode
    /// 0…1; used only by modes where `blendMode.usesOpacity` is true.
    public var opacity: Float
    /// `nil` renders at native (display-oriented) resolution.
    public var maxLongEdge: Int?

    public init(source: MediaSource, frames: [FrameTime], blendMode: BlendMode, opacity: Float = 1, maxLongEdge: Int?) {
        self.source = source
        self.frames = frames
        self.blendMode = blendMode
        self.opacity = opacity
        self.maxLongEdge = maxLongEdge
    }

    public init(source: VideoSourceInfo, frames: [FrameTime], blendMode: BlendMode, opacity: Float = 1, maxLongEdge: Int?) {
        self.source = .video(source)
        self.frames = frames
        self.blendMode = blendMode
        self.opacity = opacity
        self.maxLongEdge = maxLongEdge
    }
}

public struct CompositeProgress: Sendable, Equatable {
    public let framesComposited: Int
    public let framesTotal: Int
}

/// A point where the decoder gave up (corrupt or unsupported data) and the
/// renderer restarted it after the damage.
public struct DecodeFailure: Sendable, Equatable {
    /// Last frame the decoder delivered before failing, if any.
    public let afterFrame: FrameTime?
    /// Selected frame the renderer resumed from.
    public let resumedAt: FrameTime
    public let message: String
}

public struct CompositeResult: Sendable {
    public let image: LinearImage
    public let framesComposited: Int
    /// Selected timestamps the decoder never delivered (e.g. corrupt data).
    /// The composite uses only the frames that were decoded; callers must
    /// surface this list to the user.
    public let missingFrames: [FrameTime]
    /// Decoder failures encountered and skipped. Empty for a healthy file.
    public let decodeFailures: [DecodeFailure]
    /// True when composited frames arrived in strictly increasing
    /// presentation order (relevant for order-dependent blend modes).
    public let deliveredInPresentationOrder: Bool
    public let elapsedSeconds: Double

    /// One-line explanation of why frames are missing, for the UI.
    public var decodeFailureSummary: String? {
        guard let first = decodeFailures.first else { return nil }
        let at = first.afterFrame.map { String(format: "after %.3f s", $0.seconds) } ?? "at the start of the selection"
        let more = decodeFailures.count > 1 ? " (+\(decodeFailures.count - 1) more)" : ""
        let gaveUp = decodeFailures.count >= CompositeRenderer.maxDecoderRestarts
            ? "; gave up after \(decodeFailures.count) decoder restarts — the file is badly damaged" : ""
        return "\(first.message) \(at)\(more)\(gaveUp)"
    }
}

/// Decodes the selected frames of a video and reduces them into a composite.
///
/// Pipeline per selected frame:
/// 1. AVAssetReader decodes the track (hardware decoder when available) to
///    32BGRA; the buffer keeps the source's color attachments.
/// 2. Core Image interprets the buffer using those attachments (YCbCr matrix,
///    primaries, transfer function), applies the display orientation, and
///    renders into **extended linear sRGB, Float32 RGBA** — FrameStack's
///    working space. Preview renders additionally apply a Lanczos downscale
///    (in linear light) before rendering.
/// 3. The frame is added to a streaming accumulator, then discarded.
///
/// Memory: one output-sized Float32 frame buffer + the accumulator; never
/// proportional to the number of frames. Rendering is cancellable between
/// frames via Swift task cancellation.
///
/// Damaged files: when the decoder fails part-way (AVAssetReader reports
/// `.failed`, e.g. "Cannot Decode" on an invalid NAL unit), the renderer
/// restarts a new reader at the next selected frame after the last one the
/// decoder delivered and keeps going. Frames that never decode are reported
/// in `missingFrames` with the reason in `decodeFailures`; they are never
/// replaced by a neighbouring frame. Each restart strictly advances, so the
/// loop terminates; it is additionally capped at `maxDecoderRestarts`.
public final class CompositeRenderer: @unchecked Sendable {
    public static let maxDecoderRestarts = 256
    /// 8-bit sources: 32BGRA (one quantisation by the decoder, D-009).
    static let decodeSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    /// 10-bit / HDR sources: half-float RGBA keeps the extra precision and
    /// values above SDR white (D-020).
    static let highPrecisionDecodeSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf
    ]

    /// Tests can force the 8-bit path to prove the difference.
    nonisolated(unsafe) static var forceEightBitDecode = false

    /// A track output in the best pixel format the reader accepts: half-float
    /// for >8-bit sources when available, else 32BGRA. `nil` if neither works.
    static func makeOutput(track: AVAssetTrack, highPrecision: Bool, reader: AVAssetReader) -> AVAssetReaderTrackOutput? {
        var candidates = [decodeSettings]
        if highPrecision, !forceEightBitDecode { candidates.insert(highPrecisionDecodeSettings, at: 0) }
        for settings in candidates {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) { return output }
        }
        return nil
    }

    public static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private let context: CIContext

    public init(useSoftwareRenderer: Bool = false) {
        context = CIContext(options: [
            .workingColorSpace: Self.workingColorSpace,
            .workingFormat: CIFormat.RGBAf,
            .cacheIntermediates: false,
            .useSoftwareRenderer: useSoftwareRenderer,
        ])
    }

    /// Everything the per-frame step needs; shared by the video and the
    /// image-sequence producers so both reduce frames identically.
    private final class Reduction {
        let request: CompositeRequest
        let wanted: Set<FrameTime>
        let total: Int
        var seen = Set<FrameTime>()
        var reducer: FrameReducer?
        var frameBuffer: [Float] = []
        var sourceSize: PixelSize?
        var outputSize = PixelSize(width: 0, height: 0)
        var previous: FrameTime?
        var inOrder = true
        var failures: [DecodeFailure] = []
        let progress: (@Sendable (CompositeProgress) -> Void)?

        init(request: CompositeRequest, progress: (@Sendable (CompositeProgress) -> Void)?) {
            self.request = request
            self.wanted = Set(request.frames)
            self.total = wanted.count
            self.progress = progress
        }

        var isComplete: Bool { seen.count == total }
    }

    public func render(
        _ request: CompositeRequest,
        progress: (@Sendable (CompositeProgress) -> Void)? = nil
    ) async throws -> CompositeResult {
        let started = Date()
        guard !request.frames.isEmpty else {
            throw MediaError.noFramesSelected
        }
        try Task.checkCancellation()
        let reduction = Reduction(request: request, progress: progress)

        switch request.source {
        case let .video(video):
            try await decodeVideo(video, into: reduction)
        case let .imageSequence(sequence):
            try decodeSequence(sequence, into: reduction)
        }
        try Task.checkCancellation()

        guard let reducer = reduction.reducer, reducer.count > 0 else {
            throw MediaError.noFramesDecoded
        }
        let image = try reducer.result()
        let missing = request.frames.filter { !reduction.seen.contains($0) }
        return CompositeResult(
            image: image,
            framesComposited: reducer.count,
            missingFrames: missing,
            decodeFailures: reduction.failures,
            deliveredInPresentationOrder: reduction.inOrder,
            elapsedSeconds: Date().timeIntervalSince(started)
        )
    }

    /// Orients, size-checks, resamples and reduces one upright frame.
    private func consume(_ image: CIImage, at pts: FrameTime, into r: Reduction) throws {
        let size = PixelSize(width: Int(image.extent.width.rounded()), height: Int(image.extent.height.rounded()))
        if let expected = r.sourceSize {
            guard expected == size else {
                throw MediaError.frameSizeChanged(expected: expected, actual: size)
            }
        } else {
            r.sourceSize = size
            r.outputSize = size.fitting(maxLongEdge: r.request.maxLongEdge)
            r.reducer = r.request.blendMode.makeReducer(
                width: r.outputSize.width, height: r.outputSize.height, opacity: r.request.opacity
            )
            r.frameBuffer = [Float](repeating: 0, count: r.outputSize.pixelCount * LinearImage.channelCount)
        }
        renderFrame(image, sourceSize: size, outputSize: r.outputSize, into: &r.frameBuffer)
        try r.frameBuffer.withUnsafeBufferPointer { try r.reducer!.add($0) }
        r.seen.insert(pts)
        if let previous = r.previous, !(previous < pts) { r.inOrder = false }
        r.previous = pts
        r.progress?(CompositeProgress(framesComposited: r.seen.count, framesTotal: r.total))
    }

    // MARK: Video

    private func decodeVideo(_ source: VideoSourceInfo, into r: Reduction) async throws {
        let request = r.request
        guard let first = request.frames.first, let last = request.frames.last else { return }
        let asset = VideoSourceLoader.makeAsset(source.url)
        let track = try await VideoSourceLoader.videoTrack(of: asset, trackID: source.trackID)
        try Task.checkCancellation()

        // Decode only the span containing the selection. The end is one tick
        // past the last selected timestamp, so that frame is included.
        let end = CMTimeAdd(last.cmTime, CMTime(value: 1, timescale: last.timescale))
        let orientation = CGImagePropertyOrientation(rawValue: UInt32(source.orientation.rawValue)) ?? .up
        var resumeFrom = first

        readers: while true {
            let (reader, output) = try makeReader(asset: asset, track: track, codec: source.codec, highPrecision: source.wantsHighPrecisionDecode,
                                                  from: resumeFrom.cmTime, to: end)
            defer {
                if reader.status == .reading { reader.cancelReading() }
            }
            /// Last timestamp the decoder delivered in this pass, wanted or not.
            var lastDelivered: FrameTime?

            while true {
                try Task.checkCancellation()
                let finished: Bool = try autoreleasepool {
                    guard let sample = output.copyNextSampleBuffer() else { return true }
                    guard let pts = FrameTime(CMSampleBufferGetPresentationTimeStamp(sample)) else { return false }
                    lastDelivered = pts
                    guard r.wanted.contains(pts), !r.seen.contains(pts),
                          let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                        return false
                    }
                    try consume(orientedImage(pixelBuffer, orientation: orientation), at: pts, into: r)
                    return r.isComplete
                }
                if finished { break }
            }

            guard reader.status == .failed else { break readers }

            // The decoder gave up. Skip past the damage: resume at the next
            // selected frame after the last one delivered (or after the
            // start of this pass if nothing was delivered). `next` is
            // strictly greater than the anchor, so every restart advances.
            let message = reader.error?.localizedDescription ?? "unknown error"
            let anchor = lastDelivered ?? resumeFrom
            guard r.failures.count < Self.maxDecoderRestarts,
                  let next = request.frames.first(where: { $0 > anchor && !r.seen.contains($0) }) else {
                if r.reducer == nil { throw MediaError.readerFailed(message) }
                r.failures.append(DecodeFailure(afterFrame: lastDelivered, resumedAt: last, message: message))
                break readers
            }
            r.failures.append(DecodeFailure(afterFrame: lastDelivered, resumedAt: next, message: message))
            resumeFrom = next
        }
    }

    // MARK: Image sequence

    /// Decodes each selected still in playback order. A file that cannot be
    /// decoded is reported as a decode failure and left out — never
    /// replaced by a neighbour.
    private func decodeSequence(_ sequence: ImageSequenceInfo, into r: Reduction) throws {
        for pts in r.request.frames {
            try Task.checkCancellation()
            guard let file = sequence.file(at: pts) else {
                r.failures.append(DecodeFailure(afterFrame: r.previous, resumedAt: pts,
                                                message: "\(pts) is not a frame time of this sequence"))
                continue
            }
            try autoreleasepool {
                guard let decoded = CIImage(contentsOf: file.url) else {
                    r.failures.append(DecodeFailure(afterFrame: r.previous, resumedAt: pts,
                                                    message: "\(file.fileName) could not be decoded"))
                    return
                }
                // Apply the EXIF orientation the loader read from the header
                // (the same value the inspector and the canvas size use).
                let orientation = CGImagePropertyOrientation(rawValue: UInt32(file.orientation)) ?? .up
                let image = orientation == .up ? decoded : decoded.oriented(orientation)
                let origin = image.extent.origin
                try consume(image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y)), at: pts, into: r)
            }
        }
    }

    private func makeReader(
        asset: AVAsset, track: AVAssetTrack, codec: String, highPrecision: Bool, from start: CMTime, to end: CMTime
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaError.readerFailed(error.localizedDescription)
        }
        reader.timeRange = CMTimeRange(start: start, end: end)
        guard let output = Self.makeOutput(track: track, highPrecision: highPrecision, reader: reader) else {
            throw MediaError.cannotDecode(codec: codec, reason: "No decoder output is available for this track.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.readerFailed(reader.error?.localizedDescription ?? "The reader could not start.")
        }
        return (reader, output)
    }

    private func orientedImage(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let origin = image.extent.origin
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    /// Renders an upright frame into `buffer` (Float32 RGBA, linear, row 0 at
    /// the top), resampling with Lanczos in linear light if the output size
    /// differs from the source size.
    private func renderFrame(_ image: CIImage, sourceSize: PixelSize, outputSize: PixelSize, into buffer: inout [Float]) {
        var image = image
        let bounds = CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
        if outputSize != sourceSize {
            let scaleY = CGFloat(outputSize.height) / CGFloat(sourceSize.height)
            let scaleX = CGFloat(outputSize.width) / CGFloat(sourceSize.width)
            image = image
                .clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scaleY,
                    kCIInputAspectRatioKey: scaleX / scaleY,
                ])
                .cropped(to: bounds)
        }
        buffer.withUnsafeMutableBytes { raw in
            context.render(
                image,
                toBitmap: raw.baseAddress!,
                rowBytes: outputSize.width * LinearImage.channelCount * MemoryLayout<Float>.stride,
                bounds: bounds,
                format: .RGBAf,
                colorSpace: Self.workingColorSpace
            )
        }
    }
}
