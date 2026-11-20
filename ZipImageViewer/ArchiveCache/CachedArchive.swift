import Foundation

struct ArchiveCachePreferences: Codable, Equatable {
    var maximumBytes: Int64 = 2_000_000_000
    var maximumArchiveCount: Int? = nil
    var compressExtractedImages: Bool = false

    init(maximumBytes: Int64 = 2_000_000_000, maximumArchiveCount: Int? = nil,
         compressExtractedImages: Bool = false) {
        self.maximumBytes = maximumBytes
        self.maximumArchiveCount = maximumArchiveCount
        self.compressExtractedImages = compressExtractedImages
    }

    private enum CodingKeys: String, CodingKey { case maximumBytes, maximumArchiveCount, compressExtractedImages }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maximumBytes = try container.decodeIfPresent(Int64.self, forKey: .maximumBytes) ?? 2_000_000_000
        maximumArchiveCount = try container.decodeIfPresent(Int.self, forKey: .maximumArchiveCount)
        compressExtractedImages = try container.decodeIfPresent(Bool.self, forKey: .compressExtractedImages) ?? false
    }
}

/// Stable archive identity is independent of the file used to render a page.
/// All paths are relative to the trusted extraction root, then the cached images root.
struct ArchivePreparedPage: Codable, Equatable, Sendable {
    let originalRelativePath: String
    let storedRelativePath: String
    var previewRelativePath: String? = nil
    var creationDate: Date? = nil
    var modificationDate: Date? = nil
    /// Identifies the encoder policy without making it part of cache identity.
    var processingPolicy: String? = nil
}

struct ArchiveReadingPosition: Codable, Equatable {
    var relativePath: String? = nil
    var index: Int = 0
}

struct CachedArchiveSummary: Identifiable {
    let id: UUID
    let displayName: String
    let format: String
    let imageCount: Int
    let lastOpenedAt: Date
    let position: ArchiveReadingPosition
    let isAvailable: Bool
    let thumbnailURL: URL?
    let retainedBytes: Int64
}

struct ArchiveCacheUsage {
    let retainedBytes: Int64
    let archiveCount: Int
    let pendingDeletionBytes: Int64
    var totalBytes: Int64 { retainedBytes + pendingDeletionBytes }
}

/// A snapshot of the same unleased LRU candidates used when applying limits.
/// Confirm promptly: opening or releasing readers can change a later snapshot.
struct ArchiveCacheEvictionImpact {
    struct Archive: Identifiable {
        let id: UUID
        let displayName: String
        let retainedBytes: Int64
    }

    let archives: [Archive]
    var count: Int { archives.count }
    var archiveIDs: [UUID] { archives.map(\.id) }
    var displayNames: [String] { archives.map(\.displayName) }
    var retainedBytes: Int64 { archives.reduce(0) { $0 + $1.retainedBytes } }
}

/// A lease keeps all image URLs alive through pending presentation and reading.
/// Explicit release is preferred; deinit also releases an abandoned presentation.
final class ArchiveReaderSession {
    let archiveID: UUID
    let displayName: String
    let imageURLs: [URL]
    let position: ArchiveReadingPosition
    let isTemporary: Bool
    let pageMetadata: [URL: ArchivePreparedPage]
    let previewURLs: [URL: URL]
    var cleanupWarning: String?
    private let imageRoot: URL
    private let releaseAction: () -> Void
    private let lock = NSLock()
    private var released = false
    private var imageWorkCount = 0
    private var releaseActionPerformed = false

    init(archiveID: UUID, imageURLs: [URL], imageRoot: URL,
         position: ArchiveReadingPosition, isTemporary: Bool, displayName: String = "Archive",
         pageMetadata: [URL: ArchivePreparedPage] = [:], previewURLs: [URL: URL] = [:],
         release: @escaping () -> Void) {
        self.archiveID = archiveID
        self.displayName = displayName
        self.imageURLs = imageURLs
        self.imageRoot = imageRoot
        self.position = position
        self.isTemporary = isTemporary
        self.pageMetadata = pageMetadata
        self.previewURLs = previewURLs
        self.releaseAction = release
    }

    func relativePath(for url: URL) -> String? {
        if let page = pageMetadata[url] { return page.originalRelativePath }
        let prefix = imageRoot.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    func restoredIndex(in sortedImages: [URL]) -> Int {
        if let path = position.relativePath,
           let index = sortedImages.firstIndex(where: { relativePath(for: $0) == path }) { return index }
        return min(max(0, position.index), max(0, sortedImages.count - 1))
    }

    /// Acquire before closing the reader. The returned closure is idempotent and
    /// keeps the cache lease alive until work that already uses its files finishes.
    func retainForImageWork() -> () -> Void {
        lock.lock()
        guard !released else { lock.unlock(); return {} }
        imageWorkCount += 1
        lock.unlock()
        let token = ImageWorkRelease { [self] in finishImageWork() }
        return { token.release() }
    }

    private func finishImageWork() {
        lock.lock()
        imageWorkCount -= 1
        let shouldRelease = released && imageWorkCount == 0 && !releaseActionPerformed
        if shouldRelease { releaseActionPerformed = true }
        lock.unlock()
        if shouldRelease { releaseAction() }
    }

    func release() {
        lock.lock()
        released = true
        let shouldRelease = imageWorkCount == 0 && !releaseActionPerformed
        if shouldRelease { releaseActionPerformed = true }
        lock.unlock()
        if shouldRelease { releaseAction() }
    }

    deinit { release() }
}

private final class ImageWorkRelease {
    private let lock = NSLock()
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func release() {
        lock.lock()
        let pending = action
        action = nil
        lock.unlock()
        pending?()
    }
    deinit { release() }
}

struct ArchiveCacheManifest: Codable {
    var schemaVersion = 2
    let id: UUID
    let displayName: String
    let format: String
    let sourceIdentity: String
    let signature: String
    let importedAt: Date
    let pages: [ArchivePreparedPage]
    var retainedBytes: Int64
    var isTemporary: Bool
    var relativeImagePaths: [String] { pages.map(\.originalRelativePath) }

    init(id: UUID, displayName: String, format: String, sourceIdentity: String, signature: String,
         importedAt: Date, pages: [ArchivePreparedPage], retainedBytes: Int64, isTemporary: Bool) {
        self.id = id
        self.displayName = displayName
        self.format = format
        self.sourceIdentity = sourceIdentity
        self.signature = signature
        self.importedAt = importedAt
        self.pages = pages
        self.retainedBytes = retainedBytes
        self.isTemporary = isTemporary
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, displayName, format, sourceIdentity, signature, importedAt
        case relativeImagePaths, pages, retainedBytes, isTemporary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 || schemaVersion == 2 else { throw ArchiveCacheError.unsupportedSchema }
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        format = try c.decode(String.self, forKey: .format)
        sourceIdentity = try c.decode(String.self, forKey: .sourceIdentity)
        signature = try c.decode(String.self, forKey: .signature)
        importedAt = try c.decode(Date.self, forKey: .importedAt)
        retainedBytes = try c.decode(Int64.self, forKey: .retainedBytes)
        isTemporary = try c.decode(Bool.self, forKey: .isTemporary)
        if schemaVersion == 1 {
            pages = try c.decode([String].self, forKey: .relativeImagePaths).map {
                ArchivePreparedPage(originalRelativePath: $0, storedRelativePath: $0)
            }
        } else { pages = try c.decode([ArchivePreparedPage].self, forKey: .pages) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(format, forKey: .format)
        try c.encode(sourceIdentity, forKey: .sourceIdentity)
        try c.encode(signature, forKey: .signature)
        try c.encode(importedAt, forKey: .importedAt)
        try c.encode(retainedBytes, forKey: .retainedBytes)
        try c.encode(isTemporary, forKey: .isTemporary)
        if schemaVersion == 1 { try c.encode(relativeImagePaths, forKey: .relativeImagePaths) }
        else { try c.encode(pages, forKey: .pages) }
    }
}

struct ArchiveCacheRecord: Codable {
    var manifest: ArchiveCacheManifest
    var lastOpenedAt: Date
    var accessSequence: UInt64
    var position: ArchiveReadingPosition
    var isAvailable: Bool
    var isVisible: Bool
}

struct ArchiveCacheCatalog: Codable {
    var schemaVersion = 2
    var accessSequence: UInt64 = 0
    var records: [ArchiveCacheRecord] = []
}

enum ArchiveCacheError: LocalizedError {
    case unavailable
    case invalidPath
    case noImages
    case unsupportedSchema
    case invalidLimits

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The cached copy is unavailable. Select the archive again."
        case .invalidPath: return "The cached archive contains an unsafe image path."
        case .noImages: return "The archive contains no supported images."
        case .unsupportedSchema: return "This cache was created by a newer version of the app."
        case .invalidLimits: return "Choose a positive cache size and archive count."
        }
    }
}
