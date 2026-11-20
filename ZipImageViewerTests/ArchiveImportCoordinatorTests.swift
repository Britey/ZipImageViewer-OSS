import XCTest
@testable import ZipImageViewer

final class ArchiveImportCoordinatorTests: XCTestCase {
    private final class FakeExtractor: ArchiveExtracting {
        var body: (URL, URL, String?, ArchiveCancellationToken, @escaping (ArchiveImportProgress) -> Void) throws -> [URL]
        init(_ body: @escaping (URL, URL, String?, ArchiveCancellationToken, @escaping (ArchiveImportProgress) -> Void) throws -> [URL]) {
            self.body = body
        }
        func extract(archiveURL: URL, destinationURL: URL, password: String?, cancellation: ArchiveCancellationToken,
                     progress: @escaping (ArchiveImportProgress) -> Void) throws -> [URL] {
            try body(archiveURL, destinationURL, password, cancellation, progress)
        }
    }

    private final class CommitGateFileManager: FileManager, @unchecked Sendable {
        var afterCommitRename: (() -> Void)?
        override func moveItem(at source: URL, to destination: URL) throws {
            try super.moveItem(at: source, to: destination)
            if destination.deletingLastPathComponent().lastPathComponent == "archives" {
                afterCommitRename?()
            }
        }
    }

    private func fixture() throws -> (base: URL, source: URL, root: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("test.7z")
        try Data("archive".utf8).write(to: source)
        return (base, source, base.appendingPathComponent("cache"))
    }

    private static func writeImage(to directory: URL) throws -> [URL] {
        let image = directory.appendingPathComponent("page.png")
        try Data([1, 2, 3]).write(to: image)
        return [image]
    }

    @MainActor
    func testPasswordRetryCopiesOncePreservesWhitespaceAndDeletesFailedAttempt() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.base) }
        var copies = 0
        var passwords: [String?] = []
        var attempts: [URL] = []
        let fake = FakeExtractor { _, destination, password, _, _ in
            passwords.append(password)
            attempts.append(destination)
            let images = try Self.writeImage(to: destination)
            guard password != nil else { throw ArchiveImportError.passwordRequired }
            return images
        }
        var access = ArchiveImportCoordinator.SourceAccess()
        access.copy = { source, destination in
            copies += 1
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let coordinator = ArchiveImportCoordinator(rootDirectory: files.root, extractor: fake, sourceAccess: access)
        await coordinator.beginImport(from: files.source)
        guard case .awaitingPassword(.passwordRequired) = coordinator.state else {
            return XCTFail("Expected a password request")
        }
        XCTAssertTrue(coordinator.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attempts[0].path))
        await coordinator.submitPassword("  密碼  ")
        guard case .completed(let images) = coordinator.state else { return XCTFail("Expected successful retry") }
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(passwords.count, 2)
        XCTAssertNil(passwords[0])
        XCTAssertEqual(passwords[1], "  密碼  ")
        XCTAssertNotEqual(attempts[0], attempts[1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: images[0].path))
        XCTAssertFalse(coordinator.isBusy)
    }

    @MainActor
    func testFailedReplacementRetainsPreviousCacheAndClearInvalidatesIt() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.base) }
        let secondSource = files.base.appendingPathComponent("broken.7z")
        try Data("broken".utf8).write(to: secondSource)
        var decodes = 0
        let fake = FakeExtractor { _, output, _, _, _ in
            decodes += 1
            if decodes == 2 { throw ArchiveImportError.invalidArchive }
            return try Self.writeImage(to: output)
        }
        let coordinator = ArchiveImportCoordinator(rootDirectory: files.root, extractor: fake)
        await coordinator.beginImport(from: files.source)
        guard case .completed(let firstImages) = coordinator.state else { return XCTFail("Expected first success") }
        await coordinator.beginImport(from: secondSource)
        guard case .failed = coordinator.state else { return XCTFail("Expected replacement failure") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstImages[0].path))
        await coordinator.beginImport(from: files.source)
        guard case .completed(let cachedImages) = coordinator.state else { return XCTFail("Expected cached success") }
        XCTAssertEqual(cachedImages, firstImages)
        XCTAssertEqual(decodes, 2)
        try await coordinator.clearCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstImages[0].path))
        await coordinator.beginImport(from: files.source)
        XCTAssertEqual(decodes, 3)
    }

    @MainActor
    func testMultipleSevenZipArchivesSurviveCoordinatorRecreation() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.base) }
        let secondSource = files.base.appendingPathComponent("second.7z")
        try Data("second".utf8).write(to: secondSource)
        var decodes = 0
        let fake = FakeExtractor { _, output, _, _, _ in
            decodes += 1
            return try Self.writeImage(to: output)
        }
        var firstImages: [URL] = []
        do {
            let coordinator = ArchiveImportCoordinator(rootDirectory: files.root, extractor: fake)
            await coordinator.beginImport(from: files.source)
            guard case .completed(let images) = coordinator.state else { return XCTFail("Expected first import") }
            firstImages = images
            await coordinator.beginImport(from: secondSource)
            guard case .completed = coordinator.state else { return XCTFail("Expected second import") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: firstImages[0].path))
        }
        let relaunched = ArchiveImportCoordinator(rootDirectory: files.root, extractor: fake)
        for source in [files.source, secondSource] {
            await relaunched.beginImport(from: source)
            guard case .completed = relaunched.state else { return XCTFail("Expected retained cache") }
        }
        XCTAssertEqual(decodes, 2, "Recreated coordinators must not decode retained archives")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstImages[0].path))
    }

    @MainActor
    func testSameSizeSameDateArchiveReplacementInvalidatesSevenZipCache() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.base) }
        let timestamp = try XCTUnwrap(files.source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var decodes = 0
        let fake = FakeExtractor { _, output, _, _, _ in
            decodes += 1
            return try Self.writeImage(to: output)
        }
        let coordinator = ArchiveImportCoordinator(rootDirectory: files.root, extractor: fake)
        await coordinator.beginImport(from: files.source)
        try Data("changed".utf8).write(to: files.source)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: files.source.path)
        await coordinator.beginImport(from: files.source)
        guard case .completed = coordinator.state else { return XCTFail("Expected replacement import") }
        XCTAssertEqual(decodes, 2, "Metadata equality must not hide changed archive bytes")
    }

    @MainActor
    func testPurgedSevenZipImagesDoNotReuseCachedURLMetadata() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.base) }
        var decodes = 0
        let fake = FakeExtractor { _, output, _, _, _ in
            decodes += 1
            return try Self.writeImage(to: output)
        }
        let coordinator = ArchiveImportCoordinator(rootDirectory: files.root, extractor: fake)
        await coordinator.beginImport(from: files.source)
        guard case .completed(let images) = coordinator.state else { return XCTFail("Expected import") }
        _ = try images[0].resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        try FileManager.default.removeItem(at: images[0])
        await coordinator.beginImport(from: files.source)
        guard case .completed(let rebuilt) = coordinator.state else { return XCTFail("Expected rebuilt cache") }
        XCTAssertEqual(decodes, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rebuilt[0].path))
    }

    @MainActor
    func testCancelWaitsForNativeWorkerBeforeDeletingPartialOutput() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.base) }
        let entered = expectation(description: "decoder entered")
        let cancelling = expectation(description: "cancel requested")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var partialOutput: URL?
        let fake = FakeExtractor { _, output, _, token, _ in
            partialOutput = try Self.writeImage(to: output).first
            entered.fulfill()
            _ = release.wait(timeout: .now() + 10)
            try token.checkCancellation()
            return [partialOutput!]
        }
        let coordinator = ArchiveImportCoordinator(rootDirectory: files.root, extractor: fake)
        coordinator.onStateChange = { state in
            if case .cancelling = state { cancelling.fulfill() }
        }
        let importing = Task { await coordinator.beginImport(from: files.source) }
        await fulfillment(of: [entered], timeout: 5)
        let cancel = Task { await coordinator.cancel() }
        await fulfillment(of: [cancelling], timeout: 5)
        XCTAssertTrue(coordinator.isBusy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(partialOutput).path))
        // A conflicting import must not be admitted while cancellation is draining the decoder.
        await coordinator.beginImport(from: files.source)
        release.signal()
        await cancel.value
        await importing.value
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(partialOutput).path))
        guard case .idle = coordinator.state else { return XCTFail("Expected idle after native return") }
    }

    @MainActor
    func testCancellingCallerTaskDrainsWorkerAndCleansOutput() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.base) }
        let entered = expectation(description: "decoder entered")
        let cancelling = expectation(description: "task cancellation forwarded")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var partialOutput: URL?
        let fake = FakeExtractor { _, output, _, token, _ in
            partialOutput = try Self.writeImage(to: output).first
            entered.fulfill()
            _ = release.wait(timeout: .now() + 10)
            try token.checkCancellation()
            return [partialOutput!]
        }
        let coordinator = ArchiveImportCoordinator(rootDirectory: files.root, extractor: fake)
        coordinator.onStateChange = { if case .cancelling = $0 { cancelling.fulfill() } }
        let importing = Task { await coordinator.beginImport(from: files.source) }
        await fulfillment(of: [entered], timeout: 5)
        importing.cancel()
        await fulfillment(of: [cancelling], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(partialOutput).path))
        release.signal()
        await importing.value
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(partialOutput).path))
    }

    @MainActor
    func testCancellationAfterCommitCannotHideCompletedImport() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.base) }
        let committed = expectation(description: "cache directory committed")
        let cancelling = expectation(description: "late cancellation requested")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let manager = CommitGateFileManager()
        manager.afterCommitRename = {
            committed.fulfill()
            _ = release.wait(timeout: .now() + 10)
        }
        let store = ArchiveCacheStore(cacheDirectory: files.base.appendingPathComponent("retained"),
                                      supportDirectory: files.base.appendingPathComponent("catalog"),
                                      fileManager: manager)
        let fake = FakeExtractor { _, output, _, _, _ in try Self.writeImage(to: output) }
        let coordinator = ArchiveImportCoordinator(rootDirectory: files.root, extractor: fake, cacheStore: store)
        coordinator.onStateChange = { if case .cancelling = $0 { cancelling.fulfill() } }
        let importing = Task { await coordinator.beginImport(from: files.source) }
        await fulfillment(of: [committed], timeout: 5)
        let cancel = Task { await coordinator.cancel() }
        await fulfillment(of: [cancelling], timeout: 5)
        release.signal()
        await importing.value
        await cancel.value
        guard case .completed(let images) = coordinator.state else {
            return XCTFail("A durable import must remain completed after late cancellation")
        }
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertTrue(images.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let session = try XCTUnwrap(coordinator.takePreparedSession())
        XCTAssertEqual(try store.list().map(\.id), [session.archiveID])
        session.release()
    }

    @MainActor
    func testCancelDuringCopyKeepsSecurityScopeUntilCopyReturns() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.base) }
        let entered = expectation(description: "copy entered")
        let cancelling = expectation(description: "cancel requested")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let lock = NSLock()
        var scopeOpen = false
        var decoded = false
        var access = ArchiveImportCoordinator.SourceAccess()
        access.start = { _ in lock.withLock { scopeOpen = true }; return true }
        access.stop = { _ in lock.withLock { scopeOpen = false } }
        access.copy = { source, destination in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 10)
            XCTAssertTrue(lock.withLock { scopeOpen })
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let fake = FakeExtractor { _, output, _, _, _ in
            decoded = true
            return try Self.writeImage(to: output)
        }
        let coordinator = ArchiveImportCoordinator(rootDirectory: files.root, extractor: fake, sourceAccess: access)
        coordinator.onStateChange = { if case .cancelling = $0 { cancelling.fulfill() } }
        let importing = Task { await coordinator.beginImport(from: files.source) }
        await fulfillment(of: [entered], timeout: 5)
        let cancel = Task { await coordinator.cancel() }
        await fulfillment(of: [cancelling], timeout: 5)
        XCTAssertTrue(lock.withLock { scopeOpen })
        release.signal()
        await cancel.value
        await importing.value
        XCTAssertFalse(lock.withLock { scopeOpen })
        XCTAssertFalse(decoded)
        XCTAssertFalse(coordinator.isBusy)
    }

    @MainActor
    func testLateProgressFromOldAttemptCannotChangeCompletedState() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.base) }
        var oldProgress: ((ArchiveImportProgress) -> Void)?
        let fake = FakeExtractor { _, output, password, _, progress in
            if password == nil {
                oldProgress = progress
                throw ArchiveImportError.passwordRequired
            }
            return try Self.writeImage(to: output)
        }
        let coordinator = ArchiveImportCoordinator(rootDirectory: files.root, extractor: fake)
        await coordinator.beginImport(from: files.source)
        await coordinator.submitPassword("")
        oldProgress?(ArchiveImportProgress(stage: .extracting, fractionCompleted: 0.9))
        // Let the main-actor progress callback run before checking the stable published result.
        await Task.yield()
        guard case .completed = coordinator.state else { return XCTFail("Stale progress changed state") }
    }
}
