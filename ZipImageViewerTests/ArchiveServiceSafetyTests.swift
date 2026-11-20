import XCTest
@testable import ZipImageViewer

final class ArchiveServiceSafetyTests: XCTestCase {
    private struct FailingExtractor: ArchiveExtracting {
        let error: ArchiveImportError
        func extract(archiveURL: URL, destinationURL: URL, password: String?,
                     cancellation: ArchiveCancellationToken,
                     progress: @escaping (ArchiveImportProgress) -> Void) throws -> [URL] {
            try Data([1]).write(to: destinationURL.appendingPathComponent("partial.png"))
            throw error
        }
    }

    private struct CancellingProcessor: ExtractedImagePreparing {
        let token: ArchiveCancellationToken
        func prepare(images: [URL], imageRoot: URL, compress: Bool,
                     cancellation: (() throws -> Void)?, progress: ((Double) -> Void)?) throws -> [ArchivePreparedPage] {
            token.cancel()
            try cancellation?()
            XCTFail("Cancellation must reach image preparation")
            return []
        }
    }

    private func workspace(_ body: (URL, URL, ArchiveCacheStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zip-service-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ZipServiceSafety.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.zip")
        try ZipExtractorTests.fixture([.init(name: "page.png")]).write(to: source)
        let store = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
                                      supportDirectory: root.appendingPathComponent("catalog"), defaults: defaults)
        try body(root, source, store)
    }

    func testStorageAndResourceFailuresDiscardSourceAndPartialOutputWithoutPasswordRetry() throws {
        for error in [ArchiveImportError.storageFailure, .resourceLimit("Test limit"), .unsafeOutput("Test path")] {
            try workspace { root, source, store in
                let service = ArchiveService(workDirectory: root.appendingPathComponent("work"), cacheStore: store,
                                             zipExtractor: FailingExtractor(error: error))
                guard case .archive(let request) = try service.prepareArchive(at: source) else { return XCTFail("Missing request") }
                XCTAssertThrowsError(try service.extract(request, password: "irrelevant")) {
                    XCTAssertEqual($0 as? ArchiveImportError, error)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: request.directory.path))
                XCTAssertNil(service.takePreparedSession())
                XCTAssertTrue(try store.list().isEmpty)
            }
        }
    }

    func testPasswordFailureKeepsOnlyRetrySource() throws {
        try workspace { root, source, store in
            let service = ArchiveService(workDirectory: root.appendingPathComponent("work"), cacheStore: store,
                                         zipExtractor: FailingExtractor(error: .passwordOrDamagedArchive))
            guard case .archive(let request) = try service.prepareArchive(at: source) else { return XCTFail("Missing request") }
            XCTAssertThrowsError(try service.extract(request, password: "wrong")) {
                guard case ArchiveService.ImportError.zipExtractionFailed = $0 else { return XCTFail("Unexpected \($0)") }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: request.directory.path), [request.url.lastPathComponent])
            try service.discard(request)
            XCTAssertFalse(FileManager.default.fileExists(atPath: request.directory.path))
        }
    }

    func testCancellationInPreparationDoesNotPublishOrRemoveExistingCache() throws {
        try workspace { root, source, store in
            let existing = root.appendingPathComponent("existing")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
            let oldPage = existing.appendingPathComponent("old.png")
            let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7o0AAAAASUVORK5CYII=")!
            try bytes.write(to: oldPage)
            let retained = try store.publish(images: [oldPage], imageRoot: existing, displayName: "existing",
                                             sourceIdentity: "existing", signature: "existing", format: "zip")
            defer { retained.release() }
            let token = ArchiveCancellationToken()
            let service = ArchiveService(workDirectory: root.appendingPathComponent("work"), cacheStore: store,
                                         imageProcessor: CancellingProcessor(token: token))
            guard case .archive(let request) = try service.prepareArchive(at: source, cancellation: token) else {
                return XCTFail("Missing request")
            }
            XCTAssertThrowsError(try service.extract(request, password: nil, cancellation: token)) {
                XCTAssertEqual($0 as? ArchiveImportError, .cancelled)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: request.directory.path))
            XCTAssertEqual(try store.list().map(\.id), [retained.archiveID])
            XCTAssertEqual(try Data(contentsOf: retained.imageURLs[0]), bytes)
        }
    }
}
