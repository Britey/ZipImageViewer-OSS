import XCTest
@testable import ZipImageViewer

final class ArchiveCacheStoreTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var store: ArchiveCacheStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "ArchiveCacheStoreTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        store = newStore()
    }

    override func tearDownWithError() throws {
        // Drain release callbacks before deleting their filesystem.
        _ = try? store.list()
        store = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testRelaunchRestoresRelativePositionWithoutOriginalSource() throws {
        let session = try publish("a")
        let id = session.archiveID
        try store.saveProgress(archiveID: id, relativePath: "nested/2.png", index: 1)
        session.release()
        _ = try store.list()
        try FileManager.default.removeItem(at: root.appendingPathComponent("input-a"))
        let reopened = try newStore().acquire(id: id)
        XCTAssertEqual(reopened.position.relativePath, "nested/2.png")
        XCTAssertEqual(reopened.restoredIndex(in: reopened.imageURLs.reversed()), 0)
        XCTAssertTrue(reopened.imageURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        reopened.release()
    }

    func testCountLimitProtectsAllLeasesThenEvictsLeastRecentOnRelease() throws {
        try store.updatePreferences(ArchiveCachePreferences(maximumArchiveCount: 1))
        let a = try publish("a")
        let b = try publish("b")
        XCTAssertEqual(try store.list().count, 2)
        a.release()
        XCTAssertEqual(try store.list().map(\.id), [b.archiveID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.imageURLs[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.imageURLs[0].path))
        b.release()
    }

    func testEvictionPreviewMatchesExecutionWithoutMutatingPreferencesOrCatalog() throws {
        let a = try publish("a")
        a.release()
        let b = try publish("b")
        b.release()
        let c = try publish("c")
        c.release()
        let previous = store.preferences
        let before = try store.list().map(\.id)
        let proposed = ArchiveCachePreferences(maximumArchiveCount: 1)
        let preview = try store.evictionImpact(for: proposed)
        XCTAssertEqual(preview.archiveIDs, [a.archiveID, b.archiveID])
        XCTAssertEqual(preview.displayNames, ["a.zip", "b.zip"])
        XCTAssertEqual(preview.count, 2)
        XCTAssertGreaterThan(preview.retainedBytes, 0)
        XCTAssertEqual(store.preferences, previous)
        XCTAssertEqual(try store.list().map(\.id), before)
        try store.updatePreferences(proposed)
        XCTAssertEqual(Set(before).subtracting(try store.list().map(\.id)), Set(preview.archiveIDs))
    }

    func testEvictionPreviewRespectsActualReaderLeasesAndByteLimits() throws {
        let a = try publish("a")
        a.release()
        let b = try publish("b")
        let proposed = ArchiveCachePreferences(maximumBytes: 1)
        XCTAssertEqual(try store.evictionImpact(for: proposed).archiveIDs, [a.archiveID])
        b.release()
        XCTAssertEqual(try store.evictionImpact(for: proposed).archiveIDs, [a.archiveID, b.archiveID])
        try store.updatePreferences(proposed)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testConfirmedQuotaRejectsChangedVictimsAtomically() throws {
        let a = try publish("a"); a.release()
        let b = try publish("b"); b.release()
        let proposed = ArchiveCachePreferences(maximumArchiveCount: 1)
        let preview = try store.evictionImpact(for: proposed)
        let protection = try store.acquire(id: a.archiveID)
        let before = store.preferences
        let changed = try XCTUnwrap(store.applyPreferences(proposed, confirmedArchiveIDs: preview.archiveIDs))
        XCTAssertEqual(store.preferences, before)
        XCTAssertEqual(Set(try store.list().map(\.id)), Set([a.archiveID, b.archiveID]))
        XCTAssertNotEqual(changed.archiveIDs, preview.archiveIDs)
        XCTAssertNil(try store.applyPreferences(proposed, confirmedArchiveIDs: changed.archiveIDs))
        XCTAssertEqual(store.preferences, proposed)
        XCTAssertEqual(try store.list().map(\.id), [a.archiveID])
        protection.release()
    }

    func testInvalidEvictionPreviewPreservesPreferences() throws {
        let before = store.preferences
        XCTAssertThrowsError(try store.evictionImpact(for: ArchiveCachePreferences(maximumBytes: 0)))
        XCTAssertThrowsError(try store.evictionImpact(for: ArchiveCachePreferences(maximumArchiveCount: 0)))
        XCTAssertEqual(store.preferences, before)
    }

    func testReaderSessionPreservesArchiveDisplayNameOnReopen() throws {
        let session = try publish("My Book 日本語")
        XCTAssertEqual(session.displayName, "My Book 日本語.zip")
        session.release()
        let reopened = try newStore().acquire(id: session.archiveID)
        defer { reopened.release() }
        XCTAssertEqual(reopened.displayName, session.displayName)
    }

    func testOversizedArchiveDoesNotDisplaceExistingCache() throws {
        let a = try publish("a")
        a.release()
        let bytes = try XCTUnwrap(store.list().first?.retainedBytes)
        try store.updatePreferences(ArchiveCachePreferences(maximumBytes: bytes + 4096))
        let b = try publish("b", imageBytes: Int(bytes + 8192))
        XCTAssertTrue(b.isTemporary)
        XCTAssertEqual(try store.list().map(\.id), [a.archiveID])
        b.release()
        XCTAssertEqual(try store.list().map(\.id), [a.archiveID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.imageURLs[0].path))
    }

    func testMissingFilesProduceUnavailableRowAndCacheMiss() throws {
        let a = try publish("a")
        a.release()
        _ = try store.list()
        try FileManager.default.removeItem(at: a.imageURLs[0])
        XCTAssertFalse(try XCTUnwrap(store.list().first).isAvailable)
        XCTAssertNil(try store.acquire(signature: "source-a|digest-a"))
        XCTAssertThrowsError(try store.acquire(id: a.archiveID))
    }

    func testRemoveAndClearDeferUntilAllLeasesRelease() throws {
        let a = try publish("a")
        let second = try store.acquire(id: a.archiveID)
        try store.clear()
        XCTAssertTrue(try store.list().isEmpty)
        a.release()
        _ = try store.list()
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.imageURLs[0].path))
        second.release()
        XCTAssertEqual(try store.usage().totalBytes, 0)
    }

    func testCorruptCatalogRebuildsCompletedManifests() throws {
        let a = try publish("a")
        a.release()
        _ = try store.list()
        try Data("broken".utf8).write(to: root.appendingPathComponent("support/recent-archives.json"))
        XCTAssertEqual(try newStore().list().map(\.id), [a.archiveID])
    }

    func testUnsafeOrCancelledPublicationPreservesPreviousArchive() throws {
        let a = try publish("a")
        a.release()
        let outside = root.appendingPathComponent("outside.png")
        try Data([1]).write(to: outside)
        XCTAssertThrowsError(try store.publish(images: [outside], imageRoot: root.appendingPathComponent("input-a"),
            displayName: "bad", sourceIdentity: "source-a", signature: "new", format: "zip"))
        XCTAssertThrowsError(try store.publish(images: [outside], imageRoot: root,
            displayName: "cancel", sourceIdentity: "source-a", signature: "new", format: "zip",
            cancellation: { throw CocoaError(.userCancelled) }))
        XCTAssertEqual(try store.list().map(\.id), [a.archiveID])
    }

    func testNewerCatalogIsPreserved() throws {
        _ = try store.list()
        let url = root.appendingPathComponent("support/recent-archives.json")
        let data = Data("{\"schemaVersion\":99}".utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try newStore().list())
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testPreferencesPersistAndAcquireUpdatesLRUOrder() throws {
        let a = try publish("a")
        a.release()
        let b = try publish("b")
        b.release()
        let reopened = try store.acquire(id: a.archiveID)
        reopened.release()
        XCTAssertEqual(try store.list().map(\.id), [a.archiveID, b.archiveID])
        let limits = ArchiveCachePreferences(maximumBytes: 500_000_000, maximumArchiveCount: 1)
        try store.updatePreferences(limits)
        XCTAssertEqual(try store.list().map(\.id), [a.archiveID])
        XCTAssertEqual(newStore().preferences, limits)
    }

    func testPartialCacheAndCorruptOrphanDirectoryAreReclaimed() throws {
        let a = try publish("a")
        a.release()
        _ = try store.list()
        try FileManager.default.removeItem(at: a.imageURLs[0])
        XCTAssertFalse(try XCTUnwrap(store.list().first).isAvailable)
        XCTAssertEqual(try store.usage().totalBytes, 0)
        let orphan = root.appendingPathComponent("cache/archives/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: orphan.appendingPathComponent("partial.png"))
        let recovered = newStore()
        _ = try recovered.list()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try recovered.usage().totalBytes, 0)
    }

    func testDeletionFailureRemainsAccountedAndRetried() throws {
        let manager = FailingDeletionFileManager()
        store = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
            supportDirectory: root.appendingPathComponent("support"), defaults: defaults, fileManager: manager)
        let a = try publish("a")
        a.release()
        _ = try store.list()
        manager.failDeletion = true
        XCTAssertThrowsError(try store.clear())
        XCTAssertGreaterThan(try store.usage().pendingDeletionBytes, 0)
        XCTAssertTrue(try store.list().isEmpty)
        manager.failDeletion = false
        _ = try store.list()
        XCTAssertEqual(try store.usage().totalBytes, 0)
    }

    func testFailedDeferredRemovalRetriesOnLaterList() throws {
        let manager = FailingDeletionFileManager()
        store = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
            supportDirectory: root.appendingPathComponent("support"), defaults: defaults, fileManager: manager)
        let session = try publish("a")
        try store.remove(id: session.archiveID)
        manager.failRetirementMoves = true
        session.release()
        // usage drains the release callback without itself retrying the failed move.
        XCTAssertGreaterThan(try store.usage().totalBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.imageURLs[0].path))
        manager.failRetirementMoves = false
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertEqual(try store.usage().totalBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.imageURLs[0].path))
    }

    func testInterruptedReplacementKeepsNewSnapshotWhenClockMovesBackward() throws {
        var time = Date(timeIntervalSince1970: 2_000)
        store = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
            supportDirectory: root.appendingPathComponent("support"), defaults: defaults, now: { time })
        let old = try publish("old", sourceIdentity: "same-source")
        old.release()
        _ = try store.list()
        let catalogURL = root.appendingPathComponent("support/recent-archives.json")
        let oldCatalog = try JSONDecoder().decode(ArchiveCacheCatalog.self, from: Data(contentsOf: catalogURL))
        let oldDirectory = root.appendingPathComponent("cache/archives/\(old.archiveID.uuidString)")
        let backup = root.appendingPathComponent("old-snapshot-backup")
        try FileManager.default.copyItem(at: oldDirectory, to: backup)

        time = Date(timeIntervalSince1970: 1_000)
        let replacement = try publish("new", sourceIdentity: "same-source")
        replacement.release()
        _ = try store.list()
        // Recreate termination immediately after the new catalog commit, before
        // the previous source record and directory were retired.
        try FileManager.default.copyItem(at: backup, to: oldDirectory)
        var interrupted = try JSONDecoder().decode(ArchiveCacheCatalog.self, from: Data(contentsOf: catalogURL))
        interrupted.records.append(try XCTUnwrap(oldCatalog.records.first))
        try JSONEncoder().encode(interrupted).write(to: catalogURL, options: .atomic)

        let recovered = newStore()
        XCTAssertEqual(try recovered.list().map(\.id), [replacement.archiveID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.imageURLs[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.imageURLs[0].path))
    }

    func testLostCatalogReconstructsOrderFromImportDates() throws {
        let manager = FailingDeletionFileManager()
        var time = Date(timeIntervalSince1970: 1_000)
        store = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
            supportDirectory: root.appendingPathComponent("support"), defaults: defaults,
            fileManager: manager, now: { time })
        let old = try publish("old")
        old.release()
        _ = try store.list()
        time = Date(timeIntervalSince1970: 2_000)
        let latest = try publish("latest")
        latest.release()
        _ = try store.list()
        // Force enumeration newest-first: assigning sequence numbers in that
        // order would incorrectly make the oldest archive most recently opened.
        manager.archiveDirectoryOrder = [latest.archiveID.uuidString, old.archiveID.uuidString]
        try Data("corrupt catalog".utf8).write(to: root.appendingPathComponent("support/recent-archives.json"))
        let recovered = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
            supportDirectory: root.appendingPathComponent("support"), defaults: defaults, fileManager: manager)
        XCTAssertEqual(try recovered.list().map(\.id), [latest.archiveID, old.archiveID])
    }

    func testFailedPublicationCleansStagingAndPreservesCompletedEntry() throws {
        let manager = FailingDeletionFileManager()
        store = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
            supportDirectory: root.appendingPathComponent("support"), defaults: defaults, fileManager: manager)
        let a = try publish("a")
        a.release()
        manager.failCopies = true
        XCTAssertThrowsError(try publish("b"))
        XCTAssertEqual(try store.list().map(\.id), [a.archiveID])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache/staging").path).isEmpty)
    }

    func testSymlinkImagesAreRejectedWithoutPublishing() throws {
        let input = root.appendingPathComponent("symlink-input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("real.png")
        try Data([1]).write(to: outside)
        let link = input.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try store.publish(images: [link], imageRoot: input, displayName: "unsafe.zip",
            sourceIdentity: "unsafe", signature: "unsafe|digest", format: "zip"))
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testResolvedExtractorOutputMatchesAliasedWorkspaceAncestor() throws {
        let workspace = root.appendingPathComponent("workspace")
        let input = workspace.appendingPathComponent("extraction")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("workspace-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace)
        let requestedRoot = alias.appendingPathComponent("extraction")
        // The 7z extractor returns canonical URLs, whereas its caller keeps the
        // requested directory URL (for example /var versus /private/var on iOS).
        let image = requestedRoot.resolvingSymlinksInPath().appendingPathComponent("page.png")
        try Data([1]).write(to: image)
        let session = try store.publish(images: [image], imageRoot: requestedRoot,
            displayName: "book.7z", sourceIdentity: "book", signature: "book|digest", format: "7z")
        defer { session.release() }
        XCTAssertEqual(session.relativePath(for: session.imageURLs[0]), "page.png")
        XCTAssertEqual(try Data(contentsOf: session.imageURLs[0]), Data([1]))
    }

    func testSymlinkDirectoryInsideExtractionIsStillRejected() throws {
        let input = root.appendingPathComponent("input-with-link")
        let outside = root.appendingPathComponent("outside-images")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([1]).write(to: outside.appendingPathComponent("page.png"))
        let link = input.appendingPathComponent("chapter")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try store.publish(images: [link.appendingPathComponent("page.png")], imageRoot: input,
            displayName: "unsafe.7z", sourceIdentity: "unsafe", signature: "unsafe|digest", format: "7z"))
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testCompressionToggleDoesNotRetryFailedLimitEviction() throws {
        let manager = FailingDeletionFileManager()
        store = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
            supportDirectory: root.appendingPathComponent("support"), defaults: defaults, fileManager: manager)
        let a = try publish("a")
        a.release()
        let b = try publish("b")
        b.release()
        _ = try store.list()
        manager.failRetirementMoves = true
        XCTAssertThrowsError(try store.updatePreferences(ArchiveCachePreferences(maximumArchiveCount: 1)))
        manager.failRetirementMoves = false
        var preferences = store.preferences
        preferences.compressExtractedImages = true
        try store.updatePreferences(preferences)
        XCTAssertTrue(store.preferences.compressExtractedImages)
        XCTAssertEqual(try store.list().count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.imageURLs[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.imageURLs[0].path))
        // A subsequent actual limit change still applies the normal eviction policy.
        preferences.maximumArchiveCount = 2
        try store.updatePreferences(preferences)
        preferences.maximumArchiveCount = 1
        try store.updatePreferences(preferences)
        XCTAssertEqual(try store.list().map(\.id), [b.archiveID])
    }

    func testCompressionToggleOnUnloadedStoreDoesNotRunStartupEviction() throws {
        let a = try publish("a")
        a.release()
        let b = try publish("b")
        b.release()
        _ = try store.list()
        let catalogURL = root.appendingPathComponent("support/recent-archives.json")
        let catalogBeforeToggle = try Data(contentsOf: catalogURL)
        // Recreate deferred limit enforcement at startup, before any cache access.
        defaults.set(try JSONEncoder().encode(ArchiveCachePreferences(maximumArchiveCount: 1)),
                     forKey: "archiveCache.preferences.v1")
        let unloaded = newStore()
        var preferences = unloaded.preferences
        preferences.compressExtractedImages = true
        try unloaded.updatePreferences(preferences)
        XCTAssertEqual(try Data(contentsOf: catalogURL), catalogBeforeToggle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.imageURLs[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.imageURLs[0].path))
        XCTAssertTrue(newStore().preferences.compressExtractedImages)
        XCTAssertEqual(try unloaded.list().map(\.id), [b.archiveID])
    }

    func testLegacyPreferencesPreserveLimitsAndDefaultCompressionOff() throws {
        defaults.set(Data("{\"maximumBytes\":123456789,\"maximumArchiveCount\":7}".utf8),
                     forKey: "archiveCache.preferences.v1")
        let preferences = newStore().preferences
        XCTAssertEqual(preferences.maximumBytes, 123456789)
        XCTAssertEqual(preferences.maximumArchiveCount, 7)
        XCTAssertFalse(preferences.compressExtractedImages)
        try store.updatePreferences(ArchiveCachePreferences(maximumBytes: 123456789,
            maximumArchiveCount: 7, compressExtractedImages: true))
        XCTAssertTrue(newStore().preferences.compressExtractedImages)
    }

    func testPreparedPagesKeepOriginalIdentityAcrossSortingResumeAndRecovery() throws {
        let input = try preparedInput()
        let pages = [
            ArchivePreparedPage(originalRelativePath: "chapter/10.png", storedRelativePath: ".prepared/a.jxl",
                previewRelativePath: ".prepared/preview.jpg", modificationDate: Date(timeIntervalSince1970: 100)),
            ArchivePreparedPage(originalRelativePath: "chapter/2.jpg", storedRelativePath: ".prepared/z.jxl",
                modificationDate: Date(timeIntervalSince1970: 200))
        ]
        let session = try publishPrepared(pages, input: input)
        XCTAssertEqual(session.previewURLs.count, 1)
        let sorted = ImageFileSorter.sort(session.imageURLs, criterion: .filename, order: .ascending,
                                          metadata: session.pageMetadata)
        XCTAssertEqual(sorted.map { session.relativePath(for: $0)! }, ["chapter/2.jpg", "chapter/10.png"])
        let dates = ImageFileSorter.sort(session.imageURLs, criterion: .modifiedDate, order: .ascending,
                                         metadata: session.pageMetadata)
        XCTAssertEqual(dates, session.imageURLs)
        try store.saveProgress(archiveID: session.archiveID, relativePath: "chapter/2.jpg", index: 1)
        XCTAssertThrowsError(try store.saveProgress(archiveID: session.archiveID, relativePath: ".prepared/z.jxl", index: 1))
        session.release()
        _ = try store.list()
        let reopened = try newStore().acquire(id: session.archiveID)
        XCTAssertEqual(reopened.restoredIndex(in: reopened.imageURLs.reversed()), 0)
        XCTAssertEqual(reopened.pageMetadata[reopened.imageURLs[0]], pages[0])
        reopened.release()
        try Data("broken".utf8).write(to: root.appendingPathComponent("support/recent-archives.json"))
        let recovered = try newStore().acquire(id: session.archiveID)
        XCTAssertEqual(recovered.relativePath(for: recovered.imageURLs[0]), "chapter/10.png")
        XCTAssertEqual(recovered.previewURLs.count, 1)
        recovered.release()
    }

    func testMissingPreviewDoesNotInvalidateDetailedCacheAndClearRemovesItAll() throws {
        let input = try preparedInput()
        let session = try publishPrepared([
            ArchivePreparedPage(originalRelativePath: "1.png", storedRelativePath: ".prepared/a.jxl",
                                previewRelativePath: ".prepared/preview.jpg")
        ], input: input)
        let preview = try XCTUnwrap(session.previewURLs.values.first)
        session.release()
        _ = try store.list()
        try FileManager.default.removeItem(at: preview)
        let reopened = try newStore().acquire(id: session.archiveID)
        XCTAssertTrue(reopened.previewURLs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.imageURLs[0].path))
        reopened.release()
        try store.clear()
        XCTAssertEqual(try store.usage().totalBytes, 0)
    }

    func testPreviewsCountTowardFinalOversizeDecision() throws {
        let baseline = try publish("baseline")
        baseline.release()
        let originalBytes = try XCTUnwrap(store.list().first?.retainedBytes)
        try store.updatePreferences(ArchiveCachePreferences(maximumBytes: originalBytes + 16384))
        let input = try preparedInput(previewBytes: 1024 * 1024)
        let session = try publishPrepared([
            ArchivePreparedPage(originalRelativePath: "1.png", storedRelativePath: ".prepared/a.jxl",
                                previewRelativePath: ".prepared/preview.jpg")
        ], input: input)
        XCTAssertTrue(session.isTemporary)
        XCTAssertGreaterThan(try store.usage().retainedBytes, 1024 * 1024)
        XCTAssertEqual(try store.list().map(\.id), [baseline.archiveID])
        session.release()
        XCTAssertEqual(try store.list().map(\.id), [baseline.archiveID])
    }

    func testImageWorkLeaseDefersDeletionAndReleasesExactlyOnce() throws {
        let session = try publish("leased")
        let finishFirst = session.retainForImageWork()
        let finishSecond = session.retainForImageWork()
        try store.remove(id: session.archiveID)
        session.release()
        finishFirst()
        finishFirst()
        _ = try store.list()
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.imageURLs[0].path))
        finishSecond()
        finishSecond()
        XCTAssertEqual(try store.usage().totalBytes, 0)
        session.retainForImageWork()()
        XCTAssertEqual(try store.usage().totalBytes, 0)
    }

    func testLegacyCacheOpensWithoutChangingItsManifestOrImages() throws {
        let session = try publish("legacy")
        session.release()
        _ = try store.list()
        let manifestURL = root.appendingPathComponent("cache/archives/\(session.archiveID)/manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["schemaVersion"] = 1
        manifest["relativeImagePaths"] = ["1.png", "nested/2.png"]
        manifest.removeValue(forKey: "pages")
        let legacyData = try JSONSerialization.data(withJSONObject: manifest)
        try legacyData.write(to: manifestURL)
        let catalogURL = root.appendingPathComponent("support/recent-archives.json")
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        var records = try XCTUnwrap(catalog["records"] as? [[String: Any]])
        records[0]["manifest"] = manifest
        catalog["records"] = records
        catalog["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: catalog).write(to: catalogURL)
        let reopened = try newStore().acquire(id: session.archiveID)
        XCTAssertEqual(reopened.imageURLs, session.imageURLs)
        XCTAssertTrue(reopened.previewURLs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: manifestURL), legacyData)
        XCTAssertEqual(try Data(contentsOf: reopened.imageURLs[0]), Data(repeating: 1, count: 16))
        reopened.release()
    }

    func testPreparedPathCollisionsAndTraversalAreRejected() throws {
        let input = try preparedInput()
        let badPaths = ["../escape.jpg", "/absolute.jpg", ".prepared/../escape.jpg", ".prepared/a.jxl/child.jpg"]
        for path in badPaths {
            XCTAssertThrowsError(try publishPrepared([
                ArchivePreparedPage(originalRelativePath: "1.png", storedRelativePath: ".prepared/a.jxl", previewRelativePath: path)
            ], input: input))
        }
        XCTAssertThrowsError(try publishPrepared([
            ArchivePreparedPage(originalRelativePath: "1.png", storedRelativePath: ".prepared/a.jxl"),
            ArchivePreparedPage(originalRelativePath: "2.png", storedRelativePath: ".prepared/A.JXL")
        ], input: input))
        XCTAssertThrowsError(try publishPrepared([
            ArchivePreparedPage(originalRelativePath: "1.png", storedRelativePath: ".prepared/a.jxl", previewRelativePath: ".prepared/a.jxl")
        ], input: input))
        let outside = root.appendingPathComponent("outside-previews")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([1]).write(to: outside.appendingPathComponent("preview.jpg"))
        try FileManager.default.createSymbolicLink(at: input.appendingPathComponent("linked"), withDestinationURL: outside)
        XCTAssertThrowsError(try publishPrepared([
            ArchivePreparedPage(originalRelativePath: "1.png", storedRelativePath: ".prepared/a.jxl", previewRelativePath: "linked/preview.jpg")
        ], input: input))
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testCancelledPreparedCopyCleansDetailedAndPreviewStaging() throws {
        let input = try preparedInput()
        var checks = 0
        XCTAssertThrowsError(try store.publish(preparedPages: [
            ArchivePreparedPage(originalRelativePath: "1.png", storedRelativePath: ".prepared/a.jxl", previewRelativePath: ".prepared/preview.jpg")
        ], imageRoot: input, displayName: "cancel", sourceIdentity: "cancel", signature: "cancel", format: "zip",
            cancellation: {
                checks += 1
                if checks == 3 { throw CocoaError(.userCancelled) }
            }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache/staging").path).isEmpty)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testMetadataMissingDatesDoNotUseGeneratedFileDates() throws {
        let input = try preparedInput()
        let a = input.appendingPathComponent(".prepared/a.jxl")
        let z = input.appendingPathComponent(".prepared/z.jxl")
        let metadata = [
            a: ArchivePreparedPage(originalRelativePath: "2.png", storedRelativePath: ".prepared/a.jxl"),
            z: ArchivePreparedPage(originalRelativePath: "1.jpg", storedRelativePath: ".prepared/z.jxl")
        ]
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: a.path)
        for criterion in [SortCriterion.filename, .modifiedDate, .createdDate] {
            XCTAssertEqual(ImageFileSorter.sort([a, z], criterion: criterion, order: .ascending, metadata: metadata), [z, a])
        }
    }

    private func preparedInput(previewBytes: Int = 64) throws -> URL {
        let input = root.appendingPathComponent("prepared-\(UUID())")
        let generated = input.appendingPathComponent(".prepared")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        for name in ["a.jxl", "z.jxl"] { try Data([1, 2, 3]).write(to: generated.appendingPathComponent(name)) }
        try Data(repeating: 3, count: previewBytes).write(to: generated.appendingPathComponent("preview.jpg"))
        return input
    }

    private func publishPrepared(_ pages: [ArchivePreparedPage], input: URL) throws -> ArchiveReaderSession {
        try store.publish(preparedPages: pages, imageRoot: input, displayName: "prepared.zip",
                          sourceIdentity: "prepared", signature: "prepared-signature", format: "zip")
    }

    private func newStore() -> ArchiveCacheStore {
        ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
            supportDirectory: root.appendingPathComponent("support"), defaults: defaults)
    }

    private func publish(_ name: String, imageBytes: Int = 16,
                         sourceIdentity: String? = nil) throws -> ArchiveReaderSession {
        let directory = root.appendingPathComponent("input-\(name)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("1.png")
        let second = directory.appendingPathComponent("nested/2.png")
        // Cache integrity validates filesystem structure; a corrupt bitmap remains a valid reader placeholder.
        try Data(repeating: 1, count: imageBytes).write(to: first)
        try Data(repeating: 2, count: imageBytes).write(to: second)
        let identity = sourceIdentity ?? "source-\(name)"
        return try store.publish(images: [first, second], imageRoot: directory, displayName: "\(name).zip",
            sourceIdentity: identity, signature: "\(identity)|digest-\(name)", format: "zip")
    }
}

private final class FailingDeletionFileManager: FileManager, @unchecked Sendable {
    var failDeletion = false
    var failCopies = false
    var failRetirementMoves = false
    var archiveDirectoryOrder: [String]?

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if failRetirementMoves && dstURL.deletingLastPathComponent().lastPathComponent == "pending-deletion" {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                     options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        let entries = try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        guard url.lastPathComponent == "archives", let order = archiveDirectoryOrder else { return entries }
        return entries.sorted {
            (order.firstIndex(of: $0.lastPathComponent) ?? order.count)
                < (order.firstIndex(of: $1.lastPathComponent) ?? order.count)
        }
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if failCopies { throw CocoaError(.fileWriteOutOfSpace) }
        try super.copyItem(at: srcURL, to: dstURL)
    }
    override func removeItem(at URL: URL) throws {
        if failDeletion && URL.deletingLastPathComponent().lastPathComponent == "pending-deletion" {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}
