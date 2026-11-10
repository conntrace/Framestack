import Foundation

/// Writes a tiny uncompressed 16-bit **linear DNG** (demosaiced sensor data,
/// PhotometricInterpretation LinearRaw, DNG 1.4) so RAW decoding can be
/// tested without a camera file. The colour matrix is XYZ → linear sRGB and
/// the as-shot neutral is 1 1 1, so the stored values are linear sRGB light.
///
/// Measured on macOS 27: Apple's RAW decoder accepts such a file from
/// 256×192 up and refuses it at 128×96 and below (it then reads as a TIFF
/// with no images). Tests skip when the decoder refuses the file.
enum SyntheticDNG {
    /// Left half 18% grey; right half three bands, top to bottom: red,
    /// green, blue (0.5 with 0.05 in the other channels). `gain` scales it.
    static func patches(width: Int, height: Int, gain: Double = 1) -> (Int, Int) -> (Double, Double, Double) {
        { x, y in
            if x < width / 2 { return (0.18 * gain, 0.18 * gain, 0.18 * gain) }
            let band = min(2, y * 3 / height)
            let c: (Double, Double, Double) = band == 0 ? (0.5, 0.05, 0.05) : band == 1 ? (0.05, 0.5, 0.05) : (0.05, 0.05, 0.5)
            return (c.0 * gain, c.1 * gain, c.2 * gain)
        }
    }

    /// `pixel(x, y)` gives linear RGB in 0…1, y = 0 at the top as stored.
    static func write(to url: URL, width: Int, height: Int, orientation: Int = 1,
                      pixel: (Int, Int) -> (Double, Double, Double)) throws {
        var data = Data(capacity: width * height * 6)
        func u16(_ v: Double) -> UInt16 { UInt16((min(max(v, 0), 1) * 65535).rounded()) }
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                for v in [u16(r), u16(g), u16(b)] { data.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
            }
        }
        // (tag, type, count, little-endian value bytes)
        var entries: [(UInt16, UInt16, UInt32, Data)] = []
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func short(_ tag: UInt16, _ v: [UInt16]) { entries.append((tag, 3, UInt32(v.count), v.reduce(Data()) { $0 + le($1) })) }
        func long(_ tag: UInt16, _ v: [UInt32]) { entries.append((tag, 4, UInt32(v.count), v.reduce(Data()) { $0 + le($1) })) }
        func byte(_ tag: UInt16, _ v: [UInt8]) { entries.append((tag, 1, UInt32(v.count), Data(v))) }
        func ascii(_ tag: UInt16, _ s: String) { let d = Data(s.utf8) + [0]; entries.append((tag, 2, UInt32(d.count), d)) }
        func rational(_ tag: UInt16, _ v: [Double]) {
            entries.append((tag, 5, UInt32(v.count), v.reduce(Data()) { $0 + le(UInt32(($1 * 10000).rounded())) + le(UInt32(10000)) }))
        }
        func srational(_ tag: UInt16, _ v: [Double]) {
            entries.append((tag, 10, UInt32(v.count), v.reduce(Data()) { $0 + le(Int32(($1 * 10000).rounded())) + le(Int32(10000)) }))
        }
        long(254, [0]); long(256, [UInt32(width)]); long(257, [UInt32(height)])
        short(258, [16, 16, 16]); short(259, [1]); short(262, [34892])        // LinearRaw
        ascii(271, "FrameStack"); ascii(272, "Synthetic Linear")
        long(273, [0]); short(274, [UInt16(orientation)]); short(277, [3])
        long(278, [UInt32(height)]); long(279, [UInt32(data.count)]); short(284, [1])
        byte(50706, [1, 4, 0, 0]); byte(50707, [1, 1, 0, 0]); ascii(50708, "FrameStack Synthetic Linear")
        short(50714, [0, 0, 0]); short(50717, [65535, 65535, 65535])           // black / white level
        srational(50721, [3.2404542, -1.5371385, -0.4985314, -0.9692660, 1.8760108, 0.0415560,
                          0.0556434, -0.2040259, 1.0572252])                    // ColorMatrix1: XYZ → linear sRGB
        rational(50728, [1, 1, 1]); short(50778, [21])                          // AsShotNeutral, D65

        entries.sort { $0.0 < $1.0 }
        let extraOffset = 8 + 2 + 12 * entries.count + 4
        var extra = Data()
        var directory = Data()
        var stripSlot = 0
        for (tag, type, count, value) in entries {
            directory += le(tag) + le(type) + le(count)
            if tag == 273 { stripSlot = directory.count }
            if value.count <= 4 {
                directory += value + Data(count: 4 - value.count)
            } else {
                if extra.count % 2 == 1 { extra.append(0) }
                directory += le(UInt32(extraOffset + extra.count))
                extra += value
            }
        }
        if extra.count % 2 == 1 { extra.append(0) }
        directory.replaceSubrange(stripSlot..<stripSlot + 4, with: le(UInt32(extraOffset + extra.count)))
        var file = Data([0x49, 0x49]) + le(UInt16(42)) + le(UInt32(8)) + le(UInt16(entries.count))
        file += directory + le(UInt32(0)) + extra + data
        try file.write(to: url)
    }
}
