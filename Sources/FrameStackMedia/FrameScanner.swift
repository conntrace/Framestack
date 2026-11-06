import AVFoundation
import CoreMedia
import Foundation
import FrameStackCore

public enum ScanMethod: String, Sendable, Equatable {
    /// Compressed samples read without decoding, mapped through the track's
    /// edit list. Fast.
    case sampleTable
    /// Every frame decoded; timestamps taken from decoder output. Slow but
    /// exact by construction. Used when the edit list cannot be mapped exactly.
    case decode
}

public enum ScanPreference: Sendable {
    /// Sample-table scan when the edit list maps exactly, otherwise decode.
    case automatic
    /// Always decode (reference behavior; used by tests to cross-check).
    case decodeOnly
}

public struct FrameScanResult: Sendable, Equatable {
    public let timeline: FrameTimeline
    public let method: ScanMethod
    /// Why the fast path was not used, if it was not.
    public let fallbackReason: String?
    /// Samples marked "do not display", skipped.
    public let nonDisplayedSamplesSkipped: Int
    /// Samples stored in the file but outside every edit-list segment, so
    /// never presented (e.g. a clip trimmed without re-encoding).
    public let samplesOutsideEdits: Int
    public let elapsedSeconds: Double
}

/// Finds the presentation timestamp of every frame the decoder will deliver,
/// so frame counts come from the stream rather than `duration × fps`.
///
/// Frame identity is the timestamp the *decoder* reports, which is in the
/// track's presentation timeline (edit list applied). Compressed samples are
/// stored in media time, so the fast path maps each sample through the
/// track's edit segments (`AVAssetTrack.segments`). If any segment changes
/// speed, an edit begins mid-frame, or the arithmetic would round, the scan
/// falls back to decoding every frame. See DECISIONS.md D-006.
public enum FrameScanner {
    public static func scan(
        _ source: VideoSourceInfo,
        preference: ScanPreference = .automatic,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> FrameScanResult {
        let started = Date()
        let asset = VideoSourceLoader.makeAsset(source.url)
        let track = try await VideoSourceLoader.videoTrack(of: asset, trackID: source.trackID)
        try Task.checkCancellation()

        var fallbackReason: String?
        if preference == .automatic {
            let segments = try await track.load(.segments)
            let table = try readSampleTable(asset: asset, track: track, progress: progress)
            switch mapThroughEdits(table.samples, segments: segments) {
            case let .exact(times, outside):
                progress?(times.count)
                return FrameScanResult(
                    timeline: FrameTimeline(presentationTimes: times),
                    method: .sampleTable,
                    fallbackReason: nil,
                    nonDisplayedSamplesSkipped: table.nonDisplayed,
                    samplesOutsideEdits: outside,
                    elapsedSeconds: Date().timeIntervalSince(started)
                )
            case let .needsDecode(reason):
                fallbackReason = reason
            }
        }

        let times = try decodeTimestamps(asset: asset, track: track, progress: progress)
        progress?(times.count)
        return FrameScanResult(
            timeline: FrameTimeline(presentationTimes: times),
            method: .decode,
            fallbackReason: fallbackReason,
            nonDisplayedSamplesSkipped: 0,
            samplesOutsideEdits: 0,
            elapsedSeconds: Date().timeIntervalSince(started)
        )
    }

    // MARK: Sample table

    struct RawSample {
        let mediaTime: CMTime
        let duration: CMTime
    }

    private static func startReader(_ asset: AVAsset, _ track: AVAssetTrack, settings: [String: Any]?) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaError.readerFailed(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaError.readerFailed("Cannot read samples from the video track.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.readerFailed(reader.error?.localizedDescription ?? "The reader could not start.")
        }
        return (reader, output)
    }

    private static func readSampleTable(
        asset: AVAsset,
        track: AVAssetTrack,
        progress: (@Sendable (Int) -> Void)?
    ) throws -> (samples: [RawSample], nonDisplayed: Int) {
        let (reader, output) = try startReader(asset, track, settings: nil)
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }
        var samples: [RawSample] = []
        var skipped = 0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let count = CMSampleBufferGetNumSamples(buffer)
            guard count > 0 else { continue }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[String: Any]]
            let timings = try sampleTimings(of: buffer, count: count)
            for (i, timing) in timings.enumerated() {
                if let attachments, i < attachments.count,
                   (attachments[i][kCMSampleAttachmentKey_DoNotDisplay as String] as? Bool) == true {
                    skipped += 1
                    continue
                }
                guard timing.presentationTimeStamp.isNumeric else { continue }
                samples.append(RawSample(mediaTime: timing.presentationTimeStamp, duration: timing.duration))
            }
            if samples.count % 500 == 0 { progress?(samples.count) }
        }
        if reader.status == .failed {
            throw MediaError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        return (samples, skipped)
    }

    private static func sampleTimings(of buffer: CMSampleBuffer, count: Int) throws -> [CMSampleTimingInfo] {
        if count == 1 {
            return [CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(buffer),
                presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer),
                decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(buffer)
            )]
        }
        var needed: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &needed)
        guard needed == count else {
            throw MediaError.readerFailed("Unexpected sample timing layout (\(needed) timings for \(count) samples).")
        }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: needed)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: needed, arrayToFill: &timings, entriesNeededOut: &needed)
        return timings
    }

    enum EditMapping: Equatable {
        case exact([FrameTime], outside: Int)
        case needsDecode(String)
    }

    /// Maps media-time samples into the presentation timeline.
    /// Only unscaled segments with frame-aligned starts are mapped; anything
    /// else returns `.needsDecode` so correctness never depends on guessing
    /// how the decoder treats unusual edits.
    static func mapThroughEdits(_ samples: [RawSample], segments: [AVAssetTrackSegment]) -> EditMapping {
        let active = segments.filter { !$0.isEmpty }
        if segments.isEmpty {
            return .exact(samples.compactMap { FrameTime($0.mediaTime) }, outside: 0)
        }
        guard !active.isEmpty else { return .needsDecode("The edit list has no media segments.") }
        for segment in active {
            let m = segment.timeMapping
            guard m.source.start.isNumeric, m.source.duration.isNumeric,
                  m.target.start.isNumeric, m.target.duration.isNumeric else {
                return .needsDecode("The edit list has non-numeric times.")
            }
            guard CMTimeCompare(m.source.duration, m.target.duration) == 0 else {
                return .needsDecode("The edit list changes playback speed.")
            }
        }

        var times: [FrameTime] = []
        times.reserveCapacity(samples.count)
        var outside = 0
        for sample in samples {
            var placed = false
            for segment in active {
                let source = segment.timeMapping.source
                let target = segment.timeMapping.target
                let sourceEnd = CMTimeRangeGetEnd(source)
                if CMTimeCompare(sample.mediaTime, source.start) >= 0, CMTimeCompare(sample.mediaTime, sourceEnd) < 0 {
                    let offset = CMTimeSubtract(sample.mediaTime, source.start)
                    let mapped = CMTimeAdd(offset, target.start)
                    guard !offset.flags.contains(.hasBeenRounded), !mapped.flags.contains(.hasBeenRounded),
                          let time = FrameTime(mapped) else {
                        return .needsDecode("Edit-list timing cannot be mapped exactly.")
                    }
                    times.append(time)
                    placed = true
                } else if CMTimeCompare(sample.mediaTime, source.start) < 0, sample.duration.isNumeric,
                          CMTimeCompare(CMTimeAdd(sample.mediaTime, sample.duration), source.start) > 0 {
                    return .needsDecode("An edit starts in the middle of a frame.")
                }
            }
            if !placed { outside += 1 }
        }
        return .exact(times, outside: outside)
    }

    // MARK: Decode

    private static func decodeTimestamps(
        asset: AVAsset,
        track: AVAssetTrack,
        progress: (@Sendable (Int) -> Void)?
    ) throws -> [FrameTime] {
        let (reader, output) = try startReader(asset, track, settings: CompositeRenderer.decodeSettings)
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }
        var times: [FrameTime] = []
        while true {
            try Task.checkCancellation()
            let done: Bool = autoreleasepool {
                guard let buffer = output.copyNextSampleBuffer() else { return true }
                if CMSampleBufferGetImageBuffer(buffer) != nil,
                   let time = FrameTime(CMSampleBufferGetPresentationTimeStamp(buffer)) {
                    times.append(time)
                    if times.count % 100 == 0 { progress?(times.count) }
                }
                return false
            }
            if done { break }
        }
        if reader.status == .failed {
            throw MediaError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        return times
    }
}
