import Foundation
import FrameStackCore

enum Format {
    static func seconds(_ s: Double) -> String {
        String(format: "%.3f s", s)
    }

    static func duration(_ s: Double) -> String {
        let total = max(0, s)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return minutes > 0 ? String(format: "%d:%06.3f", minutes, rest) : String(format: "%.3f s", rest)
    }

    static func fps(_ v: Double?) -> String {
        guard let v else { return "unknown" }
        return String(format: "%.3f fps (nominal)", v)
    }

    static func bytes(_ n: Int64?) -> String {
        guard let n else { return "–" }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
