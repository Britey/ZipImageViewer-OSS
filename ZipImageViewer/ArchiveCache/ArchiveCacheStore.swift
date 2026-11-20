import Foundation
import ImageIO
import UniformTypeIdentifiers

/// All filesystem ownership is serialized here. Call public filesystem methods on a worker.
final class ArchiveCacheStore: @unchecked Sendable {
    static let shared = ArchiveCacheStore()
    private let queue = DispatchQueue(label: "ZipImageViewer.ArchiveCacheStore", qos: .userInitiated)
    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let supportDirectory: URL
    private let defaults: UserDefaults
    private let now: () -> Date
    private var catalog = ArchiveCacheCatalog()
    private var loaded = false
    private var leases: [UUID: Int] = [:]
    private var deferredRemoval: Set<UUID> = []
    private var invalidResiduals: Set<UUID> = []
    private var settings: ArchiveCachePreferences
    private static let preferencesKey = "archiveCache.preferences.v1"
    private var archivesDirectory: URL { cacheDirectory.appendingPathComponent("archives", isDirectory: true) }
    private var stagingDirectory: URL { cacheDirectory.appendingPathComponent("staging", isDirectory: true) }
    private var pendingDirectory: URL { cacheDirectory.appendingPathComponent("pending-deletion", isDirectory: true) }
    private var catalogURL: URL { supportDirectory.appendingPathComponent("recent-archives.json") }

    convenience init() {
        let manager = FileManager.default
        self.init(cacheDirectory: manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZipImageViewer", isDirectory: true),
                  supportDirectory: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZipImageViewer", isDirectory: true))
    }

    init(cacheDirectory: URL, supportDirectory: URL, defaults: UserDefaults = .standard,
         fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.cacheDirectory = cacheDirectory
        self.supportDirectory = supportDirectory
        self.defaults = defaults
        self.fileManager = fileManager
        self.now = now
        if let data = defaults.data(forKey: Self.preferencesKey),
           let value = try? JSONDecoder().decode(ArchiveCachePreferences.self, from: data),
           value.maximumBytes > 0, value.maximumArchiveCount.map({ $0 > 0 }) ?? true {
            settings = value
        } else { settings = ArchiveCachePreferences() }
    }

    var preferences: ArchiveCachePreferences { queue.sync { settings } }

    func list() throws -> [CachedArchiveSummary] {
        try queue.sync {
            try ensureLoaded()
            try reconcile()
            try? finishDeferredRemovals()
            try? retryPendingDeletion()
            return catalog.records.filter { $0.isVisible && !$0.manifest.isTemporary }
                .sorted { $0.accessSequence > $1.accessSequence }.map { record in
                    let thumbnail = entryDirectory(record.manifest.id).appendingPathComponent("thumbnail.jpg")
                    return CachedArchiveSummary(id: record.manifest.id, displayName: record.manifest.displayName,
                        format: record.manifest.format, imageCount: record.manifest.relativeImagePaths.count,
                        lastOpenedAt: record.lastOpenedAt, position: record.position,
                        isAvailable: record.isAvailable,
                        thumbnailURL: record.isAvailable && fileManager.fileExists(atPath: thumbnail.path) ? thumbnail : nil,
                        retainedBytes: record.isAvailable ? record.manifest.retainedBytes : 0)
                }
        }
    }

    /// Read the small generated JPEG while the same queue excludes eviction.
    /// This does not open a reader or change recency/reading progress.
    func thumbnailData(id: UUID) throws -> Data? {
        try queue.sync {
            try ensureLoaded()
            guard catalog.records.contains(where: { $0.manifest.id == id && $0.isAvailable && $0.isVisible }),
                  !deferredRemoval.contains(id) else { return nil }
            let file = entryDirectory(id).appendingPathComponent("thumbnail.jpg")
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let size = attributes.fileSize, size > 0, size <= 2 * 1024 * 1024 else { return nil }
            return try Data(contentsOf: file)
        }
    }

    func usage() throws -> ArchiveCacheUsage {
        try queue.sync {
            try ensureLoaded()
            // Include temporary/deferred entries in physical usage even when absent from the recent list.
            let bytes = try directoryBytes(archivesDirectory)
            let pending = try directoryBytes(pendingDirectory)
            let count = catalog.records.filter { $0.isAvailable && !$0.manifest.isTemporary }.count
            return ArchiveCacheUsage(retainedBytes: bytes, archiveCount: count, pendingDeletionBytes: pending)
        }
    }

    func acquire(signature: String) throws -> ArchiveReaderSession? {
        try queue.sync {
            try ensureLoaded()
            guard let index = catalog.records.firstIndex(where: {
                $0.manifest.signature == signature && $0.isAvailable && $0.isVisible && !deferredRemoval.contains($0.manifest.id)
            }) else { return nil }
            do { return try acquireRecord(at: index) }
            catch ArchiveCacheError.unavailable { return nil }
        }
    }

    func acquire(id: UUID) throws -> ArchiveReaderSession {
        try queue.sync {
            try ensureLoaded()
            guard let index = catalog.records.firstIndex(where: {
                $0.manifest.id == id && $0.isAvailable && $0.isVisible && !deferredRemoval.contains(id)
            }) else { throw ArchiveCacheError.unavailable }
            return try acquireRecord(at: index)
        }
    }

    /// Copies validated images into a private completion transaction. Callers retain ownership of input staging.
    func publish(images: [URL], imageRoot: URL? = nil, displayName: String,
                 sourceIdentity: String, signature: String, format: String,
                 cancellation: (() throws -> Void)? = nil) throws -> ArchiveReaderSession {
        guard !images.isEmpty else { throw ArchiveCacheError.noImages }
        let requestedRoot = (imageRoot ?? commonRoot(of: images)).standardizedFileURL
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        let pages = try images.map { image -> ArchivePreparedPage in
            let imagePath = image.standardizedFileURL.path
            guard let prefix = [requestedRoot.path + "/", root.path + "/"].first(where: {
                imagePath.hasPrefix($0)
            }) else { throw ArchiveCacheError.invalidPath }
            let relative = String(imagePath.dropFirst(prefix.count))
            let values = try image.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            return ArchivePreparedPage(originalRelativePath: relative, storedRelativePath: relative,
                creationDate: values.creationDate, modificationDate: values.contentModificationDate)
        }
        return try publish(preparedPages: pages, imageRoot: requestedRoot, displayName: displayName,
            sourceIdentity: sourceIdentity, signature: signature, format: format, cancellation: cancellation)
    }

    /// Publishes prepared render files and optional previews while preserving archive page identity.
    func publish(preparedPages: [ArchivePreparedPage], imageRoot: URL, displayName: String,
                 sourceIdentity: String, signature: String, format: String,
                 cancellation: (() throws -> Void)? = nil) throws -> ArchiveReaderSession {
        try queue.sync {
            try ensureLoaded()
            guard !preparedPages.isEmpty else { throw ArchiveCacheError.noImages }
            if let index = catalog.records.firstIndex(where: {
                $0.manifest.signature == signature && $0.isAvailable && $0.isVisible && !deferredRemoval.contains($0.manifest.id)
            }), let session = try? acquireRecord(at: index) { return session }
            let requestedRoot = imageRoot.standardizedFileURL
            // Resolve OS aliases only above the trusted extraction root. All archive-controlled
            // descendants are checked component by component, including preview directories.
            guard try requestedRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw ArchiveCacheError.invalidPath
            }
            let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
            try validatePagePaths(preparedPages, root: root)
            var pages: [ArchivePreparedPage] = []
            var sourceFiles: [(path: String, url: URL)] = []
            for var page in preparedPages {
                try cancellation?()
                sourceFiles.append((page.storedRelativePath, try validatedImage(page.storedRelativePath, root: root)))
                if let path = page.previewRelativePath {
                    do { sourceFiles.append((path, try validatedImage(path, root: root))) }
                    catch {
                        // An evicted or unsuccessful preview must not prevent a detailed page opening.
                        guard isMissingFile(error) else { throw error }
                        page.previewRelativePath = nil
                    }
                }
                pages.append(page)
            }
            let neededBytes = try sourceFiles.reduce(Int64(0)) { sum, file in
                sum + Int64(try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            if let available = try fileManager.attributesOfFileSystem(forPath: cacheDirectory.path)[.systemFreeSize] as? NSNumber,
               available.int64Value < neededBytes + 100_000_000 {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let id = UUID()
            let staging = stagingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            let destinationImages = staging.appendingPathComponent("images", isDirectory: true)
            try createDirectory(destinationImages)
            var committed = false
            defer { if !committed { try? fileManager.removeItem(at: staging) } }
            for file in sourceFiles {
                try cancellation?()
                let target = try safeURL(file.path, root: destinationImages)
                try createDirectory(target.deletingLastPathComponent())
                try fileManager.copyItem(at: file.url, to: target)
                try protect(target)
            }
            let cover = pages.sorted { $0.originalRelativePath.localizedStandardCompare($1.originalRelativePath) == .orderedAscending }[0]
            generateThumbnail(from: destinationImages.appendingPathComponent(cover.previewRelativePath ?? cover.storedRelativePath), in: staging)
            var manifest = ArchiveCacheManifest(id: id, displayName: displayName, format: format,
                sourceIdentity: sourceIdentity, signature: signature, importedAt: now(), pages: pages,
                retainedBytes: 0, isTemporary: false)
            let manifestURL = staging.appendingPathComponent("manifest.json")
            try write(manifest, to: manifestURL)
            manifest.retainedBytes = try directoryBytes(staging)
            manifest.isTemporary = manifest.retainedBytes > settings.maximumBytes
            try write(manifest, to: manifestURL)
            // The last manifest rewrite can change its allocated block count.
            manifest.retainedBytes = try directoryBytes(staging)
            manifest.isTemporary = manifest.retainedBytes > settings.maximumBytes
            try write(manifest, to: manifestURL)
            let oldCatalog = catalog
            let previous = catalog.records.first { $0.manifest.signature == signature }
            catalog.accessSequence += 1
            let record = ArchiveCacheRecord(manifest: manifest, lastOpenedAt: now(), accessSequence: catalog.accessSequence,
                position: previous?.position ?? ArchiveReadingPosition(), isAvailable: true, isVisible: true)
            try cancellation?()
            try fileManager.moveItem(at: staging, to: entryDirectory(id))
            committed = true
            catalog.records.append(record)
            do { try persist() }
            catch {
                catalog = oldCatalog
                try? fileManager.removeItem(at: entryDirectory(id))
                throw error
            }
            // Lease before applying limits or replacing an older version of this source.
            let session = makeSession(record)
            // An oversized snapshot is temporary and must leave the existing cache intact.
            do {
                if !manifest.isTemporary {
                    let oldIDs = catalog.records.filter {
                        $0.manifest.id != id && $0.manifest.sourceIdentity == sourceIdentity
                    }.map { $0.manifest.id }
                    for oldID in oldIDs { try retire(oldID, forget: true) }
                    try enforceLimits()
                }
                try persist()
            } catch {
                // Import is already durable and leased. Cleanup errors must not turn a
                // completed import into a retry, or cause existing readable data loss.
                session.cleanupWarning = "The archive opened, but some cached files could not be removed. \(error.localizedDescription)"
            }
            return session
        }
    }

    func saveProgress(archiveID: UUID, relativePath: String?, index: Int) throws {
        try queue.sync {
            try ensureLoaded()
            guard let recordIndex = catalog.records.firstIndex(where: { $0.manifest.id == archiveID }) else { return }
            if let relativePath, !catalog.records[recordIndex].manifest.relativeImagePaths.contains(relativePath) {
                throw ArchiveCacheError.invalidPath
            }
            catalog.records[recordIndex].position = ArchiveReadingPosition(relativePath: relativePath, index: max(0, index))
            try persist()
        }
    }

    /// Does not apply the proposed limits or change preferences. Existing startup
    /// recovery still runs, just as it does for any other cache read.
    func evictionImpact(for preferences: ArchiveCachePreferences) throws -> ArchiveCacheEvictionImpact {
        try queue.sync { try evictionImpactLocked(for: preferences) }
    }

    private func evictionImpactLocked(for preferences: ArchiveCachePreferences) throws -> ArchiveCacheEvictionImpact {
        try ensureLoaded()
        guard preferences.maximumBytes > 0, preferences.maximumArchiveCount.map({ $0 > 0 }) ?? true else {
            throw ArchiveCacheError.invalidLimits
        }
        let candidates = ArchiveCachePolicy.evictionCandidates(entries: policyEntries(), preferences: preferences)
        let records = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.manifest.id, $0) })
        return ArchiveCacheEvictionImpact(archives: candidates.compactMap { id in
            guard let record = records[id] else { return nil }
            return ArchiveCacheEvictionImpact.Archive(id: id, displayName: record.manifest.displayName,
                                                     retainedBytes: record.manifest.retainedBytes)
        })
    }

    /// Revalidation and mutation share the store queue; a lease change cannot slip
    /// between them. Changed victims are returned without applying any limits.
    func applyPreferences(_ preferences: ArchiveCachePreferences,
                          confirmedArchiveIDs: [UUID]) throws -> ArchiveCacheEvictionImpact? {
        try queue.sync {
            let current = try evictionImpactLocked(for: preferences)
            guard current.archiveIDs == confirmedArchiveIDs else { return current }
            try updatePreferencesLocked(preferences)
            return nil
        }
    }

    func updatePreferences(_ preferences: ArchiveCachePreferences) throws {
        try queue.sync { try updatePreferencesLocked(preferences) }
    }

    private func updatePreferencesLocked(_ preferences: ArchiveCachePreferences) throws {
        guard preferences.maximumBytes > 0, preferences.maximumArchiveCount.map({ $0 > 0 }) ?? true else {
            throw ArchiveCacheError.invalidLimits
        }
        let limitsChanged = preferences.maximumBytes != settings.maximumBytes
            || preferences.maximumArchiveCount != settings.maximumArchiveCount
        // Compression affects future imports only; preserve startup recovery semantics.
        if !limitsChanged {
            defaults.set(try JSONEncoder().encode(preferences), forKey: Self.preferencesKey)
            settings = preferences
            return
        }
        try ensureLoaded()
        settings = preferences
        defaults.set(try JSONEncoder().encode(preferences), forKey: Self.preferencesKey)
        try enforceLimits()
        try persist()
    }

    func remove(id: UUID) throws {
        try queue.sync { try ensureLoaded(); try retire(id, forget: true); try persist() }
    }

    func clear() throws {
        try queue.sync {
            try ensureLoaded()
            for id in catalog.records.map({ $0.manifest.id }) { try retire(id, forget: true) }
            try persist()
            try retryPendingDeletion()
        }
    }

    private func acquireRecord(at index: Int) throws -> ArchiveReaderSession {
        let record = catalog.records[index]
        do { try validate(record.manifest) }
        catch {
            if isMissingOrInvalid(error) {
                catalog.records[index].isAvailable = false
                invalidResiduals.insert(record.manifest.id)
                try persist()
                try discardInvalidResiduals()
                throw ArchiveCacheError.unavailable
            }
            throw error
        }
        catalog.accessSequence += 1
        catalog.records[index].accessSequence = catalog.accessSequence
        catalog.records[index].lastOpenedAt = now()
        try persist()
        return makeSession(catalog.records[index])
    }

    private func makeSession(_ record: ArchiveCacheRecord) -> ArchiveReaderSession {
        let id = record.manifest.id
        leases[id, default: 0] += 1
        let root = entryDirectory(id).appendingPathComponent("images", isDirectory: true)
        var metadata: [URL: ArchivePreparedPage] = [:]
        var previews: [URL: URL] = [:]
        for var page in record.manifest.pages {
            let url = root.appendingPathComponent(page.storedRelativePath)
            if record.manifest.schemaVersion == 1 {
                // Old cache files retain their original dates; no mutation or regeneration.
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                page.creationDate = values?.creationDate
                page.modificationDate = values?.contentModificationDate
            }
            metadata[url] = page
            if let path = page.previewRelativePath, let preview = try? validatedImage(path, root: root) {
                previews[url] = preview
            }
        }
        return ArchiveReaderSession(archiveID: id,
            imageURLs: record.manifest.pages.map { root.appendingPathComponent($0.storedRelativePath) },
            imageRoot: root, position: record.position, isTemporary: record.manifest.isTemporary,
            displayName: record.manifest.displayName, pageMetadata: metadata, previewURLs: previews) { [self] in
                queue.async { [self] in
                    leases[id] = max(0, (leases[id] ?? 1) - 1)
                    if leases[id] == 0 {
                        leases.removeValue(forKey: id)
                        let temporary = catalog.records.first(where: { $0.manifest.id == id })?.manifest.isTemporary == true
                        if temporary || deferredRemoval.contains(id) {
                            // retire clears the intent only after removal succeeds;
                            // a failed rename must remain eligible for a later retry.
                            try? retire(id, forget: true)
                        }
                        try? discardInvalidResiduals()
                        try? enforceLimits()
                        try? persist()
                    }
                }
            }
    }

    private func ensureLoaded() throws {
        guard !loaded else { return }
        for directory in [cacheDirectory, supportDirectory, archivesDirectory, stagingDirectory, pendingDirectory] {
            try createDirectory(directory)
        }
        if fileManager.fileExists(atPath: catalogURL.path) {
            let data = try Data(contentsOf: catalogURL)
            try checkSchema(data)
            // A malformed catalog can be rebuilt from completion manifests.
            catalog = (try? JSONDecoder().decode(ArchiveCacheCatalog.self, from: data)) ?? ArchiveCacheCatalog()
        }
        // Check manifests before cleanup so newer schemas are never destructively downgraded.
        var recovered: [ArchiveCacheManifest] = []
        for directory in try fileManager.contentsOfDirectory(at: archivesDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { continue }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let data: Data
            do { data = try Data(contentsOf: manifestURL) }
            catch {
                guard isMissingOrInvalid(error) else { throw error }
                invalidResiduals.insert(UUID(uuidString: directory.lastPathComponent)!)
                continue
            }
            try checkSchema(data)
            guard let manifest = try? JSONDecoder().decode(ArchiveCacheManifest.self, from: data),
                  manifest.id.uuidString == directory.lastPathComponent else {
                invalidResiduals.insert(UUID(uuidString: directory.lastPathComponent)!)
                continue
            }
            recovered.append(manifest)
        }
        // Missing catalog records have no persisted access sequence. Reconstruct
        // those in import order, rather than filesystem enumeration order. With a
        // surviving catalog they represent interrupted publications and follow its
        // existing sequence; full catalog recovery uses dates as the best fallback.
        recovered.sort {
            if $0.importedAt != $1.importedAt { return $0.importedAt < $1.importedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        for manifest in recovered {
            if manifest.isTemporary {
                try? fileManager.removeItem(at: entryDirectory(manifest.id))
                catalog.records.removeAll { $0.manifest.id == manifest.id }
                continue
            }
            if !catalog.records.contains(where: { $0.manifest.id == manifest.id }) {
                catalog.accessSequence += 1
                catalog.records.append(ArchiveCacheRecord(manifest: manifest, lastOpenedAt: manifest.importedAt,
                    accessSequence: catalog.accessSequence, position: ArchiveReadingPosition(), isAvailable: true, isVisible: true))
            }
        }
        for directory in try fileManager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: directory)
        }
        try? retryPendingDeletion()
        try reconcile()
        // A removed reader may have been live when the app terminated. Its hidden
        // record is persisted, so finish that explicit removal on relaunch.
        for id in catalog.records.filter({ $0.isAvailable && !$0.isVisible }).map({ $0.manifest.id }) {
            try retire(id, forget: true)
        }
        // Recover a crash between committing a changed source and retiring its old snapshot.
        let sourceGroups = Dictionary(grouping: catalog.records.filter { $0.isAvailable && $0.isVisible },
                                      by: { $0.manifest.sourceIdentity })
        for records in sourceGroups.values where records.count > 1 {
            let ordered = records.sorted {
                if $0.accessSequence != $1.accessSequence { return $0.accessSequence > $1.accessSequence }
                if $0.manifest.importedAt != $1.manifest.importedAt { return $0.manifest.importedAt > $1.manifest.importedAt }
                return $0.manifest.id.uuidString > $1.manifest.id.uuidString
            }
            for obsolete in ordered.dropFirst() { try retire(obsolete.manifest.id, forget: true) }
        }
        try enforceLimits()
        try persist()
        loaded = true
    }

    private func reconcile() throws {
        var changed = false
        for index in catalog.records.indices where catalog.records[index].isAvailable {
            do { try validate(catalog.records[index].manifest) }
            catch {
                guard isMissingOrInvalid(error) else { throw error }
                catalog.records[index].isAvailable = false
                invalidResiduals.insert(catalog.records[index].manifest.id)
                changed = true
            }
        }
        if changed { try persist() }
        for record in catalog.records where !record.isAvailable { invalidResiduals.insert(record.manifest.id) }
        try discardInvalidResiduals()
    }

    /// Keep unavailable metadata visible, but do not strand a partially purged directory.
    private func discardInvalidResiduals() throws {
        for id in invalidResiduals where (leases[id] ?? 0) == 0 {
            let source = entryDirectory(id)
            if fileManager.fileExists(atPath: source.path) {
                let pending = pendingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
                if fileManager.fileExists(atPath: pending.path) { try fileManager.removeItem(at: pending) }
                try fileManager.moveItem(at: source, to: pending)
                invalidResiduals.remove(id)
                try fileManager.removeItem(at: pending)
            } else { invalidResiduals.remove(id) }
        }
    }

    private func policyEntries() -> [ArchiveCachePolicy.Entry] {
        catalog.records.filter { $0.isAvailable && !$0.manifest.isTemporary }.map {
            ArchiveCachePolicy.Entry(id: $0.manifest.id, bytes: $0.manifest.retainedBytes,
                accessSequence: $0.accessSequence, isLeased: (leases[$0.manifest.id] ?? 0) > 0)
        }
    }

    private func enforceLimits() throws {
        for id in ArchiveCachePolicy.evictionCandidates(entries: policyEntries(), preferences: settings) {
            try retire(id, forget: false)
        }
    }

    private func retire(_ id: UUID, forget: Bool) throws {
        guard let index = catalog.records.firstIndex(where: { $0.manifest.id == id }) else { return }
        if forget {
            // Persist removal intent before touching files, including a failed rename.
            deferredRemoval.insert(id)
            catalog.records[index].isVisible = false
            try write(catalog, to: catalogURL)
        }
        if (leases[id] ?? 0) > 0 { return }
        let source = entryDirectory(id)
        if fileManager.fileExists(atPath: source.path) {
            let pending = pendingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            if fileManager.fileExists(atPath: pending.path) { try fileManager.removeItem(at: pending) }
            try fileManager.moveItem(at: source, to: pending)
            // Catalog state reflects that the archive is no longer acquirable even if physical deletion fails.
            if forget { catalog.records.remove(at: index) }
            else { catalog.records[index].isAvailable = false; catalog.records[index].isVisible = false }
            try persist()
            try fileManager.removeItem(at: pending)
        } else if forget { catalog.records.remove(at: index) }
        else { catalog.records[index].isAvailable = false; catalog.records[index].isVisible = false }
        deferredRemoval.remove(id)
    }

    private func finishDeferredRemovals() throws {
        for id in deferredRemoval where (leases[id] ?? 0) == 0 { try retire(id, forget: true) }
        try persist()
    }

    private func persist() throws {
        catalog.schemaVersion = 2
        let unavailable = catalog.records.filter { !$0.isAvailable }.sorted { $0.accessSequence > $1.accessSequence }
        let retained = Set(unavailable.prefix(100).map { $0.manifest.id })
        catalog.records.removeAll { !$0.isAvailable && !retained.contains($0.manifest.id) }
        try write(catalog, to: catalogURL)
    }

    private func retryPendingDeletion() throws {
        for url in try fileManager.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: url)
        }
    }

    private func validate(_ manifest: ArchiveCacheManifest) throws {
        guard manifest.schemaVersion == 1 || manifest.schemaVersion == 2 else { throw ArchiveCacheError.unsupportedSchema }
        guard !manifest.relativeImagePaths.isEmpty else { throw ArchiveCacheError.unavailable }
        let directory = entryDirectory(manifest.id)
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ArchiveCacheError.invalidPath
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        try checkSchema(data)
        let disk = try JSONDecoder().decode(ArchiveCacheManifest.self, from: data)
        guard disk.id == manifest.id, disk.signature == manifest.signature,
              disk.pages == manifest.pages else { throw ArchiveCacheError.unavailable }
        let imageRoot = directory.appendingPathComponent("images", isDirectory: true)
        try validatePagePaths(manifest.pages, root: imageRoot)
        for page in manifest.pages {
            _ = try validatedImage(page.storedRelativePath, root: imageRoot)
        }
    }

    private func validatePagePaths(_ pages: [ArchivePreparedPage], root: URL) throws {
        var identities = Set<String>()
        var files = Set<String>()
        var directories = Set<String>()
        for page in pages {
            let original = try safeURL(page.originalRelativePath, root: root)
            guard ["jpg", "jpeg", "png"].contains(original.pathExtension.lowercased()),
                  identities.insert(page.originalRelativePath.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw ArchiveCacheError.invalidPath }
            for path in [page.storedRelativePath, page.previewRelativePath].compactMap({ $0 }) {
                let url = try safeURL(path, root: root)
                guard ["jpg", "jpeg", "png", "jxl"].contains(url.pathExtension.lowercased()) else {
                    throw ArchiveCacheError.invalidPath
                }
                let normalized = path.precomposedStringWithCanonicalMapping.lowercased()
                guard !directories.contains(normalized), files.insert(normalized).inserted else {
                    throw ArchiveCacheError.invalidPath
                }
                var components = normalized.split(separator: "/")
                components.removeLast()
                while !components.isEmpty {
                    let ancestor = components.joined(separator: "/")
                    guard !files.contains(ancestor) else { throw ArchiveCacheError.invalidPath }
                    directories.insert(ancestor)
                    components.removeLast()
                }
            }
        }
    }

    private func isMissingFile(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code)
    }

    private func validatedImage(_ path: String, root: URL) throws -> URL {
        let root = root.standardizedFileURL
        let url = try safeURL(path, root: root)
        guard ["jpg", "jpeg", "png", "jxl"].contains(url.pathExtension.lowercased()) else { throw ArchiveCacheError.invalidPath }
        var ancestor = url
        while true {
            let values = try ancestor.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ArchiveCacheError.invalidPath }
            if ancestor.path == root.path { break }
            guard ancestor.path != "/" else { throw ArchiveCacheError.invalidPath }
            ancestor.deleteLastPathComponent()
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ArchiveCacheError.invalidPath }
        return url
    }

    private func safeURL(_ path: String, root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !parts.contains(".."), !parts.contains("."), !parts.contains(""),
              !parts[0].contains(":") else { throw ArchiveCacheError.invalidPath }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw ArchiveCacheError.invalidPath }
        return url
    }

    private func commonRoot(of images: [URL]) -> URL {
        var root = images[0].deletingLastPathComponent().standardizedFileURL
        while !images.allSatisfy({ $0.standardizedFileURL.path.hasPrefix(root.path + "/") }) && root.path != "/" {
            root.deleteLastPathComponent()
        }
        return root
    }

    private func entryDirectory(_ id: UUID) -> URL { archivesDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func checkSchema(_ data: Data) throws {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["schemaVersion"] as? Int, version > 2 { throw ArchiveCacheError.unsupportedSchema }
    }

    private func isMissingOrInvalid(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        if let cacheError = error as? ArchiveCacheError {
            switch cacheError { case .unavailable, .invalidPath, .noImages: return true; default: return false }
        }
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code)
    }

    private func directoryBytes(_ directory: URL) throws -> Int64 {
        var failure: Error?
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in failure = error; return false }) else { return 0 }
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isRegularFile == true && values.isSymbolicLink != true {
                bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        if let failure { throw failure }
        return bytes
    }

    private func createDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try protect(url)
    }

    private func protect(_ url: URL) throws {
        #if os(iOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try protect(url)
    }

    private func generateThumbnail(from image: URL, in directory: URL) {
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 240,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return }
        let url = directory.appendingPathComponent("thumbnail.jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        if CGImageDestinationFinalize(destination) { try? protect(url) }
    }
}
