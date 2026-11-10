import Foundation
import FrameStackCore

/// The post-composite pipeline shared by the preview, single exports and
/// batches: colour first, then straighten/crop (PRD §10.1).
public enum PostProcessor {
    public static func apply(_ image: LinearImage, color: ColorAdjustments, geometry: GeometrySettings) throws -> LinearImage {
        try GeometryProcessor.apply(geometry, to: ColorProcessor.apply(color, to: image))
    }
}

/// One output of a batch: a full set of settings (the range is shared with
/// the document, sampling and everything else may differ) and how to write it.
public struct BatchVariant: Sendable, Equatable, Identifiable {
    /// Stable identity for the UI; also the label in the file name.
    public var id: String
    public var name: String
    public var settings: CompositeSettings
    public var export: ExportSettings

    public init(id: String? = nil, name: String, settings: CompositeSettings, export: ExportSettings) {
        self.id = id ?? name
        self.name = name
        self.settings = settings
        self.export = export
    }
}

public struct BatchPlan: Sendable {
    public var source: MediaSource
    public var timeline: FrameTimeline
    /// File-name stem shared by every output (the project or clip name).
    public var baseName: String
    public var folder: URL
    public var variants: [BatchVariant]

    public init(source: MediaSource, timeline: FrameTimeline, baseName: String, folder: URL, variants: [BatchVariant]) {
        self.source = source
        self.timeline = timeline
        self.baseName = baseName
        self.folder = folder
        self.variants = variants
    }
}

public enum BatchOutputStatus: Sendable, Equatable {
    case pending
    case rendering(done: Int, total: Int)
    case writing
    case finished(ExportReport, missingFrames: Int)
    case failed(String)
    case cancelled

    public var isFinal: Bool {
        switch self {
        case .finished, .failed, .cancelled: return true
        case .pending, .rendering, .writing: return false
        }
    }
}

public struct BatchOutput: Sendable, Equatable, Identifiable {
    public var variant: BatchVariant
    public var url: URL
    public var status: BatchOutputStatus
    /// Variants that share this output's decoded composite (same frames,
    /// blend, alignment, masks, weighting and size) are rendered once.
    public var sharesRenderWith: [String]
    public var id: String { variant.id }
}

public struct BatchSummary: Sendable, Equatable {
    public var outputs: [BatchOutput]
    /// Distinct compositing passes run (≤ outputs).
    public var rendersPerformed: Int
    public var elapsedSeconds: Double
    public var finishedCount: Int { outputs.filter { if case .finished = $0.status { return true } else { return false } }.count }
    public var failedCount: Int { outputs.filter { if case .failed = $0.status { return true } else { return false } }.count }
    public var cancelledCount: Int { outputs.filter { $0.status == .cancelled }.count }
}

/// Deterministic, collision-safe output names (PRD §9.3).
public enum BatchNaming {
    /// `"<base> <variant> <count>f[ <long edge>px].<ext>"` — the same scheme as a single export.
    public static func fileName(base: String, variant: String, frameCount: Int, longEdge: Int?, format: ExportFormat) -> String {
        let sizePart = longEdge.map { " \($0)px" } ?? ""
        return "\(base) \(variant) \(frameCount)f\(sizePart).\(format.fileExtension)"
    }

    /// Resolves each name against the folder and the other names of the
    /// batch: a name that is taken gets " 2", " 3", … before its extension.
    /// Given the same names and the same folder contents the result is the
    /// same, and no two outputs share a URL.
    public static func uniqueURLs(for names: [String], in folder: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [URL] {
        var taken = Set<String>()
        return names.map { name in
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            var candidate = name
            var n = 2
            while taken.contains(candidate.lowercased()) || exists(folder.appendingPathComponent(candidate)) {
                candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                n += 1
            }
            taken.insert(candidate.lowercased())
            return folder.appendingPathComponent(candidate)
        }
    }
}

/// Runs a batch: one compositing pass per distinct compositing part and
/// output size, every variant of that pass written from the same composite
/// (colour and geometry applied per variant), one pass at a time so memory
/// stays bounded by one output-sized composite. Cancelling the task stops
/// after the current frame; unwritten outputs become `.cancelled` and no
/// partial files are left (writes are atomic).
public struct BatchExporter: Sendable {
    public let renderer: CompositeRenderer

    public init(renderer: CompositeRenderer) {
        self.renderer = renderer
    }

    /// The outputs the plan would produce, with their final URLs, before anything runs.
    public static func outputs(for plan: BatchPlan, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [BatchOutput] {
        let native = plan.source.displaySize
        let names = plan.variants.map { v -> String in
            let count = (try? selection(for: v, in: plan).selectedCount) ?? 0
            let outputSize = v.settings.geometry.outputSize(for: v.export.sizing.outputSize(for: native))
            let showSize = v.export.sizing != .native || v.settings.geometry.hasTransform
            return BatchNaming.fileName(base: plan.baseName, variant: v.name, frameCount: count,
                                        longEdge: showSize ? outputSize.longEdge : nil, format: v.export.format)
        }
        let urls = BatchNaming.uniqueURLs(for: names, in: plan.folder, exists: exists)
        let keys = plan.variants.map { renderKey(for: $0, native: native) }
        return zip(plan.variants, urls).enumerated().map { i, pair in
            let shared = plan.variants.indices.filter { $0 != i && keys[$0] == keys[i] }.map { plan.variants[$0].id }
            return BatchOutput(variant: pair.0, url: pair.1, status: .pending, sharesRenderWith: shared)
        }
    }

    /// How many compositing passes the variants need (variants with the same
    /// compositing part and output size share one).
    public static func renderPassCount(for variants: [BatchVariant], native: PixelSize) -> Int {
        var keys: [RenderKey] = []
        for v in variants {
            let key = renderKey(for: v, native: native)
            if !keys.contains(key) { keys.append(key) }
        }
        return keys.count
    }

    public func run(_ plan: BatchPlan, onUpdate: @escaping @Sendable ([BatchOutput]) -> Void) async -> BatchSummary {
        let started = Date()
        var outputs = Self.outputs(for: plan)
        let native = plan.source.displaySize
        let keys = plan.variants.map { Self.renderKey(for: $0, native: native) }
        var renders = 0
        var done = Set<Int>()

        func publish() { onUpdate(outputs) }
        func setStatus(_ indices: [Int], _ status: BatchOutputStatus) {
            for i in indices { outputs[i].status = status }
        }

        for i in outputs.indices where !done.contains(i) {
            let group = outputs.indices.filter { !done.contains($0) && keys[$0] == keys[i] }
            group.forEach { done.insert($0) }
            if Task.isCancelled {
                setStatus(group, .cancelled)
                publish()
                continue
            }
            let variant = plan.variants[i]
            let selection: SamplingResult
            do {
                selection = try Self.selection(for: variant, in: plan)
            } catch {
                setStatus(group, .failed(error.localizedDescription))
                publish()
                continue
            }
            let request = CompositeRequest(
                source: plan.source,
                frames: selection.selectedTimes(in: plan.timeline),
                blendMode: variant.settings.blendMode,
                opacity: Float(variant.settings.opacity),
                maxLongEdge: variant.export.sizing.maxLongEdge(for: native),
                alignment: variant.settings.alignment,
                weighting: variant.settings.weighting,
                motionMask: variant.settings.motionMask,
                paintedMask: variant.settings.paintedMask,
                reverseOrder: variant.settings.reverseOrder
            )
            setStatus(group, .rendering(done: 0, total: request.frames.count))
            publish()
            let composite: CompositeResult
            do {
                renders += 1
                let progressBox = ProgressBox(indices: group, outputs: outputs, onUpdate: onUpdate)
                composite = try await renderer.render(request) { progress in progressBox.report(progress) }
                try Task.checkCancellation()
            } catch is CancellationError {
                setStatus(group, .cancelled)
                publish()
                continue
            } catch {
                setStatus(group, .failed(error.localizedDescription))
                publish()
                continue
            }
            for j in group {
                if Task.isCancelled {
                    outputs[j].status = .cancelled
                    publish()
                    continue
                }
                outputs[j].status = .writing
                publish()
                let v = plan.variants[j]
                let url = outputs[j].url
                do {
                    let report = try await Task.detached(priority: .userInitiated) {
                        try ImageExporter.write(try PostProcessor.apply(composite.image, color: v.settings.color, geometry: v.settings.geometry),
                                                to: url, settings: v.export)
                    }.value
                    outputs[j].status = .finished(report, missingFrames: composite.missingFrames.count)
                } catch {
                    outputs[j].status = .failed(error.localizedDescription)
                }
                publish()
            }
        }
        return BatchSummary(outputs: outputs, rendersPerformed: renders, elapsedSeconds: Date().timeIntervalSince(started))
    }

    /// Frames of a variant: the shared range sampled with the variant's own
    /// sampling choice and frame overrides (`CompositeSettings.selection`).
    static func selection(for variant: BatchVariant, in plan: BatchPlan) throws -> SamplingResult {
        try variant.settings.selection(in: plan.timeline)
    }

    struct RenderKey: Equatable {
        var compositing: CompositeSettings
        var maxLongEdge: Int?
    }

    static func renderKey(for variant: BatchVariant, native: PixelSize) -> RenderKey {
        RenderKey(compositing: variant.settings.compositingPart, maxLongEdge: variant.export.sizing.maxLongEdge(for: native))
    }

    /// Forwards render progress for every output of the group being rendered.
    private final class ProgressBox: @unchecked Sendable {
        let indices: [Int]
        let outputs: [BatchOutput]
        let onUpdate: @Sendable ([BatchOutput]) -> Void
        init(indices: [Int], outputs: [BatchOutput], onUpdate: @escaping @Sendable ([BatchOutput]) -> Void) {
            self.indices = indices
            self.outputs = outputs
            self.onUpdate = onUpdate
        }
        func report(_ progress: CompositeProgress) {
            var copy = outputs
            for i in indices { copy[i].status = .rendering(done: progress.framesComposited, total: progress.framesTotal) }
            onUpdate(copy)
        }
    }
}
