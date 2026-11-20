import Foundation
import XCTest
@testable import ZipImageViewer

final class ArchiveImagePreparationIntegrationTests: XCTestCase {
    private final class Extractor: ArchiveExtracting {
        var passwordRequired = false
        func extract(archiveURL: URL, destinationURL: URL, password: String?,
                     cancellation: ArchiveCancellationToken,
                     progress: @escaping (ArchiveImportProgress) -> Void) throws -> [URL] {
            if passwordRequired && password == nil { throw ArchiveImportError.passwordRequired }
            let url = destinationURL.appendingPathComponent("page.png")
            try Data([1, 2, 3]).write(to: url)
            return [url]
        }
    }

    private final class Processor: ExtractedImagePreparing {
        var policies: [Bool] = []
        var beforeReturn: ((URL, (() throws -> Void)?) throws -> Void)?
        var savedProgress: ((Double) -> Void)?
        func prepare(images: [URL], imageRoot: URL, compress: Bool,
                     cancellation: (() throws -> Void)?,
                     progress: ((Double) -> Void)?) throws -> [ArchivePreparedPage] {
            policies.append(compress)
            savedProgress = progress
            progress?(0.5)
            try beforeReturn?(images[0], cancellation)
            try cancellation?()
            return images.map { ArchivePreparedPage(originalRelativePath: $0.lastPathComponent,
                                                     storedRelativePath: $0.lastPathComponent) }
        }
    }

    private func fixture() throws -> (URL, URL, ArchiveCacheStore, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("book.7z")
        try Data("fake archive".utf8).write(to: source)
        let suite = "ImagePreparation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("retained"),
                                      supportDirectory: root.appendingPathComponent("catalog"), defaults: defaults)
        return (root, source, store, defaults, suite)
    }

    @MainActor
    func testPolicySnapshotSurvivesPasswordRetryAndCacheHitNeverProcessesAgain() async throws {
        let (root, source, store, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        try store.updatePreferences(ArchiveCachePreferences(compressExtractedImages: true))
        let extractor = Extractor()
        extractor.passwordRequired = true
        let processor = Processor()
        let importer = ArchiveImportCoordinator(rootDirectory: root.appendingPathComponent("work"),
                                                extractor: extractor, cacheStore: store, imageProcessor: processor)
        await importer.beginImport(from: source)
        guard case .awaitingPassword = importer.state else { return XCTFail("Expected password request") }
        try store.updatePreferences(ArchiveCachePreferences(compressExtractedImages: false))
        await importer.submitPassword("secret")
        guard case .completed = importer.state else { return XCTFail("Expected successful preparation") }
        XCTAssertEqual(processor.policies, [true], "One operation retains its start-time choice")
        let originalSession = try XCTUnwrap(importer.takePreparedSession())
        let originalURLs = originalSession.imageURLs
        originalSession.release()
        await importer.beginImport(from: source, compressExtractedImages: false)
        let reused = try XCTUnwrap(importer.takePreparedSession())
        XCTAssertEqual(reused.imageURLs, originalURLs)
        XCTAssertEqual(processor.policies, [true], "Changing the setting must not rewrite a cache hit")
        processor.savedProgress?(0.9)
        await Task.yield()
        guard case .completed = importer.state else { return XCTFail("Late preparation progress changed completed state") }
        reused.release()
    }

    @MainActor
    func testPreparationCancellationWaitsForImageWorkerAndNeverPublishes() async throws {
        let (root, source, store, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let entered = expectation(description: "preparation entered")
        let cancelling = expectation(description: "cancellation requested")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let processor = Processor()
        var workingImage: URL?
        processor.beforeReturn = { image, cancellation in
            workingImage = image
            entered.fulfill()
            _ = release.wait(timeout: .now() + 10)
            XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
            try cancellation?()
        }
        let importer = ArchiveImportCoordinator(rootDirectory: root.appendingPathComponent("work"),
                                                extractor: Extractor(), cacheStore: store, imageProcessor: processor)
        importer.onStateChange = { if case .cancelling = $0 { cancelling.fulfill() } }
        let running = Task { await importer.beginImport(from: source, compressExtractedImages: true) }
        await fulfillment(of: [entered], timeout: 5)
        let cancel = Task { await importer.cancel() }
        await fulfillment(of: [cancelling], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(workingImage).path))
        release.signal()
        await cancel.value
        await running.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(workingImage).path))
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertNil(importer.takePreparedSession())
        guard case .idle = importer.state else { return XCTFail("Expected cancellation cleanup") }
    }

    @MainActor
    func testPreparationFailureCannotRequestAnotherPassword() async throws {
        let (root, source, store, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let processor = Processor()
        // Even an error resembling a decoder/password error is outside the password retry boundary.
        processor.beforeReturn = { _, _ in throw ArchiveImportError.passwordOrDamagedArchive }
        let importer = ArchiveImportCoordinator(rootDirectory: root.appendingPathComponent("work"),
                                                extractor: Extractor(), cacheStore: store, imageProcessor: processor)
        await importer.beginImport(from: source)
        guard case .failed = importer.state else { return XCTFail("Preparation failures must not ask for passwords") }
        XCTAssertFalse(importer.isBusy)
        XCTAssertTrue(try store.list().isEmpty)
    }
}
