import Foundation
import ZipArchive

/// Owns operation-scoped extraction work. Call only from one serial worker queue.
/// Completed images and reader leases belong to the shared persistent cache.
final class ArchiveService {
    enum ArchiveType {
        case zip, sevenZip
    }

    struct Request {
        let url: URL
        let signature: String
        let type: ArchiveType
        let requiresPassword: Bool
        let displayName: String
        let sourceIdentity: String
        let directory: URL
        let compressExtractedImages: Bool
    }

    enum Preparation {
        case cached([URL])
        case archive(Request)
    }

    enum ImportError: LocalizedError {
        case unsupportedFormat
        case noImages
        case invalidEntryPath(String)
        case zipExtractionFailed(Error)
        case coordinationFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return "Unsupported archive format."
            case .noImages: return "No images (.jpg, .jpeg, .png) were found in the archive."
            case .invalidEntryPath(let name): return "The archive contains an unsafe image path: \(name)"
            case .zipExtractionFailed(let error): return "The ZIP archive could not be extracted. \(error.localizedDescription)"
            case .coordinationFailed: return "The selected file couldn't be accessed."
            }
        }
    }

    static let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png"]
    private let fileManager: FileManager
    private let workDirectory: URL
    private let cacheStore: ArchiveCacheStore
    private let zipExtractor: any ArchiveExtracting
    private let imageProcessor: any ExtractedImagePreparing
    private let usesProductionWorkspace: Bool
    private var preparedSession: ArchiveReaderSession?
    private var pendingRequest: Request?

    init(workDirectory: URL? = nil, fileManager: FileManager = .default,
         cacheStore: ArchiveCacheStore? = nil,
         imageProcessor: any ExtractedImagePreparing = ExtractedImageProcessor(),
         zipExtractor: any ArchiveExtracting = ZipExtractor()) {
        self.workDirectory = workDirectory ?? fileManager.temporaryDirectory
            .appendingPathComponent("ZipImageViewerImports", isDirectory: true)
        self.fileManager = fileManager
        self.imageProcessor = imageProcessor
        self.zipExtractor = zipExtractor
        self.usesProductionWorkspace = workDirectory == nil
        if let cacheStore {
            self.cacheStore = cacheStore
        } else if let workDirectory {
            self.cacheStore = ArchiveCacheStore(
                cacheDirectory: workDirectory.appendingPathComponent("retained", isDirectory: true),
                supportDirectory: workDirectory.appendingPathComponent("catalog", isDirectory: true))
        } else {
            self.cacheStore = .shared
        }
    }

    /// Transfers the pending reader lease; the receiver releases it when viewing ends.
    func takePreparedSession() -> ArchiveReaderSession? {
        defer { preparedSession = nil }
        return preparedSession
    }

    /// Stage callbacks run synchronously on the caller's serial worker queue.
    /// Cancellation is checked during source hashing/copying, extraction and page preparation.
    func prepareArchive(at sourceURL: URL,
                        compressExtractedImages: Bool? = nil,
                        cancellation: ArchiveCancellationToken? = nil,
                        onStage: ((ImportPresentationState) -> Void)? = nil) throws -> Preparation {
        let canCancel = cancellation != nil
        let cancellation = cancellation ?? ArchiveCancellationToken()
        try cancellation.checkCancellation()
        onStage?(ImportPresentationState(stage: .preparingSource, filename: sourceURL.lastPathComponent, canCancel: canCancel))
        let compress = compressExtractedImages ?? cacheStore.preferences.compressExtractedImages
        do { return try prepareArchiveSource(at: sourceURL, compress: compress, cancellation: cancellation, canCancel: canCancel, onStage: onStage) }
        catch {
            onStage?(ImportPresentationState(stage: .failed, filename: sourceURL.lastPathComponent))
            throw error
        }
    }

    private func prepareArchiveSource(at sourceURL: URL,
                                      compress: Bool,
                                      cancellation: ArchiveCancellationToken,
                                      canCancel: Bool,
                                      onStage: ((ImportPresentationState) -> Void)?) throws -> Preparation {
        if usesProductionWorkspace { ArchiveImportWorkspace.prepare() }
        let type: ArchiveType
        switch sourceURL.pathExtension.lowercased() {
        case "zip", "cbz": type = .zip
        case "7z": type = .sevenZip
        default: throw ImportError.unsupportedFormat
        }

        preparedSession?.release()
        preparedSession = nil
        if let pendingRequest { try discard(pendingRequest) }

        // A URL inside the sandbox may not require a security scope. Let the
        // coordinated read report actual access failures in that case.
        let hasScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasScope { sourceURL.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var result: Result<Preparation, Error>?
        NSFileCoordinator().coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) { readableURL in
            result = Result {
                let sourceSize = try readableURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let sourceSize, sourceSize >= 0, UInt64(sourceSize) <= ArchiveExtractionLimits.default.maximumTotalBytes else {
                    throw ArchiveImportError.resourceLimit("The archive exceeds the source size limit.")
                }
                let signature = try ArchiveIdentity.signature(for: readableURL, identityURL: sourceURL, cancellation: cancellation.checkCancellation)
                if let session = try cacheStore.acquire(signature: signature) {
                    do { try cancellation.checkCancellation() } catch { session.release(); throw error }
                    preparedSession = session
                    onStage?(ImportPresentationState(stage: .completed, filename: session.displayName))
                    return .cached(session.imageURLs)
                }

                let directory = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = directory.appendingPathComponent("SelectedArchive.\(sourceURL.pathExtension)")
                    try ArchiveImportWorkspace.checkCopySpace(for: readableURL, in: directory)
                    onStage?(ImportPresentationState(stage: .copying, filename: sourceURL.lastPathComponent, canCancel: canCancel))
                    try Self.copySource(readableURL, to: destination, cancellation: cancellation)
                    if type == .zip {
                        _ = try ZipMetadataAdmission.check(destination, limits: .default, cancellation: cancellation)
                    }
                    onStage?(ImportPresentationState(stage: .opening, filename: sourceURL.lastPathComponent, canCancel: canCancel))
                    let needsPassword = type == .zip && SSZipArchive.isFilePasswordProtected(atPath: destination.path)
                    try cancellation.checkCancellation()
                    let request = Request(url: destination, signature: signature, type: type,
                                          requiresPassword: needsPassword, displayName: sourceURL.lastPathComponent,
                                          sourceIdentity: sourceURL.standardizedFileURL.path, directory: directory,
                                          compressExtractedImages: compress)
                    pendingRequest = request
                    if needsPassword {
                        onStage?(ImportPresentationState(stage: .waitingForPassword, filename: request.displayName, canCancel: canCancel))
                    }
                    return .archive(request)
                } catch {
                    try? fileManager.removeItem(at: directory)
                    throw error
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ImportError.coordinationFailed }
        return try result.get()
    }

    func extract(_ request: Request, password: String?,
                 cancellation: ArchiveCancellationToken? = nil,
                 onStage: ((ImportPresentationState) -> Void)? = nil) throws -> [URL] {
        let canCancel = cancellation != nil
        let cancellation = cancellation ?? ArchiveCancellationToken()
        let destination = request.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            onStage?(ImportPresentationState(stage: .extracting, filename: request.displayName, canCancel: canCancel))
            switch request.type {
            case .zip:
                do {
                    _ = try zipExtractor.extract(archiveURL: request.url, destinationURL: destination,
                        password: password, cancellation: cancellation) { value in
                        onStage?(ImportPresentationState(stage: .extracting, filename: request.displayName,
                                                        progress: value.fractionCompleted, canCancel: canCancel))
                    }
                } catch ArchiveImportError.noSupportedImages {
                    throw ImportError.noImages
                } catch ArchiveImportError.passwordRequired {
                    throw ImportError.zipExtractionFailed(ArchiveImportError.passwordRequired)
                } catch ArchiveImportError.passwordOrDamagedArchive {
                    throw ImportError.zipExtractionFailed(ArchiveImportError.passwordOrDamagedArchive)
                }
            case .sevenZip:
                _ = try SevenZipExtractor().extract(archiveURL: request.url, destinationURL: destination,
                                                   password: password, cancellation: cancellation,
                                                   progress: { progress in
                    let stage: ImportPresentationState.Stage
                    switch progress.stage {
                    case .copying: stage = .copying
                    case .opening: stage = .opening
                    case .extracting: stage = .extracting
                    case .finalizing: stage = .preparingPages
                    }
                    onStage?(ImportPresentationState(stage: stage, filename: request.displayName,
                                                    progress: progress.fractionCompleted))
                })
            }

            onStage?(ImportPresentationState(stage: .preparingPages, filename: request.displayName, canCancel: canCancel))
            let images = try collectImageFiles(in: destination)
            guard !images.isEmpty else { throw ImportError.noImages }
            let processingStage: ImportPresentationState.Stage = request.compressExtractedImages ? .compressing : .preparingPreviews
            onStage?(ImportPresentationState(stage: processingStage, filename: request.displayName, progress: 0, canCancel: canCancel))
            let pages = try imageProcessor.prepare(images: images, imageRoot: destination,
                                                  compress: request.compressExtractedImages, cancellation: cancellation.checkCancellation) { fraction in
                onStage?(ImportPresentationState(stage: processingStage, filename: request.displayName, progress: fraction, canCancel: canCancel))
            }
            onStage?(ImportPresentationState(stage: .preparingPages, filename: request.displayName, canCancel: canCancel))
            // The store copies only supported, validated images; non-image output and
            // the compressed source disappear with the operation directory below.
            try cancellation.checkCancellation()
            let session = try cacheStore.publish(preparedPages: pages, imageRoot: destination,
                                                displayName: request.displayName,
                                                sourceIdentity: request.sourceIdentity,
                                                signature: request.signature,
                                                format: request.url.pathExtension.lowercased(),
                                                cancellation: cancellation.checkCancellation)
            preparedSession?.release()
            preparedSession = session
            try? discard(request)
            onStage?(ImportPresentationState(stage: .completed, filename: request.displayName))
            return session.imageURLs
        } catch {
            try? fileManager.removeItem(at: destination)
            if case ImportError.zipExtractionFailed = error {
                // A caller can retry the same copied source or explicitly discard it.
            } else {
                try? discard(request)
            }
            onStage?(ImportPresentationState(stage: .failed, filename: request.displayName))
            throw error
        }
    }

    private static func copySource(_ source: URL, to destination: URL,
                                   cancellation: ArchiveCancellationToken) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ArchiveImportError.storageFailure
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var total: UInt64 = 0
        let limits = ArchiveExtractionLimits.default
        while true {
            try cancellation.checkCancellation()
            let data = try input.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            guard UInt64(data.count) <= limits.maximumTotalBytes - total else {
                throw ArchiveImportError.resourceLimit("The archive exceeds the source size limit.")
            }
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: destination.deletingLastPathComponent().path)
            guard let free = attributes[.systemFreeSize] as? NSNumber,
                  free.uint64Value >= limits.minimumFreeDiskBytes + UInt64(data.count) else {
                throw ArchiveImportError.storageFailure
            }
            try output.write(contentsOf: data)
            total += UInt64(data.count)
        }
        try output.synchronize()
        try cancellation.checkCancellation()
    }

    /// Abandon only this import, preserving all previously completed caches.
    func discard(_ request: Request) throws {
        if fileManager.fileExists(atPath: request.directory.path) {
            try fileManager.removeItem(at: request.directory)
        }
        if pendingRequest?.directory == request.directory { pendingRequest = nil }
    }

    func clearCache() throws {
        preparedSession?.release()
        preparedSession = nil
        if let pendingRequest { try discard(pendingRequest) }
        try cacheStore.clear()
    }

    static func outputURL(forEntryName name: String, destinationRoot: URL) throws -> URL {
        // Parse archive-relative components directly. URL(fileURLWithPath:) would
        // first resolve a relative name against the process working directory.
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !normalized.hasPrefix("/"), !normalized.contains("\0"),
              !components.contains(".."), !components.isEmpty,
              !components[0].contains(":") else {
            throw ImportError.invalidEntryPath(name)
        }
        let root = destinationRoot.standardizedFileURL
        let output = components.filter { $0 != "." }.reduce(root) { $0.appendingPathComponent(String($1)) }.standardizedFileURL
        guard output.path.hasPrefix(root.path + "/") else { throw ImportError.invalidEntryPath(name) }
        return output
    }

    static func isRegularImage(at url: URL) -> Bool {
        guard supportedImageExtensions.contains(url.pathExtension.lowercased()),
              let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    func collectImageFiles(in directory: URL) throws -> [URL] {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles], errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw ImportError.noImages }
        var images: [URL] = []
        for case let url as URL in enumerator {
            if Self.isRegularImage(at: url) { images.append(url) }
        }
        if let enumerationError { throw enumerationError }
        return images
    }
}

/// Runs once per process, on the first extraction worker that needs staging.
/// Both formats share this barrier, so cleanup cannot delete another live import.
enum ArchiveImportWorkspace {
    private static let cleanup: Void = {
        let temporary = FileManager.default.temporaryDirectory
        for name in ["ZipImageViewerImports", "ZipImageViewer7zImports", "ZipImageViewer", "ZipImageViewer7z"] {
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name, isDirectory: true))
        }
    }()

    static func prepare() { _ = cleanup }

    /// A copy preflight is only a lower bound; extraction still handles write failures.
    static func checkCopySpace(for source: URL, in directory: URL) throws {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        if let available = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value,
           UInt64(max(0, size)) > available {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }
}
