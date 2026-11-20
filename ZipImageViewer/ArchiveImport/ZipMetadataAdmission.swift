import Foundation

/// Constant-scratch-space admission before minizip can copy a central directory.
/// Split archives, SFX offsets, trailing junk and inconsistent ZIP64 are unsupported.
enum ZipMetadataAdmission {
    static func check(_ url: URL, limits: ArchiveExtractionLimits,
                      cancellation: ArchiveCancellationToken) throws -> Int {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        func invalid() -> ArchiveImportError { .unsupportedOrDamagedArchive }
        func read(_ position: UInt64, _ count: Int) throws -> [UInt8] {
            try cancellation.checkCancellation()
            guard position <= length, UInt64(count) <= length - position else { throw invalid() }
            try input.seek(toOffset: position)
            let data = try input.read(upToCount: count) ?? Data()
            guard data.count == count else { throw invalid() }
            return Array(data)
        }
        func number(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
        }
        guard length >= 22 else { throw invalid() }
        let tailStart = length > 65557 ? length - 65557 : 0
        let tail = try read(tailStart, Int(length - tailStart))
        guard let index = stride(from: tail.count - 4, through: 0, by: -1).first(where: {
            number(tail, $0, 4) == 0x06054b50
        }) else { throw invalid() }
        // Match the dependency's last-signature search. A later marker in a comment
        // must not let admission validate a different directory than the decoder.
        guard index <= tail.count - 22, index + 22 + Int(number(tail, index + 20, 2)) == tail.count else { throw invalid() }
        let end = tailStart + UInt64(index)
        guard number(tail, index + 4, 2) == 0, number(tail, index + 6, 2) == 0 else { throw invalid() }
        let count32 = number(tail, index + 10, 2)
        let size32 = number(tail, index + 12, 4)
        let offset32 = number(tail, index + 16, 4)
        guard number(tail, index + 8, 2) == count32 else { throw invalid() }
        var count = count32, size = size32, offset = offset32, directoryEnd = end
        var zip64 = false
        if end >= 20 {
            let locator = try read(end - 20, 20)
            if number(locator, 0, 4) == 0x07064b50 {
                zip64 = true
                let record = number(locator, 8, 8)
                guard end >= 76, number(locator, 4, 4) == 0, number(locator, 16, 4) == 1,
                      record <= end - 76 else { throw invalid() }
                let header = try read(record, 56)
                let recordSize = number(header, 4, 8)
                guard number(header, 0, 4) == 0x06064b50, recordSize >= 44, recordSize <= 4096,
                      recordSize == end - 20 - record - 12,
                      number(header, 16, 4) == 0, number(header, 20, 4) == 0 else { throw invalid() }
                count = number(header, 32, 8); size = number(header, 40, 8); offset = number(header, 48, 8)
                guard number(header, 24, 8) == count,
                      count32 == 65535 || count32 == count,
                      size32 == 0xffffffff || size32 == size,
                      offset32 == 0xffffffff || offset32 == offset else { throw invalid() }
                directoryEnd = record
            }
        }
        guard zip64 || (count32 != 65535 && size32 != 0xffffffff && offset32 != 0xffffffff) else { throw invalid() }
        guard count <= UInt64(max(0, limits.maximumEntryCount)), size <= limits.maximumZipMetadataBytes else {
            throw ArchiveImportError.resourceLimit("The ZIP directory exceeds the safe metadata limit.")
        }
        guard offset <= directoryEnd, size == directoryEnd - offset, count <= size / 46 else { throw invalid() }
        var position = offset
        var extraRecords = 0
        for _ in 0..<count {
            guard directoryEnd - position >= 46 else { throw invalid() }
            let header = try read(position, 46)
            let name = number(header, 28, 2), extra = number(header, 30, 2), comment = number(header, 32, 2)
            guard number(header, 0, 4) == 0x02014b50, name > 0, name <= 4096,
                  extra <= 16384, comment <= 4096, number(header, 34, 2) == 0 else { throw invalid() }
            let span = 46 + name + extra + comment
            guard span <= directoryEnd - position else { throw invalid() }
            var field = position + 46 + name
            let extraEnd = field + extra
            while field < extraEnd {
                extraRecords += 1
                guard extraEnd - field >= 4, extraRecords <= 65536 else { throw invalid() }
                let record = try read(field, 4)
                let bytes = number(record, 2, 2)
                guard bytes <= extraEnd - field - 4 else { throw invalid() }
                field += 4 + bytes
            }
            position += span
        }
        guard position == directoryEnd else { throw invalid() }
        try cancellation.checkCancellation()
        return Int(count)
    }
}
