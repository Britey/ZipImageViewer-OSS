import Foundation
import PLzmaSDK

final class SevenZipExtractor: ArchiveExtracting {
    private let limits: ArchiveExtractionLimits
    private static let abortQueue = DispatchQueue(label: "com.zipimageviewer.archive-abort", qos: .userInitiated)

    init(limits: ArchiveExtractionLimits = .default) {
        self.limits = limits
    }

    func extract(archiveURL: URL, destinationURL: URL, password: String?,
                 cancellation: ArchiveCancellationToken,
                 progress: @escaping (ArchiveImportProgress) -> Void) throws -> [URL] {
        var stage = ArchiveImportProgress.Stage.opening
        var encryptedSelection = false
        do {
            try cancellation.checkCancellation()
            progress(ArchiveImportProgress(stage: .opening))
            // Reject obvious non-7z input without presenting a misleading password option.
            let header = try FileHandle(forReadingFrom: archiveURL)
            let signature: Data
            do {
                defer { try? header.close() }
                signature = try header.read(upToCount: 6) ?? Data()
            }
            guard signature == Data([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) else {
                throw ArchiveImportError.invalidArchive
            }
            let delegate = ExtractionProgressDelegate(progress: progress)
            let input = try PLzmaSDK.InStream(path: PLzmaSDK.Path(archiveURL.path))
            let decoder = try PLzmaSDK.Decoder(stream: input, fileType: .sevenZ, delegate: delegate)
            try decoder.setPassword(password)
            let handlerID = cancellation.installHandler {
                // Never wait for a native mutex or filesystem callback on the UI thread.
                Self.abortQueue.async { try? decoder.abort() }
            }
            defer { cancellation.removeHandler(handlerID) }
            // The SDK retains delegates weakly. Explicitly extend its lifetime through native work.
            return try withExtendedLifetime(delegate) {
                try cancellation.checkCancellation()
                guard try decoder.open() else {
                    try cancellation.checkCancellation()
                    throw ArchiveImportError.openFailed(passwordAttempted: password != nil)
                }
                try cancellation.checkCancellation()
                let count = try decoder.count()
                guard UInt64(count) <= UInt64(max(0, limits.maximumEntryCount)) else {
                    throw ArchiveImportError.resourceLimit("The archive contains too many entries (limit: \(limits.maximumEntryCount)).")
                }
                var policy = ArchiveOutputPolicy(root: destinationURL, limits: limits)
                var selected: [(item: PLzmaSDK.Item, url: URL)] = []
                for index in 0..<count {
                    try cancellation.checkCancellation()
                    let item = try decoder.item(at: index)
                    guard !item.isDir else { continue }
                    let name = try item.path().description
                    guard ArchiveOutputPolicy.isSupportedImage(name) else { continue }
                    let output = try policy.reserve(entryName: name, size: item.size)
                    encryptedSelection = encryptedSelection || item.encrypted
                    selected.append((item, output))
                }
                guard !selected.isEmpty else { throw ArchiveImportError.noSupportedImages }
                if encryptedSelection && password == nil { throw ArchiveImportError.passwordRequired }
                try cancellation.checkCancellation()
                try policy.prepareDestination()
                let streams = try PLzmaSDK.ItemOutStreamArray(capacity: PLzmaSDK.Size(selected.count))
                for entry in selected {
                    try cancellation.checkCancellation()
                    try FileManager.default.createDirectory(at: entry.url.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    // File streams open lazily during native extraction and close per item.
                    // Native getExtractStream/OutFileStream.close preserve item timestamps.
                    // We never ask the SDK to restore paths, links, permissions or special objects.
                    let output = try PLzmaSDK.OutStream(path: PLzmaSDK.Path(entry.url.path))
                    try streams.add(item: entry.item, stream: output)
                }
                stage = .extracting
                delegate.beginExtraction()
                progress(ArchiveImportProgress(stage: .extracting, fractionCompleted: 0))
                guard try decoder.extract(itemsToStreams: streams) else {
                    try cancellation.checkCancellation()
                    throw encryptedSelection ? ArchiveImportError.passwordOrDamagedArchive
                        : ArchiveImportError.unsupportedOrDamagedArchive
                }
                try cancellation.checkCancellation()
                stage = .finalizing
                progress(ArchiveImportProgress(stage: .finalizing))
                for entry in selected {
                    try cancellation.checkCancellation()
                    try policy.verifyOutput(entry.url, expectedSize: entry.item.size)
                }
                return selected.map(\.url)
            }
        } catch {
            if cancellation.isCancelled { throw ArchiveImportError.cancelled }
            if let failure = error as? ArchiveImportError { throw failure }
            if let failure = error as? PLzmaSDK.Exception {
                switch failure.code {
                case .io: throw ArchiveImportError.storageFailure
                case .notEnoughMemory:
                    throw ArchiveImportError.resourceLimit("The archive requires more memory than is available.")
                default:
                    // 1.6.1 discards native password/CRC/unsupported-method distinctions.
                    // Never infer a definite wrong password from arbitrary exception prose.
                    if stage == .opening {
                        throw ArchiveImportError.openFailed(passwordAttempted: password != nil)
                    }
                    throw encryptedSelection ? ArchiveImportError.passwordOrDamagedArchive
                        : ArchiveImportError.unsupportedOrDamagedArchive
                }
            }
            throw ArchiveImportError.storageFailure
        }
    }
}

private final class ExtractionProgressDelegate: PLzmaSDK.DecoderDelegate {
    private let lock = NSLock()
    private var extracting = false
    private var lastUpdate = TimeInterval.zero
    private var reportedPositiveProgress = false
    private let progress: (ArchiveImportProgress) -> Void

    init(progress: @escaping (ArchiveImportProgress) -> Void) {
        self.progress = progress
    }

    func beginExtraction() {
        lock.lock()
        extracting = true
        lastUpdate = 0
        reportedPositiveProgress = false
        lock.unlock()
    }

    func decoder(decoder: PLzmaSDK.Decoder, path: String, progress value: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        // Show the first actual decoding progress immediately, even when the native
        // decoder just reported zero while opening its first output stream.
        let shouldReport = extracting && value.isFinite &&
            (now - lastUpdate >= 0.1 || value >= 1 || (!reportedPositiveProgress && value > 0))
        if shouldReport {
            lastUpdate = now
            if value > 0 { reportedPositiveProgress = true }
        }
        lock.unlock()
        if shouldReport {
            progress(ArchiveImportProgress(stage: .extracting, fractionCompleted: min(1, max(0, value))))
        }
    }
}
