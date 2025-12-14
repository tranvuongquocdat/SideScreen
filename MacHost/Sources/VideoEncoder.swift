import Foundation
import VideoToolbox
import CoreMedia

class VideoEncoder {
    private var compressionSession: VTCompressionSession?
    var onEncodedFrame: ((Data) -> Void)?

    init(width: Int, height: Int) {
        setupCompressionSession(width: width, height: height)
    }

    private func setupCompressionSession(width: Int, height: Int) {
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

        // Increase bitrate for better quality at 60fps
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 20_000_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [20_000_000, 1] as CFArray)

        // Frame rate settings
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber)

        // Critical for low latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)

        // Quality vs speed tradeoff - favor speed for low latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.7 as CFNumber)

        // Enable multi-threaded encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxH264SliceBytes, value: 1400 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
        print("✅ VideoToolbox encoder configured (H.265, 20Mbps, 60fps, low-latency)")
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    deinit {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
        }
    }
}

private let encodingOutputCallback: VTCompressionOutputCallback = { (outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer) in
    guard status == noErr,
          let sampleBuffer = sampleBuffer,
          let refcon = outputCallbackRefCon else {
        return
    }

    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()

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

    // Prepend SPS/PPS for keyframes
    var frameData = Data()

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
                    // Add start code
                    frameData.append(contentsOf: [0, 0, 0, 1])
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

        // Add start code
        frameData.append(contentsOf: [0, 0, 0, 1])

        // Add NAL unit data
        let nalPointer = UnsafeRawPointer(dataPointer.advanced(by: offset))
        frameData.append(nalPointer.assumingMemoryBound(to: UInt8.self), count: Int(nalLength))
        offset += Int(nalLength)
    }

    encoder.onEncodedFrame?(frameData)
}
