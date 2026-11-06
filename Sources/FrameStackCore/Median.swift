import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

// MARK: - Max / min luminance

/// Keeps, per pixel, the whole RGBA of the frame whose linear luminance
/// (Rec. 709 / sRGB primaries: 0.2126 R + 0.7152 G + 0.0722 B, on the
/// premultiplied values) is the greatest (or least) so far. Unlike
/// Lighten/Darken the result is always a colour some frame actually had at
/// that pixel. Ties keep the earlier frame. Order-independent otherwise.
public final class LuminanceExtremumReducer: FrameReducer {
    public enum Kind: Sendable { case maximum, minimum }

    public let width: Int
    public let height: Int
    public let kind: Kind
    public private(set) var count: Int = 0
    private var state: [Float]
    private var luminance: [Float]
    private var scratch: [Float]

    public static let coefficients: SIMD3<Float> = [0.2126, 0.7152, 0.0722]

    public init(width: Int, height: Int, kind: Kind) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        self.kind = kind
        state = [Float](repeating: 0, count: width * height * LinearImage.channelCount)
        luminance = [Float](repeating: 0, count: width * height)
        scratch = [Float](repeating: 0, count: width * height)
    }

    public var memoryFootprintBytes: Int { (state.count + luminance.count + scratch.count) * MemoryLayout<Float>.stride }
    public var usesWeights: Bool { false }

    public func add(_ frame: UnsafeBufferPointer<Float>) throws {
        try checkDimensions(frame)
        guard let src = frame.baseAddress else { return }
        let pixels = width * height
        let c = Self.coefficients
        // Luminance of the incoming frame.
        scratch.withUnsafeMutableBufferPointer { lum in
            let l = lum.baseAddress!
            #if canImport(Accelerate)
            var kr = c.x, kg = c.y, kb = c.z
            vDSP_vsmul(src, 4, &kr, l, 1, vDSP_Length(pixels))
            vDSP_vsma(src + 1, 4, &kg, l, 1, l, 1, vDSP_Length(pixels))
            vDSP_vsma(src + 2, 4, &kb, l, 1, l, 1, vDSP_Length(pixels))
            #else
            for p in 0..<pixels {
                let o = p * 4
                l[p] = c.x * src[o] + c.y * src[o + 1] + c.z * src[o + 2]
            }
            #endif
        }
        let isMax = kind == .maximum
        let first = count == 0
        state.withUnsafeMutableBufferPointer { stateBuffer in
            luminance.withUnsafeMutableBufferPointer { bestBuffer in
                scratch.withUnsafeBufferPointer { newBuffer in
                    let dst = stateBuffer.baseAddress!, best = bestBuffer.baseAddress!, new = newBuffer.baseAddress!
                    for p in 0..<pixels {
                        let take = first || (isMax ? new[p] > best[p] : new[p] < best[p])
                        if take {
                            let o = p * 4
                            dst[o] = src[o]; dst[o + 1] = src[o + 1]; dst[o + 2] = src[o + 2]; dst[o + 3] = src[o + 3]
                            best[p] = new[p]
                        }
                    }
                }
            }
        }
        count += 1
    }

    public func result() throws -> LinearImage {
        guard count > 0 else { throw CompositingError.noFrames }
        return LinearImage(width: width, height: height, pixels: state)
    }
}

// MARK: - Median

/// How an exact median is computed within a memory budget: the output is
/// split into horizontal bands small enough that every selected frame's
/// band fits in memory at once; the source is decoded once per band.
public struct MedianPlan: Sendable, Equatable {
    public let outputSize: PixelSize
    public let frameCount: Int
    public let memoryBudgetBytes: Int
    /// Rows per band (the last band may be shorter).
    public let bandRows: Int

    public static let defaultMemoryBudgetBytes = 1 << 30   // 1 GiB of Float32 frame history

    public init(outputSize: PixelSize, frameCount: Int, memoryBudgetBytes: Int = MedianPlan.defaultMemoryBudgetBytes) {
        self.outputSize = outputSize
        self.frameCount = max(frameCount, 1)
        self.memoryBudgetBytes = memoryBudgetBytes
        let bytesPerRowPerFrame = outputSize.width * LinearImage.channelCount * MemoryLayout<Float>.stride
        let rows = memoryBudgetBytes / max(1, bytesPerRowPerFrame * self.frameCount)
        bandRows = min(max(rows, 1), max(outputSize.height, 1))
    }

    public var passes: Int { (outputSize.height + bandRows - 1) / bandRows }

    /// Row range of pass `index`.
    public func rows(ofPass index: Int) -> Range<Int> {
        let start = index * bandRows
        return start..<min(start + bandRows, outputSize.height)
    }

    /// Bytes the band history actually takes.
    public var bandHistoryBytes: Int { bandRows * outputSize.width * LinearImage.channelCount * MemoryLayout<Float>.stride * frameCount }
}

/// Collects every frame's rows of one band, then computes the exact
/// per-channel median across frames (the mean of the two middle values for
/// an even count — the usual statistical median). Not streaming: this holds
/// `frameCount × bandPixels × 4` Float32 values, which is why
/// `MedianPlan` keeps bands small.
public final class MedianBandAccumulator: FrameReducer {
    public let width: Int
    public let height: Int
    public private(set) var count: Int = 0
    private let capacity: Int
    private var history: [Float]

    public init(width: Int, height: Int, frameCapacity: Int) {
        precondition(width > 0 && height > 0 && frameCapacity > 0)
        self.width = width
        self.height = height
        capacity = frameCapacity
        history = [Float](repeating: 0, count: width * height * LinearImage.channelCount * frameCapacity)
    }

    public var memoryFootprintBytes: Int { history.count * MemoryLayout<Float>.stride }
    public var usesWeights: Bool { false }

    public func add(_ frame: UnsafeBufferPointer<Float>) throws {
        try checkDimensions(frame)
        guard count < capacity else { throw CompositingError.historyFull(capacity: capacity) }
        guard let src = frame.baseAddress else { return }
        let n = sampleCount
        history.withUnsafeMutableBufferPointer { h in
            (h.baseAddress! + count * n).update(from: src, count: n)
        }
        count += 1
    }

    /// Per-sample median across the `count` frames added. Runs the pixels in
    /// parallel; each sample uses an O(n) selection on a small scratch copy.
    public func result() throws -> LinearImage {
        guard count > 0 else { throw CompositingError.noFrames }
        let n = sampleCount
        let frames = count
        var out = [Float](repeating: 0, count: n)
        history.withUnsafeBufferPointer { h in
            out.withUnsafeMutableBufferPointer { o in
                let hist = h.baseAddress!, dst = o.baseAddress!
                let chunk = 4096
                let chunks = (n + chunk - 1) / chunk
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    var values = [Float](repeating: 0, count: frames)
                    let lo = c * chunk, hi = min(lo + chunk, n)
                    values.withUnsafeMutableBufferPointer { v in
                        for s in lo..<hi {
                            for f in 0..<frames { v[f] = hist[f * n + s] }
                            dst[s] = Self.median(v)
                        }
                    }
                }
            }
        }
        return LinearImage(width: width, height: height, pixels: out)
    }

    /// Exact median of a buffer (modified in place): the middle value, or the
    /// mean of the two middle values when the count is even.
    static func median(_ v: UnsafeMutableBufferPointer<Float>) -> Float {
        let n = v.count
        guard n > 0 else { return 0 }
        if n == 1 { return v[0] }
        let upper = select(v, k: n / 2)
        if n % 2 == 1 { return upper }
        // The lower middle is the maximum of the elements left of k after selection.
        var lower = -Float.infinity
        for i in 0..<(n / 2) where v[i] > lower { lower = v[i] }
        return (lower + upper) / 2
    }

    /// Quickselect: after the call `v[k]` is the k-th smallest and everything
    /// before index k is ≤ it. NaNs are treated as the largest values.
    static func select(_ v: UnsafeMutableBufferPointer<Float>, k: Int) -> Float {
        var lo = 0, hi = v.count - 1
        while lo < hi {
            let pivot = v[(lo + hi) / 2]
            var i = lo, j = hi
            while i <= j {
                while less(v[i], pivot) { i += 1 }
                while less(pivot, v[j]) { j -= 1 }
                if i <= j { v.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { break }
        }
        return v[k]
    }

    @inline(__always)
    private static func less(_ a: Float, _ b: Float) -> Bool {
        if a.isNaN { return false }
        if b.isNaN { return true }
        return a < b
    }
}
