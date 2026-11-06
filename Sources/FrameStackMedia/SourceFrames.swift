import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import FrameStackCore

/// A small display-referred image of the source at a time, for the
/// filmstrip.
public struct TimelineThumbnail: @unchecked Sendable {
    /// The time the generator actually used (nearest decodable frame).
    public let time: FrameTime
    public let image: CGImage
}

/// Display-referred source frames via `AVAssetImageGenerator` — the same
/// decode + colour + display-transform path QuickTime Player uses (the
/// real-clip test showed it agrees with FrameStack's own pipeline within
/// 1/255). Used for the filmstrip and for viewing the original frame under
/// the playhead; compositing never goes through here.
public enum SourceFrames {
    /// `count` thumbnails spread evenly over the clip, each at most
    /// `maxHeight` tall, oriented for display. Frames that fail to decode
    /// are skipped. Fast: the generator may pick a nearby keyframe.
    public static func thumbnails(
        for source: VideoSourceInfo, timeline: FrameTimeline, count: Int, maxHeight: Int
    ) async throws -> [TimelineThumbnail] {
        guard count > 0, timeline.count > 0 else { return [] }
        let generator = makeGenerator(source)
        let scale = Double(maxHeight) / Double(source.displaySize.height)
        generator.maximumSize = CGSize(
            width: ceil(Double(source.displaySize.width) * scale),
            height: Double(maxHeight)
        )
        // Sample the middle of `count` equal bins so the first and last
        // thumbnails are not just the clip's first and last frames. The
        // generator may answer with any frame in the half-bin *before* the
        // requested time (a nearby keyframe is much cheaper than an exact
        // decode); the windows are disjoint, so thumbnails stay distinct and
        // ascending.
        let n = timeline.count
        let halfBin = max(source.duration.seconds / Double(count) / 2, 0.001)
        generator.requestedTimeToleranceBefore = CMTime(seconds: halfBin, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = .zero
        var times: [CMTime] = []
        for i in 0..<count {
            let index = min(n - 1, (2 * i + 1) * n / (2 * count))
            times.append(timeline.frames[index].cmTime)
        }

        var result: [TimelineThumbnail] = []
        for await item in generator.images(for: times) {
            try Task.checkCancellation()
            guard let image = try? item.image, let actual = try? item.actualTime,
                  let time = FrameTime(actual) else { continue }
            if let last = result.last, !(last.time < time) { continue }
            result.append(TimelineThumbnail(time: time, image: image))
        }
        return result
    }

    /// The exact frame at `time` (zero tolerance), oriented for display,
    /// optionally bounded to `maxLongEdge`. Throws if that frame cannot be
    /// produced.
    public static func frame(
        for source: VideoSourceInfo, at time: FrameTime, maxLongEdge: Int?
    ) async throws -> CGImage {
        let generator = makeGenerator(source)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maxLongEdge {
            let size = source.displaySize.fitting(maxLongEdge: maxLongEdge)
            generator.maximumSize = CGSize(width: size.width, height: size.height)
        }
        let (image, _) = try await generator.image(at: time.cmTime)
        return image
    }

    private static func makeGenerator(_ source: VideoSourceInfo) -> AVAssetImageGenerator {
        let asset = VideoSourceLoader.makeAsset(source.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .cleanAperture
        return generator
    }
}
