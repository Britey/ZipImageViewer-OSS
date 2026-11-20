import XCTest
import ZipArchive
@testable import ZipImageViewer

final class ZipExtractorTests: XCTestCase {
    struct Member {
        var name: String
        var bytes: Data = Data([1, 2, 3, 4])
        var mode: UInt32 = 0o100600
        var declaredSize: UInt32? = nil
    }

    // Stored, tiny, synthetic ZIPs only. No user files or large expansion fixtures.
    static func fixture(_ members: [Member]) -> Data {
        func number(_ value: UInt64, _ count: Int) -> Data {
            Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func crc(_ data: Data) -> UInt32 {
            var value = UInt32.max
            for byte in data {
                value ^= UInt32(byte)
                for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) }
            }
            return value ^ UInt32.max
        }
        var result = Data(), directory = Data()
        for entry in members {
            let name = Data(entry.name.utf8), offset = result.count
            let size = UInt64(entry.declaredSize ?? UInt32(entry.bytes.count))
            let checksum = UInt64(crc(entry.bytes))
            result += number(0x04034b50, 4) + number(20, 2) + number(0x800, 2) + number(0, 2)
            result += number(0, 2) + number(0x5021, 2) + number(checksum, 4)
            result += number(UInt64(entry.bytes.count), 4) + number(size, 4) + number(UInt64(name.count), 2) + number(0, 2)
            result += name + entry.bytes
            directory += number(0x02014b50, 4) + number(0x0314, 2) + number(20, 2) + number(0x800, 2) + number(0, 2)
            directory += number(0, 2) + number(0x5021, 2) + number(checksum, 4)
            directory += number(UInt64(entry.bytes.count), 4) + number(size, 4) + number(UInt64(name.count), 2)
            directory += number(0, 2) + number(0, 2) + number(0, 2) + number(0, 2)
            directory += number(UInt64(entry.mode) << 16, 4) + number(UInt64(offset), 4) + name
        }
        let offset = result.count
        result += directory
        result += number(0x06054b50, 4) + number(0, 2) + number(0, 2)
        result += number(UInt64(members.count), 2) + number(UInt64(members.count), 2)
        result += number(UInt64(directory.count), 4) + number(UInt64(offset), 4) + number(0, 2)
        return result
    }

    func workspace(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zip-regression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.zip"), output = root.appendingPathComponent("output")
        try body(root, source, output)
    }

    func extract(_ source: URL, _ output: URL, limits: ArchiveExtractionLimits = .default,
                 token: ArchiveCancellationToken = ArchiveCancellationToken()) throws -> [URL] {
        try ZipExtractor(limits: limits).extract(archiveURL: source, destinationURL: output, password: nil,
                                               cancellation: token, progress: { _ in })
    }

    func testMalformedAndAmbiguousDirectoriesRejected() throws {
        var countMismatch = Self.fixture([Member(name: "page.png")])
        countMismatch[countMismatch.count - 12] = 2
        var commentMarker = Self.fixture([Member(name: "page.png")])
        commentMarker[commentMarker.count - 2] = 40
        commentMarker += Data([0x50, 0x4b, 0x05, 0x06] + [UInt8](repeating: 0, count: 36))
        for bytes in [countMismatch, commentMarker, Self.fixture([Member(name: String(repeating: "a", count: 4097) + ".png")])] {
            try workspace { _, source, output in
                try bytes.write(to: source)
                XCTAssertThrowsError(try extract(source, output))
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    func testZip64DirectoryAndSmallInjectedLimit() throws {
        var bytes = Self.fixture([Member(name: "page.png")])
        let end = bytes.count - 22
        func number(_ value: UInt64, _ count: Int) -> Data {
            Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func value(_ index: Int) -> UInt64 {
            (0..<4).reduce(0) { $0 | (UInt64(bytes[index + $1]) << ($1 * 8)) }
        }
        let size = value(end + 12), offset = value(end + 16)
        var record = number(0x06064b50, 4) + number(44, 8) + number(45, 2) + number(45, 2)
        record += number(0, 4) + number(0, 4) + number(1, 8) + number(1, 8)
        record += number(size, 8) + number(offset, 8)
        record += number(0x07064b50, 4) + number(0, 4) + number(UInt64(end), 8) + number(1, 4)
        for i in (end + 8)..<(end + 20) { bytes[i] = 255 }
        bytes.insert(contentsOf: record, at: end)
        try workspace { _, source, output in
            try bytes.write(to: source)
            var limits = ArchiveExtractionLimits(); limits.maximumEntryCount = 0
            XCTAssertThrowsError(try extract(source, output, limits: limits))
            XCTAssertEqual(try extract(source, output).count, 1)
        }
    }

    func testRegularImagesOnlyAndNestedOutput() throws {
        try workspace { _, source, output in
            try Self.fixture([Member(name: "folder/page.png"), Member(name: "notes.txt"), Member(name: ".hidden.png")]).write(to: source)
            let pages = try extract(source, output)
            XCTAssertEqual(pages.count, 1)
            XCTAssertEqual(try Data(contentsOf: pages[0]), Data([1, 2, 3, 4]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("notes.txt").path))
        }
    }

    func testLinkAndSpecialEntriesRejectedBeforeWriting() throws {
        for mode: UInt32 in [0o120777, 0o010600, 0o060600] {
            try workspace { root, source, output in
                let sentinel = root.appendingPathComponent("sentinel.png")
                try Data("unchanged".utf8).write(to: sentinel)
                try Self.fixture([Member(name: "page.png"), Member(name: "link", bytes: Data("../sentinel.png".utf8), mode: mode), Member(name: "link/page.png")]).write(to: source)
                XCTAssertThrowsError(try extract(source, output)) { error in
                    guard case ArchiveImportError.unsafeOutput = error else { return XCTFail("\(error)") }
                }
                XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    func testCollisionAliasesAndFileDirectoryConflicts() throws {
        for names in [["page.png", "page.png"], ["A.png", "a.png"], ["é.png", "e\u{301}.png"],
                      ["page.png", "page.png/child.png"], ["a/../page.png"], ["a/./page.png"], ["../page.png"], ["/page.png"]] {
            try workspace { _, source, output in
                try Self.fixture(names.map { Member(name: $0) }).write(to: source)
                XCTAssertThrowsError(try extract(source, output))
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    func testEntryImageMetadataAndByteBudgets() throws {
        var count = ArchiveExtractionLimits(); count.maximumEntryCount = 1
        var images = ArchiveExtractionLimits(); images.maximumImageCount = 1
        var metadata = ArchiveExtractionLimits(); metadata.maximumZipMetadataBytes = 16
        var file = ArchiveExtractionLimits(); file.maximumFileBytes = 3
        var total = ArchiveExtractionLimits(); total.maximumTotalBytes = 7
        for limits in [count, images, metadata, file, total] {
            try workspace { _, source, output in
                try Self.fixture([Member(name: "1.png"), Member(name: "2.png")]).write(to: source)
                XCTAssertThrowsError(try extract(source, output, limits: limits)) { error in
                    guard case ArchiveImportError.resourceLimit = error else { return XCTFail("\(error)") }
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    func testActualBytesCannotExceedDeclaration() throws {
        try workspace { _, source, output in
            try Self.fixture([Member(name: "page.png", declaredSize: 1)]).write(to: source)
            XCTAssertThrowsError(try extract(source, output))
            let file = output.appendingPathComponent("page.png")
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            XCTAssertLessThanOrEqual(size, 1)
        }
    }

    func testDiskReserveAndWriteErrorsAreNotPasswords() throws {
        try workspace { _, source, output in
            try Self.fixture([Member(name: "page.png")]).write(to: source)
            let noSpace = ZipExtractor(availableBytes: { _ in 0 })
            XCTAssertThrowsError(try noSpace.extract(archiveURL: source, destinationURL: output, password: nil,
                                                    cancellation: ArchiveCancellationToken(), progress: { _ in })) { error in
                guard case ArchiveImportError.resourceLimit = error else { return XCTFail("\(error)") }
            }
            let writeFailure = ZipExtractor(writeChunk: { _, _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) })
            XCTAssertThrowsError(try writeFailure.extract(archiveURL: source, destinationURL: output, password: "irrelevant",
                                                         cancellation: ArchiveCancellationToken(), progress: { _ in })) { error in
                XCTAssertEqual(error as? ArchiveImportError, .storageFailure)
            }
        }
    }

    func testCancellationBeforeAndDuringWrites() throws {
        try workspace { _, source, output in
            try Self.fixture([Member(name: "page.png", bytes: Data(repeating: 0, count: 128 * 1024))]).write(to: source)
            let before = ArchiveCancellationToken(); before.cancel()
            XCTAssertThrowsError(try extract(source, output, token: before)) { XCTAssertEqual($0 as? ArchiveImportError, .cancelled) }
            let during = ArchiveCancellationToken()
            XCTAssertThrowsError(try ZipExtractor().extract(archiveURL: source, destinationURL: output, password: nil,
                cancellation: during, progress: { if $0.stage == .extracting { during.cancel() } })) {
                XCTAssertEqual($0 as? ArchiveImportError, .cancelled)
            }
            XCTAssertLessThanOrEqual(try output.appendingPathComponent("page.png").resourceValues(forKeys: [.fileSizeKey]).fileSize!, 64 * 1024)
        }
    }

    func testExistingOutputRootAndSymlinkRootAreRejected() throws {
        try workspace { root, source, output in
            try Self.fixture([Member(name: "page.png")]).write(to: source)
            let sentinel = root.appendingPathComponent("sentinel")
            try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: output, withDestinationURL: sentinel)
            XCTAssertThrowsError(try extract(source, output))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: sentinel.path).isEmpty)
            try FileManager.default.removeItem(at: output)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let page = output.appendingPathComponent("page.png")
            try Data("keep".utf8).write(to: page)
            XCTAssertThrowsError(try extract(source, output))
            XCTAssertEqual(try Data(contentsOf: page), Data("keep".utf8))
        }
    }

    func testEncryptedArchiveRetryAndStorageClassification() throws {
        try workspace { root, source, output in
            let page = root.appendingPathComponent("page.png")
            try Data([1, 2, 3, 4]).write(to: page)
            XCTAssertTrue(SSZipArchive.createZipFile(atPath: source.path, withFilesAtPaths: [page.path], withPassword: "test"))
            XCTAssertThrowsError(try extract(source, output)) { XCTAssertEqual($0 as? ArchiveImportError, .passwordRequired) }
            XCTAssertThrowsError(try ZipExtractor().extract(archiveURL: source, destinationURL: output, password: "wrong",
                cancellation: ArchiveCancellationToken(), progress: { _ in })) { XCTAssertEqual($0 as? ArchiveImportError, .passwordOrDamagedArchive) }
            try? FileManager.default.removeItem(at: output)
            let failure = ZipExtractor(writeChunk: { _, _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) })
            XCTAssertThrowsError(try failure.extract(archiveURL: source, destinationURL: output, password: "test",
                cancellation: ArchiveCancellationToken(), progress: { _ in })) { XCTAssertEqual($0 as? ArchiveImportError, .storageFailure) }
            try? FileManager.default.removeItem(at: output)
            let pages = try ZipExtractor().extract(archiveURL: source, destinationURL: output, password: "test",
                cancellation: ArchiveCancellationToken(), progress: { _ in })
            XCTAssertEqual(try Data(contentsOf: pages[0]), Data([1, 2, 3, 4]))
        }
    }
}
