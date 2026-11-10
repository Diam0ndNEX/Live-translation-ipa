import Foundation

/// Minimal ZIP writer using uncompressed entries, avoiding network dependencies.
/// Fixed entry names prevent path traversal; 4 MiB cap keeps export bounded.
/// The ZIP CRC32 and central directory are verified by standard ZIP readers.
enum DiagnosticStoredZIP {
    static func make(entries: [(name: String, contents: Data)]) throws -> Data {
        guard !entries.isEmpty, entries.count <= 12 else { throw CocoaError(.fileWriteUnknown) }
        var body = Data()
        var central = Data()
        func write16(_ v: UInt16, to d: inout Data) {
            let n = v.littleEndian
            withUnsafeBytes(of: n) { d.append(contentsOf: $0) }
        }
        func write32(_ v: UInt32, to d: inout Data) {
            let n = v.littleEndian
            withUnsafeBytes(of: n) { d.append(contentsOf: $0) }
        }
        func checksum(_ bytes: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFFFFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB88320 : 0)
                }
            }
            return ~crc
        }
        for entry in entries {
            let name = Data(entry.name.utf8)
            guard entry.contents.count <= 4 * 1024 * 1024,
                  body.count + entry.contents.count < 8 * 1024 * 1024,
                  name.count > 0, name.count < 200, !entry.name.contains("/"),
                  !entry.name.contains("\\"), !entry.name.contains("..")
            else { throw CocoaError(.fileWriteUnknown) }
            let offset = UInt32(body.count)
            let count = UInt32(entry.contents.count)
            let crc = checksum(entry.contents)

            write32(0x04034B50, to: &body) // Local file header
            write16(20, to: &body)
            write16(0, to: &body) // No data descriptor
            write16(0, to: &body) // Stored, not compressed
            write16(0, to: &body)
            write16(0, to: &body)
            write32(crc, to: &body)
            write32(count, to: &body)
            write32(count, to: &body)
            write16(UInt16(name.count), to: &body)
            write16(0, to: &body)
            body.append(name)
            body.append(entry.contents)

            write32(0x02014B50, to: &central) // Central file header
            write16(20, to: &central)
            write16(20, to: &central)
            write16(0, to: &central)
            write16(0, to: &central)
            write16(0, to: &central)
            write16(0, to: &central)
            write32(crc, to: &central)
            write32(count, to: &central)
            write32(count, to: &central)
            write16(UInt16(name.count), to: &central)
            write16(0, to: &central)
            write16(0, to: &central)
            write16(0, to: &central)
            write16(0, to: &central)
            write32(0, to: &central)
            write32(offset, to: &central)
            central.append(name)
        }
        let centralOffset = UInt32(body.count)
        body.append(central)
        write32(0x06054B50, to: &body)
        write16(0, to: &body)
        write16(0, to: &body)
        write16(UInt16(entries.count), to: &body)
        write16(UInt16(entries.count), to: &body)
        write32(UInt32(central.count), to: &body)
        write32(centralOffset, to: &body)
        write16(0, to: &body)
        return body
    }
}
