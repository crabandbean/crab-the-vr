//
//  H264Decoder.swift
//  JoyVR
//
//  Turns Annex-B H.264 access units from the PC into CVPixelBuffers Metal can
//  sample directly.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class H264Decoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var sps: [UInt8]?
    private var pps: [UInt8]?

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    func reset() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        sps = nil
        pps = nil
    }

    func decode(accessUnit: Data) {
        let units = AnnexB.split(accessUnit)
        guard !units.isEmpty else { return }

        var parameterSetsChanged = false
        var frameUnits: [[UInt8]] = []

        for unit in units {
            guard let first = unit.first else { continue }
            switch first & 0x1F {
            case 7:
                if sps != unit { sps = unit; parameterSetsChanged = true }
            case 8:
                if pps != unit { pps = unit; parameterSetsChanged = true }
            case 1, 5:
                frameUnits.append(unit)
            default:
                break
            }
        }

        if parameterSetsChanged || formatDescription == nil {
            rebuildDecoder()
        }

        guard let formatDescription, let session, !frameUnits.isEmpty else { return }

        var avcc = Data()
        for unit in frameUnits {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: unit)
        }

        guard let sampleBuffer = makeSampleBuffer(avcc, formatDescription: formatDescription) else { return }

        let status = VTDecompressionSessionDecodeFrame(session,
                                                      sampleBuffer: sampleBuffer,
                                                      flags: [],
                                                      frameOptions: nil,
                                                      frameRefcon: nil,
                                                      infoFlagsOut: nil)
        if status != noErr {
            // A corrupt frame: rebuild so the next keyframe can start cleanly.
            reset()
        }
    }

    // MARK: Building the session

    private func rebuildDecoder() {
        guard let sps, let pps, let description = makeFormatDescription(sps: sps, pps: pps) else { return }
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = description

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: joyVRDecodeOutput,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                  formatDescription: description,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary,
                                                  outputCallback: &callback,
                                                  decompressionSessionOut: &newSession)
        guard status == noErr, let newSession else { return }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
    }

    private func makeFormatDescription(sps: [UInt8], pps: [UInt8]) -> CMFormatDescription? {
        var description: CMFormatDescription?
        sps.withUnsafeBufferPointer { spsPointer in
            pps.withUnsafeBufferPointer { ppsPointer in
                guard let spsBase = spsPointer.baseAddress,
                      let ppsBase = ppsPointer.baseAddress else { return }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                _ = pointers.withUnsafeBufferPointer { pointerArray in
                    sizes.withUnsafeBufferPointer { sizeArray in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                                                                            parameterSetCount: 2,
                                                                            parameterSetPointers: pointerArray.baseAddress!,
                                                                            parameterSetSizes: sizeArray.baseAddress!,
                                                                            nalUnitHeaderLength: 4,
                                                                            formatDescriptionOut: &description)
                    }
                }
            }
        }
        return description
    }

    private func makeSampleBuffer(_ avcc: Data, formatDescription: CMFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                              memoryBlock: nil,
                                                              blockLength: avcc.count,
                                                              blockAllocator: kCFAllocatorDefault,
                                                              customBlockSource: nil,
                                                              offsetToData: 0,
                                                              dataLength: avcc.count,
                                                              flags: 0,
                                                              blockBufferOut: &blockBuffer)
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                 blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0,
                                                 dataLength: avcc.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                                     dataBuffer: blockBuffer,
                                                     formatDescription: formatDescription,
                                                     sampleCount: 1,
                                                     sampleTimingEntryCount: 1,
                                                     sampleTimingArray: &timing,
                                                     sampleSizeEntryCount: 1,
                                                     sampleSizeArray: &sampleSize,
                                                     sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr else { return nil }
        return sampleBuffer
    }
}

// MARK: - Decode callback

private func joyVRDecodeOutput(refCon: UnsafeMutableRawPointer?,
                               sourceFrameRefCon: UnsafeMutableRawPointer?,
                               status: OSStatus,
                               infoFlags: VTDecodeInfoFlags,
                               imageBuffer: CVImageBuffer?,
                               presentationTimeStamp: CMTime,
                               presentationDuration: CMTime) {
    guard status == noErr, let imageBuffer, let refCon else { return }
    let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.onFrame?(imageBuffer, presentationTimeStamp)
}

// MARK: - Annex-B splitting

enum AnnexB {
    /// Splits a byte stream on 00 00 01 start codes.
    static func split(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return [] }

        var starts: [Int] = []
        var index = 0
        while index + 3 <= bytes.count - 1 {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append(index + 3)
                index += 3
            } else {
                index += 1
            }
        }
        guard !starts.isEmpty else { return [] }

        var units: [[UInt8]] = []
        for (position, start) in starts.enumerated() {
            var end = position + 1 < starts.count ? starts[position + 1] - 3 : bytes.count
            while end > start, bytes[end - 1] == 0 {
                end -= 1
            }
            if end > start {
                units.append(Array(bytes[start..<end]))
            }
        }
        return units
    }
}
