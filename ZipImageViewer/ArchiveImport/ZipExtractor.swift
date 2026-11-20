import Foundation
import Darwin
import CoreFoundation

/// Extracts only regular images. The caller owns rollback of the private staging root.
/// No dependency API is given an archive-controlled output path or asked to restore links.
final class ZipExtractor: ArchiveExtracting {
    private let limits: ArchiveExtractionLimits
    private let availableBytes: (URL) throws -> UInt64
    private let writeChunk: (Int32, UnsafeRawPointer, Int) throws -> Int

    init(limits: ArchiveExtractionLimits = .default,
         availableBytes: @escaping (URL) throws -> UInt64 = { url in
             let values = try FileManager.default.attributesOfFileSystem(forPath: url.path)
             guard let bytes = values[.systemFreeSize] as? NSNumber else { throw ArchiveImportError.storageFailure }
             return bytes.uint64Value
         },
         writeChunk: @escaping (Int32, UnsafeRawPointer, Int) throws -> Int = { fd, bytes, count in
             Darwin.write(fd, bytes, count)
         }) {
        self.limits = limits
        self.availableBytes = availableBytes
        self.writeChunk = writeChunk
    }

    private struct Entry {
        let offset: Int64
        let name: String
        let size: UInt64
        let encrypted: Bool
        let modified: Date
        let url: URL
    }

    func extract(archiveURL: URL, destinationURL: URL, password: String?,
                 cancellation: ArchiveCancellationToken,
                 progress: @escaping (ArchiveImportProgress) -> Void) throws -> [URL] {
        do {
            progress(ArchiveImportProgress(stage: .opening))
            let count = try ZipMetadataAdmission.check(archiveURL, limits: limits, cancellation: cancellation)
            guard let zip = archiveURL.path.withCString({ unzOpen64($0) }) else {
                throw ArchiveImportError.unsupportedOrDamagedArchive
            }
            defer { unzClose(zip) }
            var policy = ArchiveOutputPolicy(root: destinationURL, limits: limits)
            var selected: [Entry] = []
            var status = unzGoToFirstFile(zip)
            for _ in 0..<count {
                try cancellation.checkCancellation()
                guard status == 0 else { throw ArchiveImportError.unsupportedOrDamagedArchive }
                var info = unz_file_info64()
                guard unzGetCurrentFileInfo64(zip, &info, nil, 0, nil, 0, nil, 0) == 0,
                      info.size_filename > 0, info.size_filename <= 4096 else {
                    throw ArchiveImportError.unsupportedOrDamagedArchive
                }
                var bytes = [CChar](repeating: 0, count: Int(info.size_filename) + 1)
                guard unzGetCurrentFileInfo64(zip, &info, &bytes, UInt(bytes.count), nil, 0, nil, 0) == 0 else {
                    throw ArchiveImportError.unsupportedOrDamagedArchive
                }
                let data = Data(bytes.prefix(Int(info.size_filename)).map { UInt8(bitPattern: $0) })
                let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
                guard !data.contains(0), let name = String(data: data, encoding: .utf8) ??
                        (info.flag & 0x800 == 0 ? String(data: data, encoding: cp437) : nil) else {
                    throw ArchiveImportError.unsafeOutput("Invalid ZIP filename encoding.")
                }
                let kind = (info.external_fa >> 16) & 0xf000
                let directory = name.hasSuffix("/")
                guard kind == 0 || (kind == 0x8000 && !directory) || (kind == 0x4000 && directory) else {
                    throw ArchiveImportError.unsafeOutput("Links and special entries are not supported: \(name)")
                }
                if !directory && ArchiveOutputPolicy.isSupportedImage(name) {
                    let output = try policy.reserve(entryName: name, size: info.uncompressed_size)
                    let offset = unzGetOffset64(zip)
                    guard offset >= 0 else { throw ArchiveImportError.unsupportedOrDamagedArchive }
                    var time = info.tmu_date
                    selected.append(Entry(offset: offset, name: name, size: info.uncompressed_size,
                                          encrypted: info.flag & 1 != 0,
                                          modified: Date(timeIntervalSince1970: TimeInterval(mktime(&time))), url: output))
                }
                status = unzGoToNextFile(zip)
            }
            guard status == -100 else { throw ArchiveImportError.unsupportedOrDamagedArchive }
            guard !selected.isEmpty else { throw ArchiveImportError.noSupportedImages }
            if selected.contains(where: \.encrypted) && password == nil { throw ArchiveImportError.passwordRequired }
            try cancellation.checkCancellation()
            try policy.prepareDestination()
            try checkSpace(policy.totalBytes, root: policy.root)
            let rootFD = open(policy.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw ArchiveImportError.storageFailure }
            defer { close(rootFD) }
            var total: UInt64 = 0
            var lastProgress = TimeInterval.zero
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            for entry in selected {
                try cancellation.checkCancellation()
                guard unzSetOffset64(zip, entry.offset) == 0 else { throw ArchiveImportError.unsupportedOrDamagedArchive }
                let opened = password.map { value in value.withCString { unzOpenCurrentFilePassword(zip, $0) } }
                    ?? unzOpenCurrentFilePassword(zip, nil)
                guard opened == 0 else { throw decodeFailure(opened, encrypted: entry.encrypted) }
                var entryOpen = true
                defer { if entryOpen { unzCloseCurrentFile(zip) } }
                let fd = try createOutput(entry.name, rootFD: rootFD)
                var outputOpen = true
                defer { if outputOpen { close(fd) } }
                var written: UInt64 = 0
                while true {
                    try cancellation.checkCancellation()
                    let read = unzReadCurrentFile(zip, &buffer, UInt32(buffer.count))
                    guard read >= 0 else { throw decodeFailure(read, encrypted: entry.encrypted) }
                    if read == 0 { break }
                    let bytes = UInt64(read)
                    guard bytes <= entry.size - written, bytes <= limits.maximumFileBytes - written,
                          bytes <= limits.maximumTotalBytes - total else {
                        throw ArchiveImportError.resourceLimit("A ZIP image exceeds its declared extraction size.")
                    }
                    try checkSpace(bytes, root: policy.root)
                    try buffer.withUnsafeBytes { storage in
                        var offset = 0
                        while offset < Int(read) {
                            try cancellation.checkCancellation()
                            let result = try writeChunk(fd, storage.baseAddress!.advanced(by: offset), Int(read) - offset)
                            if result < 0 && errno == EINTR { continue }
                            guard result > 0, result <= Int(read) - offset else { throw ArchiveImportError.storageFailure }
                            offset += result
                        }
                    }
                    written += bytes; total += bytes
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastProgress >= 0.1 || total == policy.totalBytes {
                        progress(ArchiveImportProgress(stage: .extracting, fractionCompleted: Double(total) / Double(max(1, policy.totalBytes))))
                        lastProgress = now
                    }
                }
                let closed = unzCloseCurrentFile(zip); entryOpen = false
                guard closed == 0 else { throw decodeFailure(closed, encrypted: entry.encrypted) }
                guard written == entry.size else { throw ArchiveImportError.unsupportedOrDamagedArchive }
                guard fsync(fd) == 0 else { throw ArchiveImportError.storageFailure }
                let closeResult = close(fd); outputOpen = false
                guard closeResult == 0 else { throw ArchiveImportError.storageFailure }
                try policy.verifyOutput(entry.url, expectedSize: entry.size)
                try FileManager.default.setAttributes([.modificationDate: entry.modified], ofItemAtPath: entry.url.path)
            }
            try cancellation.checkCancellation()
            progress(ArchiveImportProgress(stage: .finalizing))
            return selected.map(\.url)
        } catch {
            if cancellation.isCancelled { throw ArchiveImportError.cancelled }
            if let failure = error as? ArchiveImportError { throw failure }
            throw ArchiveImportError.storageFailure
        }
    }

    private func checkSpace(_ bytes: UInt64, root: URL) throws {
        let (required, overflow) = bytes.addingReportingOverflow(limits.minimumFreeDiskBytes)
        guard !overflow, try availableBytes(root) >= required else {
            throw ArchiveImportError.resourceLimit("There is not enough free storage to extract this archive.")
        }
    }

    private func decodeFailure(_ status: Int32, encrypted: Bool) -> ArchiveImportError {
        // minizip-ng read/seek/tell/close/open/write errors must never become password prompts.
        if [-1, -111, -112, -113, -114, -115, -116].contains(status) { return .storageFailure }
        return encrypted ? .passwordOrDamagedArchive : .unsupportedOrDamagedArchive
    }

    private func createOutput(_ name: String, rootFD: Int32) throws -> Int32 {
        let components = name.split(separator: "/").map(String.init)
        var parent = dup(rootFD)
        guard parent >= 0 else { throw ArchiveImportError.storageFailure }
        defer { close(parent) }
        for component in components.dropLast() {
            if mkdirat(parent, component, 0o700) != 0 && errno != EEXIST { throw ArchiveImportError.storageFailure }
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ArchiveImportError.unsafeOutput(name) }
            close(parent); parent = next
        }
        let fd = openat(parent, components.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ArchiveImportError.storageFailure }
        return fd
    }
}
