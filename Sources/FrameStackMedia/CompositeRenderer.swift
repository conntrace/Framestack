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
    /// Pre-blend registration (M5b); off by default.
    public var alignment: AlignmentSettings

    public init(source: MediaSource, frames: [FrameTime], blendMode: BlendMode, opacity: Float = 1, maxLongEdge: Int?,
                alignment: AlignmentSettings = .off) {
        self.source = source
        self.frames = frames
        self.blendMode = blendMode
        self.opacity = opacity
        self.maxLongEdge = maxLongEdge
        self.alignment = alignment
    }

    public init(source: VideoSourceInfo, frames: [FrameTime], blendMode: BlendMode, opacity: Float = 1, maxLongEdge: Int?,
                alignment: AlignmentSettings = .off) {
        self.init(source: .video(source), frames: frames, blendMode: blendMode, opacity: opacity, maxLongEdge: maxLongEdge,
                  alignment: alignment)
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
    /// Present when the request asked for alignment and more than one frame was selected.
    public let alignment: AlignmentReport?

    public init(image: LinearImage, framesComposited: Int, missingFrames: [FrameTime], decodeFailures: [DecodeFailure],
                deliveredInPresentationOrder: Bool, elapsedSeconds: Double, alignment: AlignmentReport? = nil) {
        self.image = image
        self.framesComposited = framesComposited
        self.missingFrames = missingFrames
        self.decodeFailures = decodeFailures
        self.deliveredInPresentationOrder = deliveredInPresentationOrder
        self.elapsedSeconds = elapsedSeconds
        self.alignment = alignment
    }

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
    private let registration = RegistrationEngine()

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
        var aligner: Aligner?

        init(request: CompositeRequest, progress: (@Sendable (CompositeProgress) -> Void)?) {
            self.request = request
            self.wanted = Set(request.frames)
            self.total = wanted.count
            self.progress = progress
        }

        var isComplete: Bool { seen.count == total }
    }

    /// Per-render alignment state: the reference at analysis size, the
    /// transforms found so far, and the running valid area.
    private final class Aligner {
        let settings: AlignmentSettings
        let referenceTime: FrameTime
        let reference: CGImage
        let analysisLongEdge: Int
        let key: RegistrationEngine.Key
        var outcomes: [FrameTime: RegistrationOutcome]
        var cachedCount = 0
        var failed: [FrameTime] = []
        var fellBack: [FrameTime] = []
        var aligned = 0
        var maxShift = 0.0
        /// Intersection of transformed frames, source pixels, CI coordinates.
        var validArea: CGRect?

        init(settings: AlignmentSettings, referenceTime: FrameTime, reference: CGImage, analysisLongEdge: Int,
             key: RegistrationEngine.Key, cached: [FrameTime: RegistrationOutcome]) {
            self.settings = settings
            self.referenceTime = referenceTime
            self.reference = reference
            self.analysisLongEdge = analysisLongEdge
            self.key = key
            self.outcomes = cached
        }

        var transforms: [FrameTime: AlignmentTransform] { outcomes.mapValues(\.transform) }
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
        if request.alignment.enabled, request.frames.count > 1 {
            reduction.aligner = try await makeAligner(for: request)
        }

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
        let alignmentFailures = Set(reduction.aligner?.failed ?? [])
        let missing = request.frames.filter { !reduction.seen.contains($0) && !alignmentFailures.contains($0) }
        var report: AlignmentReport?
        if let aligner = reduction.aligner, let sourceSize = reduction.sourceSize {
            registration.store(aligner.outcomes, for: aligner.key)
            // Valid area → output pixels, origin top-left.
            let sx = Double(reduction.outputSize.width) / Double(sourceSize.width)
            let sy = Double(reduction.outputSize.height) / Double(sourceSize.height)
            let area = aligner.validArea ?? CGRect(x: 0, y: 0, width: sourceSize.width, height: sourceSize.height)
            let valid = area.isNull ? CGRect.null : CGRect(
                x: area.minX * sx, y: (Double(sourceSize.height) - area.maxY) * sy,
                width: area.width * sx, height: area.height * sy
            )
            report = AlignmentReport(
                mode: aligner.settings.mode, referenceTime: aligner.referenceTime, analysisLongEdge: aligner.analysisLongEdge,
                alignedFrames: aligner.aligned, failedFrames: aligner.failed.sorted(), fallbackFrames: aligner.fellBack.sorted(),
                maxShiftPixels: aligner.maxShift,
                validArea: valid, fromCache: aligner.cachedCount > 0 && aligner.cachedCount >= aligner.aligned + aligner.failed.count,
                transforms: aligner.transforms.filter { reduction.seen.contains($0.key) || aligner.failed.contains($0.key) }
            )
        }
        return CompositeResult(
            image: image,
            framesComposited: reducer.count,
            missingFrames: missing,
            decodeFailures: reduction.failures,
            deliveredInPresentationOrder: reduction.inOrder,
            elapsedSeconds: Date().timeIntervalSince(started),
            alignment: report
        )
    }

    // MARK: Alignment

    /// Decodes the reference frame at analysis size (through the normal
    /// pipeline) and looks up transforms already computed for this
    /// source/reference/mode.
    private func makeAligner(for request: CompositeRequest) async throws -> Aligner? {
        guard let referenceTime = request.alignment.reference.resolve(in: request.frames) else { return nil }
        let analysisLongEdge = min(RegistrationEngine.analysisLongEdge, request.source.displaySize.longEdge)
        let single = CompositeRequest(source: request.source, frames: [referenceTime], blendMode: .normal,
                                      maxLongEdge: analysisLongEdge, alignment: .off)
        let decoded = try await render(single)
        guard decoded.framesComposited == 1 else { return nil }
        let reference = try ImageExporter.makeCGImage(decoded.image, bitDepth: .eight)
        let stamp: String
        switch request.source {
        case let .video(v): stamp = "\(v.fileSizeBytes ?? 0)"
        case let .imageSequence(s): stamp = "\(s.count)-\(s.totalFileSizeBytes)-\(s.framesPerSecond)-\(s.reversed)"
        }
        let key = RegistrationEngine.Key(sourcePath: request.source.url.path, sourceStamp: stamp,
                                         reference: referenceTime, mode: request.alignment.mode)
        let cached = registration.cached(key)
        let aligner = Aligner(settings: request.alignment, referenceTime: referenceTime, reference: reference,
                              analysisLongEdge: analysisLongEdge, key: key, cached: cached)
        aligner.cachedCount = request.frames.filter { cached[$0] != nil }.count
        return aligner
    }

    /// The frame as an 8-bit sRGB CGImage at analysis size (Lanczos in
    /// linear light, like the reference).
    private func analysisImage(_ image: CIImage, sourceSize: PixelSize, longEdge: Int) -> CGImage? {
        let target = sourceSize.fitting(maxLongEdge: longEdge)
        var scaled = image
        if target != sourceSize {
            let scaleY = CGFloat(target.height) / CGFloat(sourceSize.height)
            let scaleX = CGFloat(target.width) / CGFloat(sourceSize.width)
            scaled = image.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY])
        }
        let rect = CGRect(x: 0, y: 0, width: target.width, height: target.height)
        return context.createCGImage(scaled.cropped(to: rect), from: rect, format: .RGBA8, colorSpace: ImageExporter.outputColorSpace)
    }

    /// Returns the frame moved onto the reference, recording the transform,
    /// failures and the valid area — or nil when the frame could not be
    /// registered, in which case it is left out of the composite.
    private func aligned(_ image: CIImage, at pts: FrameTime, sourceSize: PixelSize, aligner: Aligner) -> CIImage? {
        let frameRect = CGRect(x: 0, y: 0, width: sourceSize.width, height: sourceSize.height)
        var transform: AlignmentTransform
        if pts == aligner.referenceTime {
            transform = .identity
            aligner.outcomes[pts] = RegistrationOutcome(transform: .identity)
        } else if let known = aligner.outcomes[pts] {
            if known.failed {
                aligner.failed.append(pts)
                return nil
            }
            if known.fellBack { aligner.fellBack.append(pts) }
            transform = known.transform
        } else if let target = analysisImage(image, sourceSize: sourceSize, longEdge: aligner.analysisLongEdge),
                  let shift = RegistrationEngine.register(target: target, reference: aligner.reference, mode: .translation),
                  RegistrationEngine.plausible(shift, in: CGRect(origin: .zero, size: CGSize(width: sourceSize.fitting(maxLongEdge: aligner.analysisLongEdge).width, height: sourceSize.fitting(maxLongEdge: aligner.analysisLongEdge).height))) {
            let factor = Double(sourceSize.longEdge) / Double(sourceSize.fitting(maxLongEdge: aligner.analysisLongEdge).longEdge)
            transform = shift.scaled(by: factor)
            if aligner.settings.mode == .perspective {
                // A homography is only trusted when it agrees with the plain
                // shift to within a few pixels; Vision's feature matching can
                // produce wild warps on low-detail or repetitive content.
                let analysisSize = sourceSize.fitting(maxLongEdge: aligner.analysisLongEdge)
                let rect = CGRect(x: 0, y: 0, width: analysisSize.width, height: analysisSize.height)
                let tolerance = max(4, 0.02 * Double(analysisSize.longEdge))
                if let warp = RegistrationEngine.register(target: target, reference: aligner.reference, mode: .perspective),
                   RegistrationEngine.agree(warp, shift, in: rect, tolerance: tolerance),
                   RegistrationEngine.plausible(warp, in: rect) {
                    transform = warp.scaled(by: factor)
                } else {
                    aligner.fellBack.append(pts)
                }
            }
            aligner.outcomes[pts] = RegistrationOutcome(transform: transform, fellBack: aligner.fellBack.contains(pts))
        } else {
            aligner.failed.append(pts)
            aligner.outcomes[pts] = RegistrationOutcome(transform: .identity, failed: true)
            return nil
        }
        if pts != aligner.referenceTime {
            aligner.aligned += 1
            aligner.maxShift = max(aligner.maxShift, transform.maxDisplacement(for: sourceSize))
        }
        let inner = transform.innerRect(of: frameRect)
        aligner.validArea = aligner.validArea.map { $0.intersection(inner) } ?? inner
        return transform.apply(to: image)
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
        var image = image
        if let aligner = r.aligner {
            guard let moved = aligned(image, at: pts, sourceSize: size, aligner: aligner) else {
                // Could not be registered: left out, reported, never stacked misaligned.
                r.progress?(CompositeProgress(framesComposited: r.seen.count, framesTotal: r.total))
                return
            }
            image = moved
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
            // Clamp so Lanczos has neighbours at the frame's own edges, then
            // crop back to the (scaled) frame so an aligned frame stays
            // transparent where it does not cover the canvas.
            let covered = image.extent.applying(CGAffineTransform(scaleX: scaleX, y: scaleY)).intersection(bounds)
            image = image
                .clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scaleY,
                    kCIInputAspectRatioKey: scaleX / scaleY,
                ])
                .cropped(to: covered)
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
