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
    /// Temporal weighting over the selection's timestamps (M6a); flat by default.
    public var weighting: WeightCurve
    /// Motion mask over a background (M6c); off by default.
    public var motionMask: MotionMaskSettings
    /// Painted mask (M6d); off by default. Shares the motion mask's background.
    public var paintedMask: PaintedMaskSettings
    /// Stack the frames last to first (M6h). `frames` stays ascending and
    /// weights stay attached to timestamps; only the order in which frames
    /// reach an order-dependent reducer changes. Ignored by modes where
    /// `blendMode.isOrderDependent` is false.
    public var reverseOrder: Bool

    public init(source: MediaSource, frames: [FrameTime], blendMode: BlendMode, opacity: Float = 1, maxLongEdge: Int?,
                alignment: AlignmentSettings = .off, weighting: WeightCurve = .flat, motionMask: MotionMaskSettings = .off,
                paintedMask: PaintedMaskSettings = .off, reverseOrder: Bool = false) {
        self.reverseOrder = reverseOrder
        self.source = source
        self.frames = frames
        self.blendMode = blendMode
        self.opacity = opacity
        self.maxLongEdge = maxLongEdge
        self.alignment = alignment
        self.weighting = weighting
        self.motionMask = motionMask
        self.paintedMask = paintedMask
    }

    public init(source: VideoSourceInfo, frames: [FrameTime], blendMode: BlendMode, opacity: Float = 1, maxLongEdge: Int?,
                alignment: AlignmentSettings = .off, weighting: WeightCurve = .flat, motionMask: MotionMaskSettings = .off,
                paintedMask: PaintedMaskSettings = .off, reverseOrder: Bool = false) {
        self.init(source: .video(source), frames: frames, blendMode: blendMode, opacity: opacity, maxLongEdge: maxLongEdge,
                  alignment: alignment, weighting: weighting, motionMask: motionMask, paintedMask: paintedMask,
                  reverseOrder: reverseOrder)
    }
}

public struct CompositeProgress: Sendable, Equatable {
    public let framesComposited: Int
    public let framesTotal: Int
    /// Multi-pass modes (Median) decode the source once per band.
    public let pass: Int
    public let passes: Int

    public init(framesComposited: Int, framesTotal: Int, pass: Int = 1, passes: Int = 1) {
        self.framesComposited = framesComposited
        self.framesTotal = framesTotal
        self.pass = pass
        self.passes = passes
    }
}

/// What the motion mask did.
public struct MotionMaskReport: Sendable, Equatable {
    /// "the median of 24 frames" or "frame 12 at 0.400 s".
    public let backgroundDescription: String
    public let threshold: Double
    /// Mean of the mask over all pixels and composited frames (0…1).
    public let meanCoverage: Double
    /// Pixels where no frame was ever masked in (they show the background only).
    public let backgroundOnlyFraction: Double
    public let inverted: Bool
    /// The motion (difference) mask was applied.
    public let motionActive: Bool
    /// Number of painted strokes applied (nil when the painted mask is off).
    public let paintedStrokes: Int?

    public var summary: String {
        var parts = ["Background: \(backgroundDescription)"]
        if motionActive { parts.append(String(format: "threshold %.2f", threshold)) }
        if let n = paintedStrokes { parts.append("\(n) painted stroke\(n == 1 ? "" : "s")") }
        parts.append(String(format: "blended pixels %.1f %% of frame·pixels", meanCoverage * 100))
        parts.append(String(format: "%.1f %% of the image is background only", backgroundOnlyFraction * 100))
        if inverted { parts.append("motion inverted") }
        return parts.joined(separator: " · ")
    }
}

/// How an exact Median was computed.
public struct MedianReport: Sendable, Equatable {
    public let passes: Int
    public let bandRows: Int
    public let memoryBudgetBytes: Int
    public let frameCount: Int

    public var summary: String {
        passes == 1
            ? "Exact median of \(frameCount) frames in one pass."
            : "Exact median of \(frameCount) frames in \(passes) passes of \(bandRows) rows (the clip was decoded \(passes) times to stay within \(ByteCountFormatter.string(fromByteCount: Int64(memoryBudgetBytes), countStyle: .memory)) of frame history)."
    }
}

/// How a video was decoded for reverse stacking: back to front in chunks,
/// each chunk decoded forward and held at output size before being stacked
/// last frame first.
public struct ReverseDecodeReport: Sendable, Equatable {
    public let chunks: Int
    /// Most output-size frames held in memory at once.
    public let framesPerChunk: Int
    public let memoryBudgetBytes: Int

    public var summary: String {
        chunks == 1
            ? "Stacked last to first; the whole selection was held in one chunk."
            : "Stacked last to first in \(chunks) chunks of up to \(framesPerChunk) frames (the decoder restarts once per chunk to stay within \(ByteCountFormatter.string(fromByteCount: Int64(memoryBudgetBytes), countStyle: .memory)) of held frames)."
    }
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
    /// True when the frames were stacked in the requested order: strictly
    /// increasing presentation time, or strictly decreasing when the request
    /// reversed an order-dependent mode (see `stackedInReverse`).
    public let deliveredInPresentationOrder: Bool
    /// The frames were stacked last to first (the request asked for it and
    /// the blend mode depends on order).
    public let stackedInReverse: Bool
    /// Reverse stacking of a video: how the clip was decoded back to front.
    public let reverseDecode: ReverseDecodeReport?
    public let elapsedSeconds: Double
    /// Present when the request asked for alignment and more than one frame was selected.
    public let alignment: AlignmentReport?
    /// Present when the request's weighting was not flat.
    public let weighting: WeightingReport?
    /// Present for the Median mode.
    public let median: MedianReport?
    /// Present when a motion mask was applied.
    public let motionMask: MotionMaskReport?
    /// With a motion mask: per-pixel mean mask value over the composited
    /// frames (0…1, output size) — where motion contributed.
    public let coverage: [Float]?

    public init(image: LinearImage, framesComposited: Int, missingFrames: [FrameTime], decodeFailures: [DecodeFailure],
                deliveredInPresentationOrder: Bool, elapsedSeconds: Double, alignment: AlignmentReport? = nil,
                weighting: WeightingReport? = nil, median: MedianReport? = nil, motionMask: MotionMaskReport? = nil,
                coverage: [Float]? = nil, stackedInReverse: Bool = false, reverseDecode: ReverseDecodeReport? = nil) {
        self.stackedInReverse = stackedInReverse
        self.reverseDecode = reverseDecode
        self.image = image
        self.framesComposited = framesComposited
        self.missingFrames = missingFrames
        self.decodeFailures = decodeFailures
        self.deliveredInPresentationOrder = deliveredInPresentationOrder
        self.elapsedSeconds = elapsedSeconds
        self.alignment = alignment
        self.weighting = weighting
        self.median = median
        self.motionMask = motionMask
        self.coverage = coverage
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

/// What temporal weighting did during a render.
public struct WeightingReport: Sendable, Equatable {
    public let preset: WeightPreset
    /// The blend mode ignores weights (Lighten / Darken).
    public let ignoredByMode: Bool
    /// Every raw weight was zero, so Flat was used.
    public let usedFlatFallback: Bool
    /// `1 / Σ w²` of the normalised weights over the *composited* frames.
    public let effectiveFrameCount: Double
    public let rawRange: ClosedRange<Double>

    public func summary(framesComposited: Int) -> String {
        if ignoredByMode { return "\(preset.displayName): this blend mode has no weights (per-channel extremum)." }
        if usedFlatFallback { return "Every weight was zero — Flat was used instead." }
        return String(format: "%@: raw weights %.2f…%.2f · worth %.1f equal frames of %d", preset.displayName,
                      rawRange.lowerBound, rawRange.upperBound, effectiveFrameCount, framesComposited)
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
    /// Frame-history budget for the Median's bands (`MedianPlan`).
    public let memoryBudgetBytes: Int

    public init(useSoftwareRenderer: Bool = false, memoryBudgetBytes: Int = MedianPlan.defaultMemoryBudgetBytes) {
        context = CIContext(options: [
            .workingColorSpace: Self.workingColorSpace,
            .workingFormat: CIFormat.RGBAf,
            .cacheIntermediates: false,
            .useSoftwareRenderer: useSoftwareRenderer,
        ])
        self.memoryBudgetBytes = memoryBudgetBytes
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
        /// Raw curve weight per selected frame (nil when flat).
        let weights: [FrameTime: Double]?
        let weightSelection: WeightedSelection?
        /// Output rows this pass reduces (nil = the whole frame).
        let band: Range<Int>?
        let passIndex: Int
        let passCount: Int
        var masker: Masker?
        /// Frames reach the reducer last to first.
        let reversed: Bool
        /// Prepared frames held for reverse stacking, not yet reduced.
        var pending = 0
        var reverseDecode: ReverseDecodeReport?

        init(request: CompositeRequest, progress: (@Sendable (CompositeProgress) -> Void)?,
             band: Range<Int>? = nil, passIndex: Int = 0, passCount: Int = 1) {
            self.request = request
            self.wanted = Set(request.frames)
            self.total = wanted.count
            self.progress = progress
            self.band = band
            self.passIndex = passIndex
            self.passCount = passCount
            self.reversed = request.reverseOrder && request.blendMode.isOrderDependent
            if request.weighting.isFlat {
                weights = nil
                weightSelection = nil
            } else {
                let selection = request.weighting.weights(for: request.frames)
                weightSelection = selection
                weights = Dictionary(uniqueKeysWithValues: zip(request.frames, selection.raw))
            }
        }

        var isComplete: Bool { seen.count == total }

        func reportProgress() {
            progress?(CompositeProgress(framesComposited: seen.count + pending, framesTotal: total, pass: passIndex + 1, passes: passCount))
        }
    }

    /// Per-render motion-mask state: the background at output size and the
    /// running coverage sums (shared across band passes).
    private final class Masker {
        /// Settings with feather/clean-up radii scaled from native canvas
        /// pixels to output pixels, so preview and export mask alike.
        let settings: MotionMaskSettings
        let background: LinearImage
        let description: String
        /// Painted mask at output size (nil when off).
        let painted: [Float]?
        let paintedStrokes: Int?
        var coverageSums: [Float]
        var framesMasked = 0

        init(settings: MotionMaskSettings, painted: PaintedMaskSettings, background: LinearImage, description: String, scale: Double) {
            var scaled = settings
            scaled.feather = Int((Double(settings.feather) * scale).rounded())
            scaled.cleanup = Int((Double(settings.cleanup) * scale).rounded())
            self.settings = scaled
            self.background = background
            self.description = description
            if painted.enabled {
                self.painted = PaintedMaskRasterizer.raster(painted, size: background.size)
                paintedStrokes = painted.strokes.count
            } else {
                self.painted = nil
                paintedStrokes = nil
            }
            coverageSums = [Float](repeating: 0, count: background.width * background.height)
        }
    }

    /// Renders the mask background at output size: the exact median of the
    /// selection, or one selected frame.
    private func makeMasker(for request: CompositeRequest) async throws -> Masker {
        let settings = request.motionMask
        var background: LinearImage
        var description: String
        if let t = settings.background.frameTime(in: request.frames) {
            let single = CompositeRequest(source: request.source, frames: [t], blendMode: .normal, maxLongEdge: request.maxLongEdge,
                                          alignment: request.alignment)
            background = try await render(single).image
            let index = request.frames.firstIndex(of: t) ?? 0
            description = String(format: "frame %d at %.3f s", index, t.seconds)
        } else {
            let median = CompositeRequest(source: request.source, frames: request.frames, blendMode: .median, maxLongEdge: request.maxLongEdge,
                                          alignment: request.alignment)
            background = try await render(median).image
            description = "the median of \(request.frames.count) frames"
        }
        // The background must be opaque for the final "over" to be opaque.
        if ImageExporter.hasTransparency(background) {
            background = GeometryProcessor.filled(background, with: SIMD3(0, 0, 0))
        }
        let scale = Double(background.size.longEdge) / Double(max(request.source.displaySize.longEdge, 1))
        return Masker(settings: settings, painted: request.paintedMask, background: background, description: description, scale: scale)
    }

    private func resetTallies(_ aligner: Aligner) {
        aligner.failed = []
        aligner.fellBack = []
        aligner.aligned = 0
        aligner.maxShift = 0
        aligner.validArea = nil
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
        var aligner: Aligner?
        if request.alignment.enabled, request.frames.count > 1 {
            aligner = try await makeAligner(for: request)
        }
        var masker: Masker?
        if request.motionMask.enabled || request.paintedMask.enabled {
            masker = try await makeMasker(for: request)
        }
        if request.blendMode.requiresFrameHistory {
            return try await renderInBands(request, aligner: aligner, masker: masker, progress: progress, started: started)
        }
        let reduction = Reduction(request: request, progress: progress)
        reduction.aligner = aligner
        reduction.masker = masker
        try await runPass(reduction)
        guard let reducer = reduction.reducer, reducer.count > 0 else {
            throw MediaError.noFramesDecoded
        }
        let image = try reducer.result()
        return finish(reduction, image: image, framesComposited: reducer.count, usesWeights: reducer.usesWeights,
                      missing: request.frames.filter { !reduction.seen.contains($0) }, started: started, median: nil)
    }

    /// Decodes the selection once into `reduction`'s reducer.
    private func runPass(_ reduction: Reduction) async throws {
        switch reduction.request.source {
        case let .video(video):
            try await decodeVideo(video, into: reduction)
        case let .imageSequence(sequence):
            try decodeSequence(sequence, into: reduction)
        }
        try Task.checkCancellation()
    }

    /// Exact Median: the output is split into horizontal bands whose whole
    /// frame history fits the memory budget (`MedianPlan`); the source is
    /// decoded once per band and each band's median is assembled into the
    /// final image. The alignment cache is shared across passes, so
    /// registration runs once.
    private func renderInBands(_ request: CompositeRequest, aligner: Aligner?, masker: Masker?,
                               progress: (@Sendable (CompositeProgress) -> Void)?, started: Date) async throws -> CompositeResult {
        let outputSize = request.source.displaySize.fitting(maxLongEdge: request.maxLongEdge)
        let plan = MedianPlan(outputSize: outputSize, frameCount: request.frames.count, memoryBudgetBytes: memoryBudgetBytes)
        var pixels = [Float](repeating: 0, count: outputSize.pixelCount * LinearImage.channelCount)
        var missing = Set<FrameTime>()
        var framesComposited = Int.max
        var last: Reduction?
        var usesWeights = true
        for pass in 0..<plan.passes {
            try Task.checkCancellation()
            let rows = plan.rows(ofPass: pass)
            let reduction = Reduction(request: request, progress: progress, band: rows, passIndex: pass, passCount: plan.passes)
            if let aligner { resetTallies(aligner) }
            reduction.aligner = aligner
            reduction.masker = masker
            try await runPass(reduction)
            guard let reducer = reduction.reducer, reducer.count > 0 else { throw MediaError.noFramesDecoded }
            guard reduction.outputSize == outputSize else {
                throw MediaError.frameSizeChanged(expected: outputSize, actual: reduction.outputSize)
            }
            let band = try reducer.result()
            let rowSamples = outputSize.width * LinearImage.channelCount
            band.pixels.withUnsafeBufferPointer { src in
                pixels.withUnsafeMutableBufferPointer { dst in
                    (dst.baseAddress! + rows.lowerBound * rowSamples).update(from: src.baseAddress!, count: rows.count * rowSamples)
                }
            }
            for f in request.frames where !reduction.seen.contains(f) { missing.insert(f) }
            framesComposited = min(framesComposited, reducer.count)
            usesWeights = reducer.usesWeights
            last = reduction
        }
        guard let reduction = last else { throw MediaError.noFramesDecoded }
        let image = LinearImage(width: outputSize.width, height: outputSize.height, pixels: pixels)
        let report = MedianReport(passes: plan.passes, bandRows: plan.bandRows, memoryBudgetBytes: plan.memoryBudgetBytes,
                                  frameCount: request.frames.count)
        return finish(reduction, image: image, framesComposited: framesComposited, usesWeights: usesWeights,
                      missing: request.frames.filter { missing.contains($0) }, started: started, median: report)
    }

    /// Assembles the result and its reports from the (last) pass.
    private func finish(_ reduction: Reduction, image: LinearImage, framesComposited: Int, usesWeights: Bool,
                        missing: [FrameTime], started: Date, median: MedianReport?) -> CompositeResult {
        let request = reduction.request
        let alignmentFailures = Set(reduction.aligner?.failed ?? [])
        let missing = missing.filter { !alignmentFailures.contains($0) }
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
        var weightingReport: WeightingReport?
        if let selection = reduction.weightSelection, let weights = reduction.weights {
            // Effective count over the frames that were actually composited.
            let used = request.frames.filter { reduction.seen.contains($0) }.map { weights[$0] ?? 0 }
            let sum = used.reduce(0, +)
            let effective = sum > 0 ? 1 / used.map { ($0 / sum) * ($0 / sum) }.reduce(0, +) : 0
            weightingReport = WeightingReport(
                preset: request.weighting.preset, ignoredByMode: !usesWeights,
                usedFlatFallback: selection.usedFlatFallback, effectiveFrameCount: effective, rawRange: selection.rawRange
            )
        }
        var finalImage = image
        var maskReport: MotionMaskReport?
        var coverage: [Float]?
        if let masker = reduction.masker, masker.background.size == image.size {
            finalImage = MaskOps.over(image, background: masker.background)
            let frames = max(masker.framesMasked / max(1, reduction.passCount), 1)
            var mean = 0.0, backgroundOnly = 0
            coverage = masker.coverageSums.map { $0 / Float(frames) }
            for c in coverage! {
                mean += Double(c)
                if c <= 0 { backgroundOnly += 1 }
            }
            let pixels = Double(max(coverage!.count, 1))
            maskReport = MotionMaskReport(backgroundDescription: masker.description, threshold: masker.settings.threshold,
                                          meanCoverage: mean / pixels, backgroundOnlyFraction: Double(backgroundOnly) / pixels,
                                          inverted: masker.settings.enabled && masker.settings.invert,
                                          motionActive: masker.settings.enabled, paintedStrokes: masker.paintedStrokes)
        }
        return CompositeResult(
            image: finalImage,
            framesComposited: framesComposited,
            missingFrames: missing,
            decodeFailures: reduction.failures,
            deliveredInPresentationOrder: reduction.inOrder,
            elapsedSeconds: Date().timeIntervalSince(started),
            alignment: report,
            weighting: weightingReport,
            median: median,
            motionMask: maskReport,
            coverage: coverage,
            stackedInReverse: reduction.reversed,
            reverseDecode: reduction.reverseDecode
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

    /// Prepares and reduces one upright frame (forward stacking).
    private func consume(_ image: CIImage, at pts: FrameTime, into r: Reduction) throws {
        guard try prepare(image, at: pts, into: r) else { return }
        try r.frameBuffer.withUnsafeBufferPointer { try reduce($0, at: pts, into: r) }
    }

    /// Size-checks, aligns, resamples and masks one upright frame into
    /// `r.frameBuffer`. Returns false when the frame is left out (it could
    /// not be registered).
    private func prepare(_ image: CIImage, at pts: FrameTime, into r: Reduction) throws -> Bool {
        let size = PixelSize(width: Int(image.extent.width.rounded()), height: Int(image.extent.height.rounded()))
        if let expected = r.sourceSize {
            guard expected == size else {
                throw MediaError.frameSizeChanged(expected: expected, actual: size)
            }
        } else {
            r.sourceSize = size
            r.outputSize = size.fitting(maxLongEdge: r.request.maxLongEdge)
            let rows = r.band?.count ?? r.outputSize.height
            if r.request.blendMode.requiresFrameHistory {
                r.reducer = MedianBandAccumulator(width: r.outputSize.width, height: rows, frameCapacity: r.total)
            } else {
                r.reducer = r.request.blendMode.makeReducer(width: r.outputSize.width, height: rows, opacity: r.request.opacity)
            }
            r.frameBuffer = [Float](repeating: 0, count: r.outputSize.width * rows * LinearImage.channelCount)
        }
        var image = image
        if let aligner = r.aligner {
            guard let moved = aligned(image, at: pts, sourceSize: size, aligner: aligner) else {
                // Could not be registered: left out, reported, never stacked misaligned.
                r.reportProgress()
                return false
            }
            image = moved
        }
        renderFrame(image, sourceSize: size, outputSize: r.outputSize, band: r.band, into: &r.frameBuffer)
        if let masker = r.masker {
            // Mask against the background's rows for this band, multiply the
            // frame by the mask, and accumulate coverage.
            let rows = r.band ?? 0..<r.outputSize.height
            let width = r.outputSize.width
            let bandPixels = width * rows.count
            let offset = rows.lowerBound * width * LinearImage.channelCount
            var mask: [Float]
            if masker.settings.enabled {
                mask = r.frameBuffer.withUnsafeBufferPointer { f in
                    masker.background.pixels.withUnsafeBufferPointer { b in
                        let slice = UnsafeBufferPointer(rebasing: b[offset..<(offset + bandPixels * LinearImage.channelCount)])
                        return MaskOps.mask(frame: f, background: slice, width: width, height: rows.count, settings: masker.settings)
                    }
                }
            } else {
                mask = [Float](repeating: 1, count: bandPixels)
            }
            if let painted = masker.painted {
                // The painted mask limits where any frame may blend.
                let base = rows.lowerBound * width
                for i in 0..<bandPixels { mask[i] *= painted[base + i] }
            }
            r.frameBuffer.withUnsafeMutableBufferPointer { MaskOps.apply(mask, to: $0) }
            let base = rows.lowerBound * width
            masker.coverageSums.withUnsafeMutableBufferPointer { c in
                for i in 0..<bandPixels { c[base + i] += mask[i] }
            }
            masker.framesMasked += 1
        }
        return true
    }

    /// Adds one prepared frame to the reducer and records it.
    private func reduce(_ frame: UnsafeBufferPointer<Float>, at pts: FrameTime, into r: Reduction) throws {
        if let weights = r.weights {
            // Average normalises Σw itself; Additive and the sequential modes
            // take the raw curve value; Lighten/Darken ignore it.
            try r.reducer!.add(frame, weight: weights[pts] ?? 1)
        } else {
            try r.reducer!.add(frame)
        }
        r.seen.insert(pts)
        if let previous = r.previous, !(r.reversed ? pts < previous : previous < pts) { r.inOrder = false }
        r.previous = pts
        r.reportProgress()
    }

    // MARK: Video

    private func decodeVideo(_ source: VideoSourceInfo, into r: Reduction) async throws {
        let frames = r.request.frames
        guard !frames.isEmpty else { return }
        let asset = VideoSourceLoader.makeAsset(source.url)
        let track = try await VideoSourceLoader.videoTrack(of: asset, trackID: source.trackID)
        try Task.checkCancellation()

        if r.reversed, frames.count > 1 {
            // A decoder only runs forward, so the selection is taken from the
            // end in chunks: each chunk is decoded forward, its prepared
            // (aligned, resampled, masked) frames are held at output size,
            // and then stacked last frame first. The chunk size keeps the
            // held frames within the memory budget; one frame always fits.
            let output = source.displaySize.fitting(maxLongEdge: r.request.maxLongEdge)
            let bytesPerFrame = max(1, output.pixelCount * LinearImage.channelCount * MemoryLayout<Float>.stride)
            let perChunk = max(1, min(frames.count, memoryBudgetBytes / bytesPerFrame))
            r.reverseDecode = ReverseDecodeReport(chunks: (frames.count + perChunk - 1) / perChunk, framesPerChunk: perChunk,
                                                  memoryBudgetBytes: memoryBudgetBytes)
            var upper = frames.count
            while upper > 0 {
                try Task.checkCancellation()
                let lower = max(0, upper - perChunk)
                var held: [(time: FrameTime, pixels: [Float])] = []
                held.reserveCapacity(upper - lower)
                try decodeSpan(of: source, asset: asset, track: track, frames: frames[lower..<upper], into: r) { image, pts in
                    if try self.prepare(image, at: pts, into: r) {
                        held.append((pts, r.frameBuffer))
                        r.pending += 1
                        r.reportProgress()
                    }
                }
                held.sort { $0.time < $1.time }
                while let frame = held.popLast() {
                    try Task.checkCancellation()
                    r.pending -= 1
                    try frame.pixels.withUnsafeBufferPointer { try reduce($0, at: frame.time, into: r) }
                }
                upper = lower
            }
        } else {
            try decodeSpan(of: source, asset: asset, track: track, frames: frames[...], into: r) { image, pts in
                try self.consume(image, at: pts, into: r)
            }
        }
        // Nothing at all could be decoded: report the decoder's own reason.
        if r.reducer == nil, let failure = r.failures.last {
            throw MediaError.readerFailed(failure.message)
        }
    }

    /// Decodes `frames` (ascending, non-empty) forward with one reader per
    /// undamaged stretch, handing each wanted frame to `deliver` once.
    private func decodeSpan(of source: VideoSourceInfo, asset: AVAsset, track: AVAssetTrack, frames: ArraySlice<FrameTime>,
                            into r: Reduction, deliver: (CIImage, FrameTime) throws -> Void) throws {
        guard let first = frames.first, let last = frames.last else { return }
        let wanted = Set(frames)
        var handled = Set<FrameTime>()

        // Decode only the span containing the frames. The end is one tick
        // past the last wanted timestamp, so that frame is included.
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
                    guard wanted.contains(pts), !handled.contains(pts),
                          let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                        return false
                    }
                    handled.insert(pts)
                    try deliver(orientedImage(pixelBuffer, orientation: orientation), pts)
                    return handled.count == wanted.count
                }
                if finished { break }
            }

            guard reader.status == .failed else { break readers }

            // The decoder gave up. Skip past the damage: resume at the next
            // wanted frame after the last one delivered (or after the start
            // of this pass if nothing was delivered). `next` is strictly
            // greater than the anchor, so every restart advances.
            let message = reader.error?.localizedDescription ?? "unknown error"
            let anchor = lastDelivered ?? resumeFrom
            guard r.failures.count < Self.maxDecoderRestarts,
                  let next = frames.first(where: { $0 > anchor && !handled.contains($0) }) else {
                r.failures.append(DecodeFailure(afterFrame: lastDelivered, resumedAt: last, message: message))
                break readers
            }
            r.failures.append(DecodeFailure(afterFrame: lastDelivered, resumedAt: next, message: message))
            resumeFrom = next
        }
    }

    // MARK: Image sequence

    /// Decodes each selected still in stacking order (playback order, or last
    /// to first when reversed). A file that cannot be decoded is reported as
    /// a decode failure and left out — never replaced by a neighbour.
    private func decodeSequence(_ sequence: ImageSequenceInfo, into r: Reduction) throws {
        let order = r.reversed ? Array(r.request.frames.reversed()) : r.request.frames
        for pts in order {
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
                var image = orientation == .up ? decoded : decoded.oriented(orientation)
                let origin = image.extent.origin
                image = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
                if file.pixelSize != sequence.displaySize, sequence.canvasPolicy != .strict {
                    // Fit/Fill onto the canvas (uniform scale, centred); the
                    // canvas extent is kept so coverage lands in alpha.
                    let (scale, offset) = sequence.placement(for: file.pixelSize)
                    let canvas = CGRect(x: 0, y: 0, width: sequence.displaySize.width, height: sequence.displaySize.height)
                    image = image.clampedToExtent()
                        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
                        .cropped(to: CGRect(x: 0, y: 0, width: Double(file.pixelSize.width) * scale, height: Double(file.pixelSize.height) * scale))
                        .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
                        .composited(over: CIImage(color: .clear).cropped(to: canvas))
                        .cropped(to: canvas)
                }
                try consume(image, at: pts, into: r)
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
    private func renderFrame(_ image: CIImage, sourceSize: PixelSize, outputSize: PixelSize, band: Range<Int>? = nil,
                             into buffer: inout [Float]) {
        var image = image
        let full = CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
        // A band is a row range from the top; Core Image's y axis points up.
        let bounds = band.map { CGRect(x: 0, y: outputSize.height - $0.upperBound, width: outputSize.width, height: $0.count) } ?? full
        if outputSize != sourceSize {
            let scaleY = CGFloat(outputSize.height) / CGFloat(sourceSize.height)
            let scaleX = CGFloat(outputSize.width) / CGFloat(sourceSize.width)
            // Clamp so Lanczos has neighbours at the frame's own edges, then
            // crop back to the (scaled) frame so an aligned frame stays
            // transparent where it does not cover the canvas.
            let covered = image.extent.applying(CGAffineTransform(scaleX: scaleX, y: scaleY)).intersection(full)
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
