import Foundation
import VideoToolbox
import CoreMedia

/// Minimal H.265 encoder for testing - same config as SideScreen's VideoEncoder
class TestEncoder {
    private var session: VTCompressionSession?
    var onEncodedFrame: ((Data, Bool) -> Void)?  // data, isKeyframe
    private let width: Int
    private let height: Int
    private let frameRate: Int
    private var forceNextKeyframe = false

    init(width: Int, height: Int, frameRate: Int = 60, bitrateMbps: Int = 20) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        setupSession(bitrateMbps: bitrateMbps)
    }

    func requestKeyframe() {
        forceNextKeyframe = true
    }

    private func setupSession(bitrateMbps: Int) {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: testEncodingCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("[FAIL] VTCompressionSessionCreate failed: \(status)")
            return
        }

        self.session = session

        // Same settings as SideScreen's VideoEncoder
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: (bitrateMbps * 1_000_000) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)

        let keyframeInterval = frameRate / 2  // 0.5 second
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 0.5 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.5 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
        print("[OK] H.265 encoder created: \(width)x\(height) @ \(frameRate)fps, \(bitrateMbps)Mbps")
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let session = session else { return }

        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        var frameProps: CFDictionary? = nil
        if forceNextKeyframe {
            forceNextKeyframe = false
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            print("  [KEYFRAME] Forcing keyframe")
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    deinit {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }
}

// NAL start code
private let nalStartCode: [UInt8] = [0, 0, 0, 1]

private let testEncodingCallback: VTCompressionOutputCallback = { (refcon, _, status, _, sampleBuffer) in
    guard status == noErr,
          let sampleBuffer = sampleBuffer,
          let refcon = refcon else { return }

    let encoder = Unmanaged<TestEncoder>.fromOpaque(refcon).takeUnretainedValue()

    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

    var lengthAtOffset: Int = 0
    var totalLength: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?

    let statusCode = CMBlockBufferGetDataPointer(
        dataBuffer, atOffset: 0,
        lengthAtOffsetOut: &lengthAtOffset,
        totalLengthOut: &totalLength,
        dataPointerOut: &dataPointer
    )
    guard statusCode == kCMBlockBufferNoErr, let dataPointer = dataPointer else { return }

    // Check keyframe
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

    var frameData = Data(capacity: totalLength + 256)

    // Keyframe: prepend VPS/SPS/PPS parameter sets
    if isKeyframe {
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var parameterSetCount: Int = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil
            )
            for i in 0..<parameterSetCount {
                var ptr: UnsafePointer<UInt8>?
                var size: Int = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                if let ptr = ptr {
                    frameData.append(contentsOf: nalStartCode)
                    frameData.append(ptr, count: size)
                }
            }
        }
    }

    // Convert AVCC (length-prefixed) to Annex-B (start code prefixed)
    var offset = 0
    while offset < totalLength {
        var nalLength: UInt32 = 0
        memcpy(&nalLength, dataPointer.advanced(by: offset), 4)
        nalLength = UInt32(bigEndian: nalLength)
        offset += 4

        frameData.append(contentsOf: nalStartCode)
        let nalPointer = UnsafeRawPointer(dataPointer.advanced(by: offset))
        frameData.append(nalPointer.assumingMemoryBound(to: UInt8.self), count: Int(nalLength))
        offset += Int(nalLength)
    }

    encoder.onEncodedFrame?(frameData, isKeyframe)
}
