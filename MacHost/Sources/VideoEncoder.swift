import Foundation
import VideoToolbox
import CoreMedia

class VideoEncoder {
    private var compressionSession: VTCompressionSession?
    var onEncodedFrame: ((Data, UInt64, Bool) -> Void)?  // data, timestamp, isKeyframe
    private var width: Int
    private var height: Int
    private var bitrateMbps: Int = 20
    private var quality: String = "medium"
    private var gamingBoost: Bool = false
    private var frameRate: Int = 60
    private var forceNextKeyframe = false

    /// Force the next encoded frame to be a keyframe (call when client connects)
    func requestKeyframe() {
        forceNextKeyframe = true
        debugLog("🔑 Keyframe requested")
    }

    // Pre-allocated buffer for frame data (reduces allocations)
    private var frameBuffer = Data(capacity: 512 * 1024)  // 512KB initial
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    init(width: Int, height: Int, bitrateMbps: Int = 20, quality: String = "ultralow", gamingBoost: Bool = false, frameRate: Int = 60) {
        self.width = width
        self.height = height
        self.bitrateMbps = gamingBoost ? 50 : bitrateMbps
        self.quality = gamingBoost ? "ultralow" : quality
        self.gamingBoost = gamingBoost
        self.frameRate = frameRate
        setupCompressionSession()
    }

    func updateSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        self.bitrateMbps = gamingBoost ? 50 : bitrateMbps
        self.quality = gamingBoost ? "ultralow" : quality
        self.gamingBoost = gamingBoost

        // Drain pending frames before invalidation
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        setupCompressionSession()
    }

    private func setupCompressionSession() {
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC, // H.265
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodingOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("❌ Failed to create compression session: \(status)")
            return
        }

        compressionSession = session

        // Ultra-low latency config for real-time streaming
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)

        // Dynamic bitrate - remove strict rate limiting for smoother streaming
        let bitrateBps = bitrateMbps * 1_000_000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateBps as CFNumber)
        // Removed DataRateLimits - was causing bursty traffic and buffer stalls

        // Frame rate settings
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)

        // Keyframe interval: 0.5 second (balance between error recovery and bandwidth)
        // 1s was too long - when P-frames are lost, artifacts persist until next keyframe
        // 0.5s provides faster error recovery while avoiding bandwidth bursts of 0.1s
        let keyframeInterval = frameRate / 2  // 0.5 second (30 frames at 60fps)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 0.5 as CFNumber)

        // Critical for low latency - NO frame reordering (no B-frames)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // ALWAYS zero frame delay for real-time streaming (not just gaming boost)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)

        // Quality based on preset
        let qualityValue: Float
        if gamingBoost {
            qualityValue = 0.3  // Ultra low quality for maximum speed
        } else {
            qualityValue = switch quality {
            case "ultralow": 0.3  // Fastest encoding, lowest latency
            case "low": 0.5
            case "medium": 0.7
            case "high": 0.85
            default: 0.3  // Default to ultralow
            }
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: qualityValue as CFNumber)

        // Use VBR (variable bitrate) instead of CBR for burst capacity during fast scene changes
        // CBR causes over-quantization (blocky artifacts) when scene complexity spikes
        // Removed: kVTCompressionPropertyKey_ConstantBitRate

        VTCompressionSessionPrepareToEncodeFrames(session)

        let mode = gamingBoost ? "🎮 GAMING BOOST" : quality.uppercased()
        print("✅ VideoToolbox encoder configured (H.265, \(bitrateMbps)Mbps, \(frameRate)fps, \(mode))")
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        // Pass capture timestamp as refcon for accurate frame age tracking
        let captureNanos = UInt64(CMTimeGetSeconds(presentationTimeStamp) * 1_000_000_000)
        let refconValue = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        refconValue.storeBytes(of: captureNanos, as: UInt64.self)

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: refconValue,
            infoFlagsOut: nil
        )
    }

    /// Encode a CVPixelBuffer directly (used by CGDisplayStream capture)
    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let session = compressionSession else { return }

        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        let captureNanos = UInt64(CMTimeGetSeconds(presentationTimeStamp) * 1_000_000_000)
        let refconValue = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        refconValue.storeBytes(of: captureNanos, as: UInt64.self)

        var frameProps: CFDictionary?
        if forceNextKeyframe {
            forceNextKeyframe = false
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            debugLog("🔑 Forcing keyframe")
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: frameProps,
            sourceFrameRefcon: refconValue,
            infoFlagsOut: nil
        )
    }

    deinit {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }
}

// Static start code to avoid repeated allocations
private let nalStartCode: [UInt8] = [0, 0, 0, 1]

private let encodingOutputCallback: VTCompressionOutputCallback = { (outputCallbackRefCon, sourceFrameRefCon, status, _, sampleBuffer) in
    guard status == noErr,
          let sampleBuffer = sampleBuffer,
          let refcon = outputCallbackRefCon else {
        return
    }

    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()

    // Get timestamp for frame age tracking
    let timestamp: UInt64
    if let refcon = sourceFrameRefCon {
        timestamp = refcon.load(as: UInt64.self)
        refcon.deallocate()
    } else {
        timestamp = DispatchTime.now().uptimeNanoseconds
    }

    // Extract encoded data
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

    var lengthAtOffset: Int = 0
    var totalLength: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?

    let statusCode = CMBlockBufferGetDataPointer(
        dataBuffer,
        atOffset: 0,
        lengthAtOffsetOut: &lengthAtOffset,
        totalLengthOut: &totalLength,
        dataPointerOut: &dataPointer
    )

    guard statusCode == kCMBlockBufferNoErr,
          let dataPointer = dataPointer else {
        return
    }

    // Check if this is a keyframe
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

    // Pre-allocate estimated size to reduce reallocations
    let estimatedSize = totalLength + (isKeyframe ? 256 : 0) + 32
    var frameData = Data(capacity: estimatedSize)

    if isKeyframe {
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // Get parameter sets (SPS, PPS, VPS for H.265)
            var parameterSetCount: Int = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)

            for i in 0..<parameterSetCount {
                var parameterSetPointer: UnsafePointer<UInt8>?
                var parameterSetSize: Int = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &parameterSetPointer, parameterSetSizeOut: &parameterSetSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

                if let pointer = parameterSetPointer {
                    frameData.append(contentsOf: nalStartCode)
                    frameData.append(pointer, count: parameterSetSize)
                }
            }
        }
    }

    // Convert length-prefixed NAL units to Annex-B format (start codes)
    var offset = 0
    while offset < totalLength {
        // Read 4-byte length
        var nalLength: UInt32 = 0
        memcpy(&nalLength, dataPointer.advanced(by: offset), 4)
        nalLength = UInt32(bigEndian: nalLength)
        offset += 4

        // Add start code and NAL unit data
        frameData.append(contentsOf: nalStartCode)
        let nalPointer = UnsafeRawPointer(dataPointer.advanced(by: offset))
        frameData.append(nalPointer.assumingMemoryBound(to: UInt8.self), count: Int(nalLength))
        offset += Int(nalLength)
    }

    encoder.onEncodedFrame?(frameData, timestamp, isKeyframe)
}
