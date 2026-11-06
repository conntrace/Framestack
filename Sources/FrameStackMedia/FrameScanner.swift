import AVFoundation
import CoreMedia
import Foundation
import FrameStackCore

public struct FrameScanResult: Sendable, Equatable {
    public let timeline: FrameTimeline
    /// Samples marked "do not display" (not presented by the decoder), skipped.
    public let nonDisplayedSamplesSkipped: Int
    public let elapsedSeconds: Double
}

/// Finds the presentation timestamp of every displayable video sample by
/// reading the track's compressed samples (no decoding), so frame counts come
/// from the stream itself rather than from `duration × fps`.
///
/// The scan uses the same `AVAssetReader` timeline as decoding, so the
/// timestamps here are exactly the ones decoded frames carry. Any selected
/// timestamp that later fails to decode is reported by the renderer as
/// missing — never silently replaced.
public enum FrameScanner {
    public static func scan(
        _ source: VideoSourceInfo,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> FrameScanResult {
        let started = Date()
        let asset = VideoSourceLoader.makeAsset(source.url)
        let track = try await VideoSourceLoader.videoTrack(of: asset, trackID: source.trackID)
        try Task.checkCancellation()

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaError.readerFailed(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaError.readerFailed("Cannot read samples from the video track.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.readerFailed(reader.error?.localizedDescription ?? "The reader could not start.")
        }
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        var times: [FrameTime] = []
        var skipped = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { continue }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            let pts = try presentationTimes(of: sample, count: count)
            for (i, time) in pts.enumerated() {
                if let attachments, i < attachments.count,
                   (attachments[i][kCMSampleAttachmentKey_DoNotDisplay as String] as? Bool) == true {
                    skipped += 1
                    continue
                }
                guard let t = FrameTime(time) else { continue }
                times.append(t)
            }
            if times.count % 250 == 0 { progress?(times.count) }
        }
        if reader.status == .failed {
            throw MediaError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        progress?(times.count)
        return FrameScanResult(
            timeline: FrameTimeline(presentationTimes: times),
            nonDisplayedSamplesSkipped: skipped,
            elapsedSeconds: Date().timeIntervalSince(started)
        )
    }

    private static func presentationTimes(of sample: CMSampleBuffer, count: Int) throws -> [CMTime] {
        if count == 1 {
            return [CMSampleBufferGetPresentationTimeStamp(sample)]
        }
        var needed: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &needed)
        guard needed == count else {
            throw MediaError.readerFailed("Unexpected sample timing layout (\(needed) timings for \(count) samples).")
        }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: needed)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: needed, arrayToFill: &timings, entriesNeededOut: &needed)
        return timings.map(\.presentationTimeStamp)
    }
}
