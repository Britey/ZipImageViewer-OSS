import CryptoKit
import Foundation
import UIKit
import XCTest
@testable import ZipImageViewer

/// Real archives created with official 7-Zip, independently of the application's decoder.
final class SevenZipExtractorTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Image: Decodable { let sha256: String; let size: Int }
        struct Fixture: Decodable {
            let file: String
            let password: String?
            let archive_sha256: String
        }
        let expected_images: [String: Image]
        let fixtures: [Fixture]
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: SevenZipExtractorTests.self)
        // Xcode synchronized groups may flatten resources; an explicit folder reference does not.
        for directory in ["Fixtures/SevenZip", "SevenZip", "Fixtures", ""] {
            if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: directory) {
                return url
            }
        }
        XCTFail("Missing bundled fixture \(name); include Fixtures/SevenZip in the test target's resources.")
        throw CocoaError(.fileNoSuchFile)
    }

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixtureURL("manifest.json")))
    }

    private func withDestination(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("output", isDirectory: true))
    }

    @discardableResult
    private func extract(_ name: String, to destination: URL, password: String? = nil,
                         cancellation: ArchiveCancellationToken = ArchiveCancellationToken()) throws -> [URL] {
        try SevenZipExtractor().extract(archiveURL: fixtureURL(name), destinationURL: destination,
                                        password: password, cancellation: cancellation, progress: { _ in })
    }

    private func assertExpectedImages(_ urls: [URL], under destination: URL,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try manifest().expected_images
        XCTAssertEqual(urls.count, expected.count, file: file, line: line)
        let prefix = destination.standardizedFileURL.path + "/"
        var paths = Set<String>()
        for url in urls {
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(prefix), file: file, line: line)
            let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            paths.insert(path)
            let expectedImage = try XCTUnwrap(expected[path], "Unexpected image: \(path)", file: file, line: line)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(data.count, expectedImage.size, file: file, line: line)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                           expectedImage.sha256, "Changed bytes: \(path)", file: file, line: line)
            XCTAssertNotNil(UIImage(data: data), "Fixture must be a real decodable image", file: file, line: line)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            XCTAssertEqual(values.isRegularFile, true, file: file, line: line)
            XCTAssertEqual(values.isSymbolicLink, false, file: file, line: line)
        }
        XCTAssertEqual(paths, Set(expected.keys), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("notes.txt").path),
                       "Non-image data must not be extracted", file: file, line: line)
    }

    func testFixturesMatchIndependentManifest() throws {
        for fixture in try manifest().fixtures {
            let data = try Data(contentsOf: fixtureURL(fixture.file))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                           fixture.archive_sha256, fixture.file)
        }
    }

    func testOrdinaryLZMAAndLZMA2Archives() throws {
        for name in ["plain-lzma-solid.7z", "plain-lzma2-nonsolid.7z"] {
            try withDestination { destination in
                try assertExpectedImages(extract(name, to: destination), under: destination)
            }
        }
    }

    func testEncryptedContentsAndEncryptedHeaders() throws {
        for name in ["content-lzma2-solid.7z", "headers-lzma-solid.7z", "headers-lzma2-nonsolid.7z"] {
            try withDestination { destination in
                try assertExpectedImages(extract(name, to: destination, password: "test-password"), under: destination)
            }
        }
    }

    func testSolidEncryptedArchiveWith600Images() throws {
        try withDestination { destination in
            let images = try extract("many-images-solid-encrypted.7z", to: destination, password: "test-password")
            XCTAssertEqual(images.count, 600)
            let expected = try XCTUnwrap(manifest().expected_images["panel.png"])
            let prefix = destination.standardizedFileURL.path + "/"
            var paths = Set<String>()
            for image in images {
                XCTAssertTrue(image.standardizedFileURL.path.hasPrefix(prefix))
                paths.insert(String(image.standardizedFileURL.path.dropFirst(prefix.count)))
                let data = try Data(contentsOf: image)
                XCTAssertEqual(data.count, expected.size)
                XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), expected.sha256)
            }
            XCTAssertEqual(paths, Set((0..<600).map { String(format: "pages/page-%04d.png", $0) }))
        }
    }

    func testPPMdCompatibility() throws {
        try withDestination { destination in
            try assertExpectedImages(extract("plain-ppmd.7z", to: destination), under: destination)
        }
    }

    func testUnicodePassword() throws {
        try withDestination { destination in
            try assertExpectedImages(extract("unicode-password.7z", to: destination, password: "密码🔐café"), under: destination)
        }
    }

    func testSupplementaryPlaneUnicodeFilename() throws {
        try withDestination { destination in
            let images = try extract("unicode-filename.7z", to: destination)
            XCTAssertEqual(images.count, 1)
            let image = try XCTUnwrap(images.first)
            XCTAssertEqual(image.lastPathComponent, "图像🔐.png")
            let data = try Data(contentsOf: image)
            let expected = try XCTUnwrap(manifest().expected_images["panel.png"])
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), expected.sha256)
            XCTAssertNotNil(UIImage(data: data))
        }
    }

    func testEmptySubmittedPasswordIsAnAttemptRatherThanCancellation() throws {
        try withDestination { destination in
            XCTAssertThrowsError(try extract("headers-lzma-solid.7z", to: destination, password: "")) { error in
                XCTAssertEqual(error as? ArchiveImportError, .openFailed(passwordAttempted: true))
            }
        }
        try withDestination { destination in
            XCTAssertThrowsError(try extract("content-lzma2-solid.7z", to: destination, password: "")) { error in
                XCTAssertEqual(error as? ArchiveImportError, .passwordOrDamagedArchive)
            }
        }
    }

    func testWhitespacePasswordIsPreservedExactly() throws {
        try withDestination { destination in
            try assertExpectedImages(extract("whitespace-password.7z", to: destination, password: "  padded password  "), under: destination)
        }
        try withDestination { destination in
            XCTAssertThrowsError(try extract("whitespace-password.7z", to: destination, password: "padded password"))
        }
    }

    func testReadableEncryptedContentsRequirePassword() throws {
        try withDestination { destination in
            XCTAssertThrowsError(try extract("content-lzma2-solid.7z", to: destination)) { error in
                XCTAssertEqual(error as? ArchiveImportError, .passwordRequired)
            }
        }
    }

    func testEncryptedHeadersReportAmbiguousOpenFailure() throws {
        try withDestination { destination in
            XCTAssertThrowsError(try extract("headers-lzma-solid.7z", to: destination)) { error in
                XCTAssertEqual(error as? ArchiveImportError, .openFailed(passwordAttempted: false))
            }
        }
        try withDestination { destination in
            XCTAssertThrowsError(try extract("headers-lzma-solid.7z", to: destination, password: "wrong")) { error in
                XCTAssertEqual(error as? ArchiveImportError, .openFailed(passwordAttempted: true))
            }
        }
    }

    func testWrongContentPasswordCanBeRetriedWithFreshDecoder() throws {
        let extractor = SevenZipExtractor()
        try withDestination { destination in
            XCTAssertThrowsError(try extractor.extract(archiveURL: fixtureURL("content-lzma2-solid.7z"),
                destinationURL: destination, password: "wrong", cancellation: ArchiveCancellationToken(), progress: { _ in })) { error in
                XCTAssertEqual(error as? ArchiveImportError, .passwordOrDamagedArchive)
            }
        }
        try withDestination { destination in
            let images = try extractor.extract(archiveURL: fixtureURL("content-lzma2-solid.7z"),
                destinationURL: destination, password: "test-password", cancellation: ArchiveCancellationToken(), progress: { _ in })
            try assertExpectedImages(images, under: destination)
        }
    }

    func testNoImagesIsDistinctFromPasswordFailure() throws {
        try withDestination { destination in
            XCTAssertThrowsError(try extract("no-images.7z", to: destination)) { error in
                XCTAssertEqual(error as? ArchiveImportError, .noSupportedImages)
            }
        }
    }

    func testTruncationAndDamagedEncryptedDataNeverSucceed() throws {
        for (name, password) in [("truncated.7z", nil), ("damaged-content.7z", "test-password")] as [(String, String?)] {
            try withDestination { destination in
                XCTAssertThrowsError(try extract(name, to: destination, password: password)) { error in
                    XCTAssertNotEqual(error as? ArchiveImportError, .passwordRequired)
                }
            }
        }
    }

    func testUnsafePathsAndCaseCollisionsAreRejectedBeforeWriting() throws {
        for name in ["unsafe-traversal.7z", "case-collision.7z"] {
            try withDestination { destination in
                XCTAssertThrowsError(try extract(name, to: destination)) { error in
                    guard case .unsafeOutput = error as? ArchiveImportError else {
                        return XCTFail("Expected unsafeOutput, received \(error)")
                    }
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().appendingPathComponent("escape.png").path))
                let outputs = (try? FileManager.default.subpathsOfDirectory(atPath: destination.path)) ?? []
                XCTAssertTrue(outputs.isEmpty, "Validate all destinations before writing any image")
            }
        }
    }

    func testPrecancelledOperationDoesNotWriteImages() throws {
        let cancellation = ArchiveCancellationToken()
        cancellation.cancel()
        try withDestination { destination in
            XCTAssertThrowsError(try extract("plain-lzma-solid.7z", to: destination, cancellation: cancellation)) { error in
                XCTAssertEqual(error as? ArchiveImportError, .cancelled)
            }
            let outputs = (try? FileManager.default.subpathsOfDirectory(atPath: destination.path)) ?? []
            XCTAssertTrue(outputs.isEmpty)
        }
    }

    func testCancellationDuringNativeExtractionThenFreshRetry() throws {
        let cancellation = ArchiveCancellationToken()
        var cancelledDuringNativeProgress = false
        try withDestination { destination in
            XCTAssertThrowsError(try SevenZipExtractor().extract(
                archiveURL: fixtureURL("cancellation.7z"), destinationURL: destination, password: nil,
                cancellation: cancellation, progress: { progress in
                    if progress.stage == .extracting, let fraction = progress.fractionCompleted,
                       fraction > 0, fraction < 1 {
                        cancelledDuringNativeProgress = true
                        cancellation.cancel()
                    }
                })) { error in
                    XCTAssertEqual(error as? ArchiveImportError, .cancelled)
                }
            XCTAssertTrue(cancelledDuringNativeProgress, "Must cancel after decoding starts and before it completes")
        }
        try withDestination { destination in
            try assertExpectedImages(extract("plain-lzma-solid.7z", to: destination), under: destination)
        }
    }

    func testOutputLimitsFailBeforeImageWrites() throws {
        let limits = [ArchiveExtractionLimits(maximumEntryCount: 1),
                      ArchiveExtractionLimits(maximumImageCount: 1),
                      ArchiveExtractionLimits(maximumFileBytes: 1),
                      ArchiveExtractionLimits(maximumTotalBytes: 1),
                      ArchiveExtractionLimits(minimumFreeDiskBytes: UInt64.max)]
        for limit in limits {
            try withDestination { destination in
                XCTAssertThrowsError(try SevenZipExtractor(limits: limit).extract(
                    archiveURL: fixtureURL("plain-lzma-solid.7z"), destinationURL: destination,
                    password: nil, cancellation: ArchiveCancellationToken(), progress: { _ in })) { error in
                    guard case .resourceLimit = error as? ArchiveImportError else {
                        return XCTFail("Expected resourceLimit, received \(error)")
                    }
                }
                let outputs = (try? FileManager.default.subpathsOfDirectory(atPath: destination.path)) ?? []
                XCTAssertTrue(outputs.isEmpty)
            }
        }
    }

    func testExistingOutputIsNeverOverwritten() throws {
        try withDestination { destination in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let sentinel = destination.appendingPathComponent("panel.png")
            let contents = Data("Existing cache must survive".utf8)
            try contents.write(to: sentinel)
            XCTAssertThrowsError(try extract("plain-lzma-solid.7z", to: destination)) { error in
                guard case .unsafeOutput = error as? ArchiveImportError else {
                    return XCTFail("Expected unsafeOutput, received \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), contents)
        }
    }

    func testSymlinkDestinationIsRejected() throws {
        try withDestination { destination in
            let outside = destination.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
            XCTAssertThrowsError(try extract("plain-lzma-solid.7z", to: destination)) { error in
                guard case .unsafeOutput = error as? ArchiveImportError else {
                    return XCTFail("Expected unsafeOutput, received \(error)")
                }
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    func testHiddenImagesAndResourceForksAreNotViewerPages() throws {
        try withDestination { destination in
            try assertExpectedImages(extract("hidden-images.7z", to: destination), under: destination)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("._panel.png").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".hidden").path))
        }
    }

    func testImageModificationDatesArePreserved() throws {
        try withDestination { destination in
            let images = try extract("plain-lzma-solid.7z", to: destination)
            for image in images {
                let date = try XCTUnwrap(image.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                XCTAssertEqual(date.timeIntervalSince1970, 1_700_000_000, accuracy: 2)
            }
        }
    }
}
