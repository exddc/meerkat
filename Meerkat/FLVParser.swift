import Foundation

enum FLVError: Error {
    case invalidHeader, invalidTag, unsupportedCodec, invalidAVC, coreMedia(OSStatus)
}

struct FLVTag {
    let type: UInt8
    let timestamp: UInt32
    let payload: Data
}

struct FLVParser {
    private var bytes = Data()
    private var hasHeader = false
    static let maximumTagSize = 2 * 1024 * 1024

    mutating func append(_ data: Data) throws -> [FLVTag] {
        bytes.append(data)
        var offset = 0
        defer { if offset > 0 { bytes = Data(bytes.dropFirst(offset)) } }
        if !hasHeader {
            guard bytes.count >= 9 else { return [] }
            guard Array(bytes.prefix(4)) == [0x46, 0x4c, 0x56, 1], bytes[4] & 0xfa == 0 else {
                throw FLVError.invalidHeader
            }
            let size = Int(bytes.integer(at: 5, count: 4))
            guard size >= 9, size <= 4096 else { throw FLVError.invalidHeader }
            guard bytes.count >= size + 4 else { return [] }
            guard bytes.integer(at: size, count: 4) == 0 else { throw FLVError.invalidHeader }
            offset = size + 4
            hasHeader = true
        }
        var tags = [FLVTag]()
        while bytes.count - offset >= 11 {
            let size = Int(bytes.integer(at: offset + 1, count: 3))
            guard size <= Self.maximumTagSize,
                  bytes[offset] & 0xe0 == 0,
                  bytes.integer(at: offset + 8, count: 3) == 0 else { throw FLVError.invalidTag }
            guard bytes.count - offset >= size + 15 else { break }
            guard bytes.integer(at: offset + 11 + size, count: 4) == size + 11 else {
                throw FLVError.invalidTag
            }
            let timestamp = bytes.integer(at: offset + 4, count: 3) | UInt32(bytes[offset + 7]) << 24
            if bytes[offset] == 9 {
                tags.append(FLVTag(type: 9, timestamp: timestamp,
                                   payload: bytes.subdata(in: offset + 11 ..< offset + 11 + size)))
            }
            offset += size + 15
        }
        return tags
    }
}

extension Data {
    func integer(at offset: Int, count: Int) -> UInt32 {
        self[offset ..< offset + count].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
