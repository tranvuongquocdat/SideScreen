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

    /// Scale (width, height) down to fit within (maxWidth, maxHeight),
    /// preserving aspect ratio, flooring each dimension to a multiple of 16
    /// (codec macroblock alignment). Sizes already within the limit pass
    /// through unchanged.
    ///
    /// A source with the box's aspect ratio (a HiDPI capture of a panel-sized
    /// box, e.g. 5760x3600 into 2880x1800) fills the box exactly and gets the
    /// box itself. The box is a size the client checked against its decoder,
    /// so flooring it to 16 (2880x1800 -> 2880x1792) would only discard rows
    /// and force a rescale on panels whose sides are not multiples of 16.
    static func clamp(width: Int, height: Int, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        guard width > maxWidth || height > maxHeight else {
            return (width, height)
        }
        let scale = min(Double(maxWidth) / Double(width),
                        Double(maxHeight) / Double(height))
        let scaledWidth = Int((Double(width) * scale).rounded())
        let scaledHeight = Int((Double(height) * scale).rounded())
        if scaledWidth == maxWidth && scaledHeight == maxHeight {
            // Even sides: 4:2:0 chroma subsampling needs them.
            return (max(16, maxWidth & ~1), max(16, maxHeight & ~1))
        }
        let w = max(16, scaledWidth & ~15)
        let h = max(16, scaledHeight & ~15)
        return (w, h)
    }

    /// Conservative fallback for AVC clients that report no decoder limit.
    static func clampForAvc(width: Int, height: Int) -> (width: Int, height: Int) {
        clamp(width: width, height: height, maxWidth: avcMaxWidth, maxHeight: avcMaxHeight)
    }

    /// Frame rate the client measures its advertised limit at (mirrors
    /// CodecCapabilities.REFERENCE_FPS on Android).
    static let clientLimitReferenceFps = 60

    /// Frame rates a type-14 client measures its sustainable size at, in wire
    /// order (mirrors CodecCapabilities.TABLE_FPS on Android).
    static let tableFps = [30, 60, 120]

    /// The client's limit is a blocks-per-second budget expressed as a frame
    /// size at `clientLimitReferenceFps`. Streaming faster than that spends the
    /// same budget on more frames, so shrink the box's area by
    /// reference/fps (each side by the square root), keeping its aspect.
    /// Slower streams do not grow it: the panel bound still applies.
    static func scaleLimit(
        _ limit: (width: Int, height: Int),
        forFps fps: Int,
        referenceFps: Int = clientLimitReferenceFps
    ) -> (width: Int, height: Int) {
        guard fps > referenceFps, limit.width > 0, limit.height > 0 else { return limit }
        let k = (Double(referenceFps) / Double(fps)).squareRoot()
        let w = max(16, Int((Double(limit.width) * k).rounded()) & ~15)
        let h = max(16, Int((Double(limit.height) * k).rounded()) & ~15)
        return (w, h)
    }

    /// The ceiling to encode within at `fps`. With a per-rate table (type
    /// 14) it is the entry measured at the lowest rate at or above `fps`, and
    /// beyond the table's fastest rate that entry scaled down by area. A
    /// measured entry beats the single limit: that one is the smaller of the
    /// panel and the 60 fps budget, so scaling it for faster streams shrank
    /// panels whose decoder had budget to spare (issue #78). Without a table,
    /// the single limit scaled as before. Nil when the client reported nothing.
    static func budget(
        limit: (width: Int, height: Int)?,
        table: [Int: (width: Int, height: Int)]?,
        forFps fps: Int
    ) -> (width: Int, height: Int)? {
        if let table = table, !table.isEmpty {
            if let rate = table.keys.filter({ $0 >= fps }).min(), let entry = table[rate] {
                return entry
            }
            if let top = table.keys.max(), let entry = table[top] {
                return scaleLimit(entry, forFps: fps, referenceFps: top)
            }
        }
        return limit.map { scaleLimit($0, forFps: fps) }
    }

    /// Clamp into a client-reported ceiling, transposing the box when its
    /// orientation differs from the capture's. Clients report the ceiling in
    /// their panel's natural orientation, but it stands for a macroblock area
    /// budget, which is indifferent to which side is longer.
    static func clampToClientLimit(
        width: Int,
        height: Int,
        limit: (width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        let box = (height > width) == (limit.height > limit.width)
            ? limit
            : (width: limit.height, height: limit.width)
        return clamp(width: width, height: height, maxWidth: box.width, maxHeight: box.height)
    }
}
