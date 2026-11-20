import Foundation

/// Runs synchronously on an import worker, before the cache publication transaction.
protocol ExtractedImagePreparing {
    func prepare(images: [URL], imageRoot: URL, compress: Bool,
                 cancellation: (() throws -> Void)?,
                 progress: ((Double) -> Void)?) throws -> [ArchivePreparedPage]
}

protocol ArchiveExtracting {
    /// Runs synchronously. The caller owns a fresh destination and must remove it on failure.
    func extract(archiveURL: URL, destinationURL: URL, password: String?,
                 cancellation: ArchiveCancellationToken,
                 progress: @escaping (ArchiveImportProgress) -> Void) throws -> [URL]
}

struct ArchiveImportProgress {
    enum Stage { case copying, opening, extracting, finalizing }
    let stage: Stage
    let fractionCompleted: Double?

    init(stage: Stage, fractionCompleted: Double? = nil) {
        self.stage = stage
        self.fractionCompleted = fractionCompleted
    }
}

struct ArchiveExtractionLimits {
    var maximumZipMetadataBytes: UInt64 = 16 * 1024 * 1024
    var maximumEntryCount: Int = 100_000
    var maximumImageCount: Int = 25_000
    var maximumFileBytes: UInt64 = 512 * 1024 * 1024
    var maximumTotalBytes: UInt64 = 10 * 1024 * 1024 * 1024
    var minimumFreeDiskBytes: UInt64 = 100 * 1024 * 1024
    static let `default` = ArchiveExtractionLimits()
}

enum ArchiveImportError: Error, LocalizedError, Equatable {
    case cancelled
    case passwordRequired
    case openFailed(passwordAttempted: Bool)
    case passwordOrDamagedArchive
    case unsupportedOrDamagedArchive
    case invalidArchive
    case unsafeOutput(String)
    case resourceLimit(String)
    case storageFailure
    case noSupportedImages

    var errorDescription: String? {
        switch self {
        case .cancelled: return "The import was cancelled."
        case .passwordRequired: return "A password is required to extract the images in this archive."
        case .openFailed(let attempted):
            return attempted
                ? "The archive could not be opened. The password may be incorrect, or the archive may be damaged or unsupported."
                : "The archive could not be opened. It may have encrypted filenames, or it may be damaged or unsupported. You can try a password."
        case .passwordOrDamagedArchive:
            return "The images could not be extracted. The password may be incorrect, or the archive may be damaged or unsupported."
        case .unsupportedOrDamagedArchive: return "The archive is damaged or uses an unsupported compression method."
        case .invalidArchive: return "The selected file is not a valid 7z archive."
        case .unsafeOutput(let reason): return "The archive contains an unsafe output path: \(reason)"
        case .resourceLimit(let reason): return reason
        case .storageFailure: return "The archive could not be read or its images could not be written. Check available storage and file access."
        case .noSupportedImages: return "No images (.jpg, .jpeg, .png) were found in the archive."
        }
    }
}

/// Cancellation can arrive from the main thread while the native decoder blocks a worker.
/// The handler is invoked outside the lock, and retains its decoder until abort returns.
final class ArchiveCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (() -> Void)?
    private var handlerID: UUID?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func checkCancellation() throws {
        if isCancelled { throw ArchiveImportError.cancelled }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let callback = handler
        lock.unlock()
        callback?()
    }

    @discardableResult
    func installHandler(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        handlerID = id
        handler = callback
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { callback() }
        return id
    }

    func removeHandler(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if handlerID == id { handler = nil; handlerID = nil }
    }
}
