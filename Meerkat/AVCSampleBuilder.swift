import CoreMedia
import Foundation

struct AVCSampleBuilder {
    private(set) var format: CMVideoFormatDescription?
    private(set) var nalLengthSize = 4
    private var needsKeyframe = true
    private var lastTimestamp: UInt32?
    private var timestampEpoch: Int64 = 0

    mutating func sample(for tag: FLVTag) throws -> CMSampleBuffer? {
        guard tag.type == 9 else { return nil }
        let data = tag.payload
        guard data.count >= 5 else { throw FLVError.invalidAVC }
        guard data[0] & 15 == 7 else { throw FLVError.unsupportedCodec }
        switch data[1] {
        case 0:
            try configure(Data(data.dropFirst(5)))
            needsKeyframe = true
            return nil
        case 2:
            needsKeyframe = true
            return nil
        case 1: break
        default: throw FLVError.invalidAVC
        }
        guard let format else { return nil }
        let keyframe = data[0] >> 4 == 1
        guard !needsKeyframe || keyframe else { return nil }
        let payload = Data(data.dropFirst(5))
        var offset = 0
        var hasIDR = false
        while offset < payload.count {
            guard payload.count - offset >= nalLengthSize else { throw FLVError.invalidAVC }
            let size = Int(payload.integer(at: offset, count: nalLengthSize))
            offset += nalLengthSize
            guard size > 0, size <= payload.count - offset else { throw FLVError.invalidAVC }
            hasIDR = hasIDR || payload[offset] & 31 == 5
            offset += size
        }
        guard !payload.isEmpty else { throw FLVError.invalidAVC }
        guard !needsKeyframe || hasIDR else { return nil }
        needsKeyframe = false
        if let lastTimestamp, tag.timestamp < lastTimestamp {
            guard lastTimestamp - tag.timestamp > UInt32.max / 2 else { throw FLVError.invalidAVC }
            timestampEpoch += 1 << 32
        }
        lastTimestamp = tag.timestamp
        let decodeTime = timestampEpoch + Int64(tag.timestamp)
        let unsignedOffset = Int32(data.integer(at: 2, count: 3))
        let compositionOffset = unsignedOffset & 0x800000 == 0 ? unsignedOffset : unsignedOffset - 0x1000000
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: decodeTime + Int64(compositionOffset), timescale: 1000),
            decodeTimeStamp: CMTime(value: decodeTime, timescale: 1000))
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block))
        guard let block else { throw FLVError.invalidAVC }
        try payload.withUnsafeBytes { buffer in
            try check(CMBlockBufferReplaceDataBytes(with: buffer.baseAddress!, blockBuffer: block,
                                                  offsetIntoDestination: 0, dataLength: payload.count))
        }
        var sample: CMSampleBuffer?
        var size = payload.count
        try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample))
        guard let sample,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else {
            throw FLVError.invalidAVC
        }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                             Unmanaged.passUnretained(hasIDR ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
        return sample
    }

    private mutating func configure(_ data: Data) throws {
        guard data.count >= 7, data[0] == 1 else { throw FLVError.invalidAVC }
        let length = Int(data[4] & 3) + 1
        guard [1, 2, 4].contains(length) else { throw FLVError.invalidAVC }
        var offset = 6
        var sets = [Data]()
        func readSets(_ count: Int, type: UInt8) throws {
            guard count > 0 else { throw FLVError.invalidAVC }
            for _ in 0..<count {
                guard offset + 2 <= data.count else { throw FLVError.invalidAVC }
                let size = Int(data.integer(at: offset, count: 2))
                offset += 2
                guard size > 0, size <= data.count - offset, data[offset] & 31 == type else {
                    throw FLVError.invalidAVC
                }
                sets.append(data.subdata(in: offset..<offset + size))
                offset += size
            }
        }
        try readSets(Int(data[5] & 31), type: 7)
        guard offset < data.count else { throw FLVError.invalidAVC }
        let count = Int(data[offset])
        offset += 1
        try readSets(count, type: 8)
        let storage = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer { storage.forEach { $0.deallocate() } }
        var description: CMFormatDescription?
        try check(CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
            parameterSetCount: sets.count, parameterSetPointers: storage.map { UnsafePointer($0) },
            parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: Int32(length), formatDescriptionOut: &description))
        format = description
        nalLengthSize = length
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw FLVError.coreMedia(status) }
    }
}
