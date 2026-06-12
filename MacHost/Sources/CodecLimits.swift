/// Video codec used for the encode session and wire stream.
enum StreamCodec {
    case hevc
    case h264

    /// Wire id used in the codecSelected (type 10) message.
    var wireId: UInt8 {
        switch self {
        case .hevc: return 0
        case .h264: return 1
        }
    }
}

enum CodecLimits {
    /// Conservative floor every AVC hardware decoder meets (H.264 level 4.x).
    /// AVC-only devices are low-end; their real cap is at or above this.
    static let avcMaxWidth = 1920
    static let avcMaxHeight = 1088

    /// Scale (width, height) down to fit within the AVC limit, preserving
    /// aspect ratio, flooring each dimension to a multiple of 16 (codec
    /// macroblock alignment). Sizes already within the limit pass through
    /// unchanged so HEVC-era resolutions keep working verbatim.
    static func clampForAvc(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > avcMaxWidth || height > avcMaxHeight else {
            return (width, height)
        }
        let scale = min(Double(avcMaxWidth) / Double(width),
                        Double(avcMaxHeight) / Double(height))
        let w = max(16, Int((Double(width) * scale).rounded()) & ~15)
        let h = max(16, Int((Double(height) * scale).rounded()) & ~15)
        return (w, h)
    }
}
