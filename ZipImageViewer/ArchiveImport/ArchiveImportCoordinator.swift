import Foundation

/// Owns copied archives, native work and password attempts; completed caches live in the shared store.
/// Only this main-actor owner publishes output; blocking file and decoder work runs on `worker`.
@MainActor
final class ArchiveImportCoordinator {
    enum State {
        case idle, copying, opening, extracting(Double?), compressing(Double?), preparingPreviews(Double?), finalizing
        case awaitingPassword(ArchiveImportError)
        case cancelling
        case completed([URL])
        case failed(Error)
    }

    struct SourceAccess {
        var start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var stop: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
        // Invoked within the coordinator's single coordinated read transaction.
        var copy: (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private final class Operation {
        let directory: URL
        let archive: URL
        let source: URL
        let compressExtractedImages: Bool
        let cancellation = ArchiveCancellationToken()
        var signature: String?
        var attemptID: UUID?
        var cancelled = false

        init(root: URL, source: URL, compressExtractedImages: Bool) {
            self.source = source
            self.compressExtractedImages = compressExtractedImages
            directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            archive = directory.appendingPathComponent("archive").appendingPathExtension(source.pathExtension)
        }
    }

    private enum CopyResult {
        case copied(String)
        case cached(ArchiveReaderSession)
    }

    private let rootDirectory: URL
    private let extractor: ArchiveExtracting
    private let sourceAccess: SourceAccess
    private let imageProcessor: any ExtractedImagePreparing
    private let worker = DispatchQueue(label: "ZipImageViewer.archive-import", qos: .userInitiated)
    private var operation: Operation?
    private var operationTask: Task<Void, Never>?
    private let cacheStore: ArchiveCacheStore
    private let usesProductionWorkspace: Bool
    private var preparedSession: ArchiveReaderSession?
    private var clearingCache = false
    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?
    var isBusy: Bool { operation != nil || clearingCache }

    init(
        rootDirectory: URL? = nil,
        extractor: ArchiveExtracting = SevenZipExtractor(),
        sourceAccess: SourceAccess = SourceAccess(),
        cacheStore: ArchiveCacheStore? = nil,
        imageProcessor: any ExtractedImagePreparing = ExtractedImageProcessor()
    ) {
        self.rootDirectory = rootDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipImageViewer7zImports", isDirectory: true)
        self.usesProductionWorkspace = rootDirectory == nil
        self.extractor = extractor
        self.sourceAccess = sourceAccess
        self.imageProcessor = imageProcessor
        if let cacheStore {
            self.cacheStore = cacheStore
        } else if let rootDirectory {
            self.cacheStore = ArchiveCacheStore(
                cacheDirectory: rootDirectory.appendingPathComponent("retained", isDirectory: true),
                supportDirectory: rootDirectory.appendingPathComponent("catalog", isDirectory: true))
        } else {
            self.cacheStore = .shared
        }
    }

    /// Transfers the pending lease to the viewer without changing the legacy state API.
    func takePreparedSession() -> ArchiveReaderSession? {
        defer { preparedSession = nil }
        return preparedSession
    }

    func beginImport(from source: URL, compressExtractedImages: Bool? = nil) async {
        guard !isBusy, !Task.isCancelled else { return }
        preparedSession?.release()
        preparedSession = nil
        let current = Operation(root: rootDirectory, source: source,
                                compressExtractedImages: compressExtractedImages ?? cacheStore.preferences.compressExtractedImages)
        operation = current
        setState(.copying)
        let task = Task { await self.copyAndExtract(source: source, operation: current) }
        operationTask = task
        await waitForOperation(task, operation: current)
    }

    /// An empty password is a submitted value; cancellation is represented by `cancel()`.
    func submitPassword(_ password: String) async {
        guard let current = operation, !current.cancelled,
              case .awaitingPassword = state else { return }
        // Change state before yielding so a second submission cannot start another decoder.
        setState(.opening)
        let task = Task { await self.extract(operation: current, password: password) }
        operationTask = task
        await waitForOperation(task, operation: current)
    }

    private func waitForOperation(_ task: Task<Void, Never>, operation current: Operation) async {
        await withTaskCancellationHandler {
            await task.value
            if Task.isCancelled, operation === current { await cancel() }
        } onCancel: {
            // This handler can execute on any thread, so touch only the thread-safe token here.
            current.cancellation.cancel()
            Task { @MainActor [weak self] in
                guard let self, self.operation === current else { return }
                await self.cancel()
            }
        }
    }

    /// Abort may be requested from the main actor, but files stay alive until native work returns.
    func cancel() async {
        guard let current = operation else { return }
        if !current.cancelled {
            current.cancelled = true
            current.attemptID = nil
            current.cancellation.cancel()
            setState(.cancelling)
        }
        let runningTask = operationTask
        await runningTask?.value
        guard operation === current else { return }
        await remove(current.directory)
        guard operation === current else { return }
        operation = nil
        operationTask = nil
        setState(.idle)
    }

    func clearCache() async throws {
        guard !clearingCache else { return }
        clearingCache = true
        defer { clearingCache = false }
        await cancel()
        preparedSession?.release()
        preparedSession = nil
        let store = cacheStore
        let result: Result<Void, Error> = await onWorker { try store.clear() }
        setState(.idle)
        try result.get()
    }

    private func copyAndExtract(source: URL, operation current: Operation) async {
        let store = cacheStore
        let access = sourceAccess
        let prepareWorkspace = usesProductionWorkspace
        let result: Result<CopyResult, Error> = await onWorker {
            if prepareWorkspace { ArchiveImportWorkspace.prepare() }
            let scoped = access.start(source)
            defer { if scoped { access.stop(source) } }
            try current.cancellation.checkCancellation()
            var coordinationError: NSError?
            var prepared: Result<CopyResult, Error>?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
                prepared = Result {
                    let signature = try ArchiveIdentity.signature(for: readableURL, identityURL: source,
                                                                 cancellation: current.cancellation.checkCancellation)
                    if let session = try store.acquire(signature: signature) {
                        return .cached(session)
                    }
                    try FileManager.default.createDirectory(at: current.directory, withIntermediateDirectories: true)
                    try ArchiveImportWorkspace.checkCopySpace(for: readableURL, in: current.directory)
                    try access.copy(readableURL, current.archive)
                    try current.cancellation.checkCancellation()
                    return .copied(signature)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let prepared else { throw ArchiveImportError.storageFailure }
            return try prepared.get()
        }
        guard isCurrent(current) else { return }
        switch result {
        case .success(.cached(let session)):
            preparedSession = session
            operation = nil
            operationTask = nil
            setState(.completed(session.imageURLs))
        case .success(.copied(let signature)):
            current.signature = signature
            await extract(operation: current, password: nil)
        case .failure(let error):
            await fail(error, operation: current)
        }
    }

    private func extract(operation current: Operation, password: String?) async {
        guard isCurrent(current) else { return }
        let attemptID = UUID()
        current.attemptID = attemptID
        let output = current.directory.appendingPathComponent(attemptID.uuidString, isDirectory: true)
        let decoder = extractor
        setState(.opening)
        let result: Result<[URL], Error> = await onWorker {
            try current.cancellation.checkCancellation()
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let images = try decoder.extract(
                archiveURL: current.archive, destinationURL: output, password: password,
                cancellation: current.cancellation
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(current), current.attemptID == attemptID else { return }
                    self.publish(progress)
                }
            }
            try current.cancellation.checkCancellation()
            guard !images.isEmpty else { throw ArchiveImportError.noSupportedImages }
            guard images.allSatisfy({ Self.isRegularFile($0) && Self.isInside($0, directory: output) }) else {
                throw ArchiveImportError.unsafeOutput("The extracted images are outside the output directory or are not regular files.")
            }
            return images
        }
        current.attemptID = nil
        guard isCurrent(current) else { return }
        switch result {
        case .success(let images):
            let preparationID = UUID()
            current.attemptID = preparationID
            setState(current.compressExtractedImages ? .compressing(0) : .preparingPreviews(0))
            let processor = imageProcessor
            let preparation: Result<[ArchivePreparedPage], Error> = await onWorker {
                try processor.prepare(images: images, imageRoot: output,
                                      compress: current.compressExtractedImages,
                                      cancellation: current.cancellation.checkCancellation) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrent(current), current.attemptID == preparationID else { return }
                        self.setState(current.compressExtractedImages ? .compressing(fraction) : .preparingPreviews(fraction))
                    }
                }
            }
            current.attemptID = nil
            guard isCurrent(current) else { return }
            let pages: [ArchivePreparedPage]
            switch preparation {
            case .success(let prepared): pages = prepared
            case .failure(let error):
                // Post-extraction errors must never be presented as password failures.
                await fail(error, operation: current)
                return
            }
            setState(.finalizing)
            guard let signature = current.signature else {
                await fail(ArchiveImportError.storageFailure, operation: current)
                return
            }
            let store = cacheStore
            let publication: Result<ArchiveReaderSession, Error> = await onWorker {
                try current.cancellation.checkCancellation()
                return try store.publish(preparedPages: pages, imageRoot: output,
                                         displayName: current.source.lastPathComponent,
                                         sourceIdentity: current.source.standardizedFileURL.path,
                                         signature: signature, format: current.source.pathExtension.lowercased(),
                                         cancellation: current.cancellation.checkCancellation)
            }
            guard operation === current else {
                if case .success(let session) = publication { session.release() }
                return
            }
            switch publication {
            case .success(let session):
                // Durable publication is the cancellation cutoff. It may already
                // have replaced an older snapshot, so a later cancellation cannot
                // turn the committed import into an apparent failure or idle state.
                preparedSession = session
                operation = nil
                operationTask = nil
                setState(.completed(session.imageURLs))
                await remove(current.directory)
            case .failure(let error):
                guard isCurrent(current) else { return }
                await fail(error, operation: current)
            }
        case .failure(let error):
            await remove(output)
            guard isCurrent(current) else { return }
            if let failure = error as? ArchiveImportError, Self.canRequestPassword(failure) {
                operationTask = nil
                setState(.awaitingPassword(failure))
            } else {
                await fail(error, operation: current)
            }
        }
    }

    private func fail(_ error: Error, operation current: Operation) async {
        await remove(current.directory)
        guard isCurrent(current) else { return }
        operation = nil
        operationTask = nil
        if (error as? ArchiveImportError) == .cancelled { setState(.idle) }
        else { setState(.failed(error)) }
    }

    private func isCurrent(_ current: Operation) -> Bool {
        operation === current && !current.cancelled && !current.cancellation.isCancelled
    }

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }

    private func publish(_ progress: ArchiveImportProgress) {
        switch progress.stage {
        case .copying: setState(.copying)
        case .opening: setState(.opening)
        case .extracting: setState(.extracting(progress.fractionCompleted))
        case .finalizing: setState(.finalizing)
        }
    }

    private nonisolated static func canRequestPassword(_ error: ArchiveImportError) -> Bool {
        switch error {
        case .passwordRequired, .openFailed, .passwordOrDamagedArchive: return true
        default: return false
        }
    }

    private nonisolated static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private nonisolated static func isInside(_ url: URL, directory: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/")
    }

    private func remove(_ url: URL) async {
        let _: Result<Void, Error> = await onWorker {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private func onWorker<T>(_ body: @escaping () throws -> T) async -> Result<T, Error> {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume(returning: Result(catching: body)) }
        }
    }
}
