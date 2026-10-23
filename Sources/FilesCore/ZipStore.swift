import Foundation

/// One-entry, uncompressed ZIP writer. No subprocess or third-party library.
/// The conservative size cap keeps this Foundation-only implementation bounded.
enum ZipStore {
    static func archiveData(name fileName: String, contents: Data) throws -> Data {
        guard contents.count <= 128 * 1_024 * 1_024 else {
            throw FilesError.unsupported("ZIP action currently supports files up to 128 MiB")
        }
        let name = Data(fileName.utf8)
        guard name.count <= Int(UInt16.max) else { throw FilesError.unsupported("ZIP filename too long") }
        let size = UInt32(contents.count)
        let crc = crc32(contents)
        var data = Data()
        // Local file header; UTF-8 name, store method, deterministic 1980 timestamp.
        data.u32(0x04034b50); data.u16(20); data.u16(0x0800); data.u16(0)
        data.u16(0); data.u16(33); data.u32(crc); data.u32(size); data.u32(size)
        data.u16(UInt16(name.count)); data.u16(0); data.append(name); data.append(contents)
        let centralOffset = UInt32(data.count)
        data.u32(0x02014b50); data.u16(20); data.u16(20); data.u16(0x0800); data.u16(0)
        data.u16(0); data.u16(33); data.u32(crc); data.u32(size); data.u32(size)
        data.u16(UInt16(name.count)); data.u16(0); data.u16(0); data.u16(0)
        data.u16(0); data.u32(0); data.u32(0); data.append(name)
        let centralSize = UInt32(data.count) - centralOffset
        data.u32(0x06054b50); data.u16(0); data.u16(0); data.u16(1); data.u16(1)
        data.u32(centralSize); data.u32(centralOffset); data.u16(0)
        return data
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return ~crc
    }
}

private extension Data {
    mutating func u16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func u32(_ value: UInt32) {
        u16(UInt16(truncatingIfNeeded: value)); u16(UInt16(truncatingIfNeeded: value >> 16))
    }
}
