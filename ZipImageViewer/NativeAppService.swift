import UIKit
import UniformTypeIdentifiers

/// The process owns files and sessions. React modules are disposable subscribers.
/// This object deliberately has no view hierarchy and survives JS reloads.
@MainActor
@objc(NativeAppService)
final class NativeAppService: NSObject, UIDocumentPickerDelegate {
    @objc static let shared: NativeAppService = {
        #if DEBUG && targetEnvironment(simulator)
        if let value = ProcessInfo.processInfo.environment["ZIPIMAGEVIEWER_TEST_CACHE_ID"],
           let id = UUID(uuidString: value) {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ZipImageViewerRNTests").appendingPathComponent(id.uuidString)
            let defaults = UserDefaults(suiteName: "ZipImageViewerRNTests.\(id.uuidString)")!
            return NativeAppService(cacheStore: ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
                supportDirectory: root.appendingPathComponent("support"), defaults: defaults),
                preferencesStore: ReaderPreferencesStore(defaults: defaults))
        }
        #endif
        return NativeAppService()
    }()
    static let stateNotification = Notification.Name("ZipImageViewerNativeStateChanged")
    let cacheStore: ArchiveCacheStore
    let preferencesStore: ReaderPreferencesStore
    private let worker = DispatchQueue(label: "ZipImageViewer.react-services", qos: .userInitiated)
    private let zip: ArchiveService
    private let sevenZip: ArchiveImportCoordinator
    private let inboxDirectory: URL
    private weak var presenter: UIViewController?
    private weak var reader: ImageViewerViewController?
    private weak var activePicker: UIDocumentPickerViewController?
    private var pendingPicker = false
    private var completingPicker = false
    private var session: ArchiveReaderSession?
    private var readerID: String?
    private var readerUI: [String: Any]?
    private var readerTool: String?
    private var readerNotice: String?
    private var readerNoticePending = false
    private var seekSequence = -1
    private var pendingPresentation: ArchiveReaderSession?
    private var progressEmission: DispatchWorkItem?
    private var lastProgressEmission = Date.distantPast
    private var revision = 0
    private var ready = false
    private var working = false
    private var archives: [CachedArchiveSummary] = []
    private var usage = ArchiveCacheUsage(retainedBytes: 0, archiveCount: 0, pendingDeletionBytes: 0)
    private var limits = ArchiveCachePreferences()
    private var operationID: String?
    private var importState: [String: Any]?
    private var zipRequest: ArchiveService.Request?
    private var zipCancellation: ArchiveCancellationToken?
    private var filename = "Archive"
    private var errors: [[String: String]] = []
    private var preview: (token: String, preferences: ArchiveCachePreferences, impact: ArchiveCacheEvictionImpact, changed: Bool)?
    private var pendingProgress: (UUID, String?, Int)?
    private var progressWrite: DispatchWorkItem?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var pendingExternalArchive: ExternalArchive?
    private var activeExternalArchive: ExternalArchive?

    private final class ExternalArchive {
        let url: URL
        private let scoped: Bool
        private let removesInboxCopy: Bool

        init(_ url: URL, openInPlace: Bool, inboxDirectory: URL) {
            self.url = url
            scoped = url.isFileURL && url.startAccessingSecurityScopedResource()
            // Only a regular, direct child of our own Inbox is disposable. In
            // particular, never follow a symlink or delete an external original.
            let inInbox = !openInPlace && url.isFileURL &&
                url.deletingLastPathComponent().resolvingSymlinksInPath().path == inboxDirectory.resolvingSymlinksInPath().path
            let values = inInbox ? (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])) : nil
            removesInboxCopy = inInbox &&
                values?.isRegularFile == true && values?.isSymbolicLink == false
        }

        deinit {
            if removesInboxCopy { try? FileManager.default.removeItem(at: url) }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    override convenience init() {
        self.init(cacheStore: .shared, preferencesStore: ReaderPreferencesStore())
    }

    init(cacheStore: ArchiveCacheStore, preferencesStore: ReaderPreferencesStore, inboxDirectory: URL? = nil) {
        self.cacheStore = cacheStore
        self.preferencesStore = preferencesStore
        zip = ArchiveService(cacheStore: cacheStore)
        sevenZip = ArchiveImportCoordinator(cacheStore: cacheStore)
        self.inboxDirectory = inboxDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
        super.init()
        sevenZip.onStateChange = { [weak self] state in self?.sevenZipChanged(state) }
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
            name: ReaderPreferencesStore.didChangeNotification, object: preferencesStore)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(activated),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    func attach(presenter: UIViewController) {
        self.presenter = presenter
        Task {
            await refresh(); presentPendingNativeUI()
            #if DEBUG && targetEnvironment(simulator)
            importTestFixtureIfNeeded()
            #endif
        }
    }

    private static func supportsExternalArchive(_ source: URL) -> Bool {
        source.isFileURL && ["zip", "cbz", "7z"].contains(source.pathExtension.lowercased())
    }

    /// One delivery opens one supported archive, without an error for every
    /// additional selection. Disposable Inbox copies of ignored items are freed.
    func openExternalArchives(_ sources: [(url: URL, openInPlace: Bool)]) {
        guard let selected = sources.firstIndex(where: { Self.supportsExternalArchive($0.url) }) ?? sources.indices.first else { return }
        openExternalArchive(sources[selected].url, openInPlace: sources[selected].openInPlace)
        for index in sources.indices where index != selected {
            let source = sources[index]
            guard !isReservedExternalURL(source.url) else { continue }
            _ = ExternalArchive(source.url, openInPlace: source.openInPlace, inboxDirectory: inboxDirectory)
        }
    }

    private func isReservedExternalURL(_ source: URL) -> Bool {
        [pendingExternalArchive?.url, activeExternalArchive?.url].compactMap { $0 }
            .contains { $0.standardizedFileURL == source.standardizedFileURL }
    }

    func openExternalArchive(_ source: URL, openInPlace: Bool = true) {
        // A repeated delivery must not delete the Inbox file an active import
        // still owns, even when that repeated request is rejected as busy.
        guard !isReservedExternalURL(source) else {
            failMessage("Unable to Open Archive", ServiceError.busy.localizedDescription)
            return
        }
        let incoming = ExternalArchive(source, openInPlace: openInPlace, inboxDirectory: inboxDirectory)
        guard Self.supportsExternalArchive(source) else {
            failMessage("Unable to Open Archive", "Choose a ZIP, CBZ, or 7z file.")
            return
        }
        guard !working, operationID == nil, !pendingPicker, activePicker == nil,
              pendingExternalArchive == nil else {
            failMessage("Unable to Open Archive", ServiceError.busy.localizedDescription)
            return
        }
        pendingExternalArchive = incoming
        changed()
        Task {
            if !ready { await refresh() }
            presentPendingNativeUI()
        }
    }

    private func openPendingExternalArchive() {
        guard ready, presenter != nil, !working, operationID == nil,
              let pending = pendingExternalArchive else { return }
        if let opened = pendingPresentation {
            pendingPresentation = nil
            opened.release()
        }
        if let opened = session {
            if reader?.presentingViewController == nil { close(opened) }
            else { reader?.closeFromHost() }
            return
        }
        pendingExternalArchive = nil
        activeExternalArchive = pending
        preview = nil
        beginImport(pending.url)
    }

    #if DEBUG && targetEnvironment(simulator)
    private var importedTestFixture = false
    private func importTestFixtureIfNeeded() {
        guard !importedTestFixture, ready,
              UUID(uuidString: ProcessInfo.processInfo.environment["ZIPIMAGEVIEWER_TEST_CACHE_ID"] ?? "") != nil,
              let encoded = ProcessInfo.processInfo.environment["ZIPIMAGEVIEWER_RN_TEST_ARCHIVE"],
              let data = Data(base64Encoded: encoded) else { return }
        importedTestFixture = true
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("rn-test-\(UUID()).7z")
        do { try data.write(to: source); beginImport(source) }
        catch { fail(error) }
    }
    #endif

    @objc func getSnapshot(_ completion: @escaping (String?, NSError?) -> Void) {
        Task {
            if !ready { await refresh() }
            completion(snapshot(), nil)
        }
    }

    @objc func dispatch(_ json: String, completion: @escaping (String?, NSError?) -> Void) {
        Task {
            do {
                guard let data = json.data(using: .utf8),
                      let command = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = command["type"] as? String else { throw ServiceError.invalidCommand }
                try await execute(type, command)
                completion(snapshot(), nil)
            } catch { completion(nil, error as NSError) }
        }
    }

    private var busy: Bool { working || operationID != nil || session != nil || pendingPresentation != nil }
    private func requireIdle() throws {
        guard ready, !busy, pendingExternalArchive == nil else { throw ServiceError.busy }
    }

    private func execute(_ type: String, _ command: [String: Any]) async throws {
        switch type {
        case "refresh": await refresh()
        case "pickArchive":
            try requireIdle()
            guard presenter != nil else { throw ServiceError.busy }
            // Reserve first, even if RN's Details sheet is still dismissing.
            // presentationReady resumes this request after UIKit finishes it.
            pendingPicker = true
            working = true
            changed()
            presentPendingNativeUI()
        case "openArchive":
            try requireIdle()
            guard let id = (command["id"] as? String).flatMap(UUID.init(uuidString:)) else { throw ServiceError.invalidCommand }
            working = true
            changed()
            Task {
                do { let opened = try await onWorker { try self.cacheStore.acquire(id: id) }; self.prepareReader(opened) }
                catch { self.fail(error) }
                self.working = false
                await self.refresh()
            }
        case "submitPassword":
            guard command["operationId"] as? String == operationID, operationID != nil,
                  importState?["passwordRequired"] as? Bool == true,
                  let password = command["password"] as? String else { throw ServiceError.staleOperation }
            setImport(phase: "opening", cancellable: true)
            if let request = zipRequest { extractZIP(request, password: password) }
            else { Task { await sevenZip.submitPassword(password) } }
        case "cancelImport":
            guard command["operationId"] as? String == operationID, operationID != nil,
                  importState?["cancellable"] as? Bool == true else { throw ServiceError.staleOperation }
            let wasWaitingForPassword = importState?["passwordRequired"] as? Bool == true
            setImport(phase: "cancelling", cancellable: false)
            if let cancellation = zipCancellation {
                cancellation.cancel()
                // Running work owns rollback; waiting-for-password has no active worker.
                guard let request = zipRequest, wasWaitingForPassword else { return }
                zipRequest = nil
                Task {
                    do { try await onWorker { try self.zip.discard(request) } }
                    catch { fail(error) }
                    finishImport(); await refresh()
                }
            } else { Task { await sevenZip.cancel() } }
        case "presentationReady": presentPendingNativeUI()
        case "closeReader":
            if let pending = pendingPresentation { pendingPresentation = nil; pending.release(); changed() }
            else if let opened = session, reader?.presentingViewController == nil {
                // Sorting publishes the reservation before UIKit presentation.
                // A controller never presented has no dismissal callback to wait for.
                working = false
                close(opened)
            } else { reader?.closeFromHost() }
        case "readerAction":
            guard let id = command["readerId"] as? String, id == readerID, session != nil,
                  let action = command["action"] as? String else { throw ServiceError.staleOperation }
            switch action {
            case "close": reader?.closeFromHost()
            case "back": readerBack()
            case "openJump": readerTool = "jump"; changed()
            case "openPages": readerTool = "pages"; changed()
            case "openSettings": readerTool = "settings"; changed()
            case "openHelp": readerTool = "help"; changed()
            case "dismissTool": readerTool = nil; changed()
            case "acknowledgeNotice": readerNoticePending = false; changed()
            case "seek":
                guard let page = Self.readerInteger(command["page"]), let sequence = Self.readerInteger(command["sequence"]),
                      sequence >= 0, let reader, (1...max(1, reader.imageUrls.count)).contains(page) else { throw ServiceError.invalidCommand }
                if sequence > seekSequence {
                    seekSequence = sequence
                    let scrubbing = (command["scrubbing"] as? Bool) ?? false
                    reader.performSharedAction(action, page: page, scrubbing: scrubbing)
                }
            case "rotateCounterclockwise", "rotateClockwise", "toggleControls", "showControls", "retry", "retryDetail":
                guard let reader else { throw ServiceError.busy }
                reader.performSharedAction(action, page: nil, scrubbing: false)
            default: throw ServiceError.invalidCommand
            }
        case "updatePreferences":
            guard let raw = command["preferences"] as? [String: Any] else { throw ServiceError.invalidCommand }
            preferencesStore.update(try Self.decodePreferences(raw))
        case "setCompression":
            try requireIdle()
            guard let enabled = command["enabled"] as? Bool else { throw ServiceError.invalidCommand }
            working = true
            defer { working = false; changed() }
            try await onWorker {
                var prefs = self.cacheStore.preferences
                prefs.compressExtractedImages = enabled
                try self.cacheStore.updatePreferences(prefs)
            }
            await refresh()
        case "removeArchive", "clearArchives":
            try requireIdle()
            let id = (command["id"] as? String).flatMap(UUID.init(uuidString:))
            guard type == "clearArchives" || id != nil else { throw ServiceError.invalidCommand }
            working = true
            defer { working = false; changed() }
            try await onWorker {
                if let id { try self.cacheStore.remove(id: id) } else { try self.cacheStore.clear() }
            }
            await refresh()
        case "previewCacheLimits":
            try requireIdle()
            guard let raw = command["limits"] as? [String: Any], let bytes = raw["maximumBytes"] as? NSNumber,
                  bytes.doubleValue.isFinite, bytes.doubleValue > 0, bytes.doubleValue <= Double(Int64.max),
                  bytes.doubleValue.rounded() == bytes.doubleValue else { throw ServiceError.invalidCommand }
            var prefs = limits
            prefs.maximumBytes = bytes.int64Value
            if let count = raw["maximumArchiveCount"] as? NSNumber {
                guard count.doubleValue > 0, count.doubleValue <= Double(Int.max), count.doubleValue.rounded() == count.doubleValue else { throw ServiceError.invalidCommand }
                prefs.maximumArchiveCount = count.intValue
            } else if raw["maximumArchiveCount"] is NSNull { prefs.maximumArchiveCount = nil }
            else { throw ServiceError.invalidCommand }
            working = true
            defer { working = false; changed() }
            let proposed = prefs
            let impact = try await onWorker { try self.cacheStore.evictionImpact(for: proposed) }
            preview = (UUID().uuidString, proposed, impact, false)
        case "applyCachePreview":
            try requireIdle()
            guard let confirmed = preview, command["token"] as? String == confirmed.token else { throw ServiceError.staleOperation }
            working = true
            defer { working = false; changed() }
            // Preserve any later compression preference; this confirmation changes only quotas.
            var proposed = confirmed.preferences
            proposed.compressExtractedImages = limits.compressExtractedImages
            let preferences = proposed
            let changedImpact = try await onWorker {
                try self.cacheStore.applyPreferences(preferences, confirmedArchiveIDs: confirmed.impact.archiveIDs)
            }
            if let impact = changedImpact { preview = (UUID().uuidString, preferences, impact, true) }
            else { preview = nil }
            await refresh()
        case "dismissCachePreview": preview = nil; changed()
        case "dismissError":
            if errors.first?["id"] == command["id"] as? String { errors.removeFirst(); changed() }
        default: throw ServiceError.invalidCommand
        }
    }

    private func presentPendingNativeUI() {
        if pendingExternalArchive != nil {
            openPendingExternalArchive()
            return
        }
        if pendingPicker {
            guard UIApplication.shared.applicationState == .active,
                  let presenter, presenter.viewIfLoaded?.window != nil,
                  presenter.presentedViewController == nil, presenter.transitionCoordinator == nil else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.zip,
                UTType(filenameExtension: "cbz") ?? .data, UTType(filenameExtension: "7z") ?? .data], asCopy: false)
            picker.allowsMultipleSelection = false
            picker.delegate = self
            pendingPicker = false
            activePicker = picker
            presenter.present(picker, animated: true)
        } else { presentPendingReader() }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishPicker(controller, source: nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finishPicker(controller, source: urls.first)
    }

    private func finishPicker(_ controller: UIDocumentPickerViewController, source: URL?) {
        guard activePicker === controller, !completingPicker else { return }
        completingPicker = true
        // Keep the reservation through dismissal, including cancellation, so a
        // second command cannot present during the native picker transition.
        controller.dismiss(animated: true) { [weak self] in
            guard let self, self.activePicker === controller else { return }
            self.activePicker = nil
            self.completingPicker = false
            self.working = false
            if let source { self.beginImport(source) } else { self.changed() }
        }
    }

    func beginImport(_ source: URL) {
        guard ready, !busy else { return }
        operationID = UUID().uuidString
        filename = source.lastPathComponent
        let compress = limits.compressExtractedImages
        setImport(phase: "preparingSource", cancellable: true)
        if source.pathExtension.lowercased() == "7z" {
            Task { await sevenZip.beginImport(from: source, compressExtractedImages: compress) }
        } else {
            let cancellation = ArchiveCancellationToken()
            zipCancellation = cancellation
            let token = operationID
            let stages = stageCallback(token)
            Task {
                do {
                    let preparation = try await onWorker { try self.zip.prepareArchive(at: source, compressExtractedImages: compress, cancellation: cancellation, onStage: stages) }
                    if cancellation.isCancelled {
                        await onWorkerValue {
                            if case .archive(let request) = preparation { try? self.zip.discard(request) }
                            self.zip.takePreparedSession()?.release()
                        }
                        throw ArchiveImportError.cancelled
                    }
                    switch preparation {
                    case .cached:
                        let opened = await onWorkerValue { self.zip.takePreparedSession() }
                        finishImport()
                        if cancellation.isCancelled { opened?.release() }
                        else if let opened { prepareReader(opened) }
                    case .archive(let request):
                        zipRequest = request
                        if request.requiresPassword { passwordPrompt("This archive is encrypted. Enter the password to continue.") }
                        else { extractZIP(request, password: nil) }
                    }
                } catch { finishImport(); if (error as? ArchiveImportError) != .cancelled { fail(error) }; await refresh() }
            }
        }
    }

    private func stageCallback(_ token: String?) -> (ImportPresentationState) -> Void {
        { [weak self] state in
            Task { @MainActor in
                guard let self, self.operationID == token, token != nil,
                      state.stage != .completed, state.stage != .failed, state.stage != .waitingForPassword,
                      self.zipCancellation?.isCancelled != true else { return }
                self.setImport(phase: String(describing: state.stage), fraction: state.progress, cancellable: state.canCancel)
            }
        }
    }

    private func extractZIP(_ request: ArchiveService.Request, password: String?) {
        let callback = stageCallback(operationID)
        guard let cancellation = zipCancellation else { return }
        Task {
            do {
                let opened: ArchiveReaderSession? = try await onWorker {
                    _ = try self.zip.extract(request, password: password, cancellation: cancellation, onStage: callback)
                    return self.zip.takePreparedSession()
                }
                zipRequest = nil
                finishImport()
                if cancellation.isCancelled { opened?.release() }
                else if let opened { prepareReader(opened) }
                await refresh()
            } catch {
                if cancellation.isCancelled {
                    try? await onWorker { try self.zip.discard(request) }
                    zipRequest = nil; finishImport(); await refresh()
                } else if case ArchiveService.ImportError.zipExtractionFailed = error {
                    passwordPrompt("The password may be incorrect or the archive may be damaged. You can try another password.")
                } else { zipRequest = nil; finishImport(); if (error as? ArchiveImportError) != .cancelled { fail(error) }; await refresh() }
            }
        }
    }

    private func sevenZipChanged(_ state: ArchiveImportCoordinator.State) {
        switch state {
        case .idle: finishImport(); Task { await refresh() }
        case .awaitingPassword(let error): passwordPrompt(error.localizedDescription)
        case .completed:
            let opened = sevenZip.takePreparedSession()
            finishImport()
            if let opened { prepareReader(opened) }
            Task { await refresh() }
        case .failed(let error): finishImport(); fail(error); Task { await refresh() }
        default:
            if let value = ImportPresentationState.from(coordinatorState: state, filename: filename) {
                setImport(phase: String(describing: value.stage), fraction: value.progress, cancellable: value.canCancel)
            }
        }
    }

    private func setImport(phase: String, fraction: Double? = nil, cancellable: Bool) {
        guard let operationID else { return }
        let phaseChanged = importState?["phase"] as? String != phase
        importState = ["id": operationID, "phase": phase, "fraction": fraction as Any? ?? NSNull(),
                       "busy": true, "passwordRequired": false, "cancellable": cancellable]
        if phaseChanged || Date().timeIntervalSince(lastProgressEmission) >= 0.1 {
            lastProgressEmission = Date(); changed()
        } else if progressEmission == nil {
            let pending = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lastProgressEmission = Date(); self.changed()
            }
            progressEmission = pending
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: pending)
        }
    }

    private func passwordPrompt(_ message: String) {
        setImport(phase: "waitingForPassword", cancellable: true)
        importState?["passwordRequired"] = true
        importState?["passwordMessage"] = message
        changed()
    }

    private func finishImport() {
        endBackgroundTask(); zipCancellation = nil; zipRequest = nil; operationID = nil; importState = nil
        activeExternalArchive = nil
        changed()
    }

    private func prepareReader(_ opened: ArchiveReaderSession) {
        guard session == nil, pendingPresentation == nil else { opened.release(); return }
        pendingPresentation = opened
        changed()
        presentPendingReader()
    }

    private func presentPendingReader() {
        guard let opened = pendingPresentation, UIApplication.shared.applicationState == .active,
              let presenter, presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil, presenter.transitionCoordinator == nil else { return }
        pendingPresentation = nil
        session = opened
        let controller = ImageViewerViewController()
        reader = controller
        readerID = UUID().uuidString; seekSequence = -1; readerTool = nil; readerUI = nil
        var notices: [String] = []
        if opened.isTemporary { notices.append("This archive exceeds your cache limit and will be removed when you close it. Your original archive stays unchanged.") }
        if let warning = opened.cleanupWarning { notices.append(warning) }
        readerNotice = notices.isEmpty ? nil : notices.joined(separator: "\n\n")
        readerNoticePending = readerNotice != nil
        controller.sharedChromeView = ReactAppHost.shared.readerControlsView()
        controller.onReaderUIChanged = { [weak self, weak opened] value in
            guard let self, self.session === opened else { return }
            if let previous = self.readerUI, NSDictionary(dictionary: previous).isEqual(to: value) { return }
            self.readerUI = value; self.changed()
        }
        controller.onReaderToolRequested = { [weak self] tool in
            guard let self else { return }
            if tool == "back" { self.readerBack() } else { self.readerTool = tool; self.changed() }
        }
        let prefs = preferencesStore.preferences
        // Sorting uses the same native metadata policy as the original reader.
        working = true
        Task {
            let images = await onWorkerValue {
                ImageFileSorter.sort(opened.imageURLs, criterion: prefs.sortCriterion, order: prefs.sortOrder, metadata: opened.pageMetadata)
            }
            guard self.session === opened else { opened.release(); return }
            controller.imageUrls = images
            controller.pageMetadata = opened.pageMetadata
            controller.previewURLs = opened.previewURLs
            controller.retainImageWork = { opened.retainForImageWork() }
            controller.currentIndex = opened.restoredIndex(in: images)
            controller.archiveTitle = opened.displayName
            controller.applyPreferences(self.preferencesStore.preferences)
            controller.onPositionChange = { [weak self] url, index in self?.scheduleProgress(opened, url, index) }
            controller.onFlushProgress = { [weak self] in self?.flushProgress() }
            controller.onClose = { [weak self] in self?.close(opened) }
            controller.onSettingsRequested = { [weak self] in self?.readerTool = "settings"; self?.changed() }
            controller.modalPresentationStyle = .fullScreen
            controller.view.accessibilityIdentifier = "imageViewer"
            self.working = false
            guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil,
                  UIApplication.shared.applicationState == .active else {
                self.reader = nil; self.session = nil; self.pendingPresentation = opened; self.changed(); self.presentPendingReader(); return
            }
            presenter.present(controller, animated: true)
            self.changed()
        }
    }

    private func readerBack() {
        if readerTool != nil { readerTool = nil; changed() }
        else if reader?.chromeVisible == false { reader?.setChromeVisible(true) }
        else { reader?.closeFromHost() }
    }

    /// Native overview decoders retain the session through their completed work.
    static func readerInteger(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= 9_007_199_254_740_991, value.rounded(.down) == value else { return nil }
        return Int(value)
    }

    func thumbnailSource(readerID id: String, index: Int) -> ([URL], () -> Void)? {
        guard id == readerID, let session, let reader, reader.imageUrls.indices.contains(index) else { return nil }
        let page = reader.imageUrls[index]
        return (reader.previewURLs[page].map { [$0, page] } ?? [page], session.retainForImageWork())
    }

    private func scheduleProgress(_ session: ArchiveReaderSession, _ url: URL, _ index: Int) {
        pendingProgress = (session.archiveID, session.relativePath(for: url), index)
        progressWrite?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.flushProgress() }
        progressWrite = task
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: task)
    }

    private func flushProgress() {
        progressWrite?.cancel(); progressWrite = nil
        guard let progress = pendingProgress else { return }
        pendingProgress = nil
        worker.async {
            do { try self.cacheStore.saveProgress(archiveID: progress.0, relativePath: progress.1, index: progress.2) }
            catch { Task { @MainActor in self.failMessage("Unable to Save Position", error.localizedDescription) } }
        }
    }

    private func close(_ opened: ArchiveReaderSession) {
        guard session === opened else { return }
        flushProgress()
        session = nil; reader = nil; readerID = nil; readerUI = nil; readerTool = nil; readerNotice = nil; readerNoticePending = false
        // Same queue guarantees final progress precedes lease release.
        worker.async {
            opened.release()
            Task { @MainActor in await self.refresh(); self.presentPendingNativeUI() }
        }
        changed()
    }

    @objc func reactDidDetach() {
        // A reload during a drag finishes the native selection without closing its lease.
        if let reader { reader.performSharedAction("seek", page: reader.currentIndex + 1, scrubbing: false) }
    }

    @objc private func preferencesChanged() {
        reader?.applyPreferences(preferencesStore.preferences)
        changed()
    }

    @objc private func activated() { Task { await refresh(); presentPendingNativeUI() } }
    @objc private func backgrounded() {
        flushProgress()
        guard sevenZip.isBusy || zipCancellation != nil else { return }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Archive cleanup") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
        }
        if let cancellation = zipCancellation {
            cancellation.cancel()
            if let request = zipRequest, importState?["passwordRequired"] as? Bool == true {
                zipRequest = nil
                Task {
                    try? await onWorker { try self.zip.discard(request) }
                    finishImport(); await refresh()
                }
            } else {
                setImport(phase: "cancelling", cancellable: false)
            }
        } else {
            Task { await sevenZip.cancel(); endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask; backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    private func refresh() async {
        do {
            let result = try await onWorker {
                ArchiveImportWorkspace.prepare()
                return (try self.cacheStore.list(), try self.cacheStore.usage(), self.cacheStore.preferences)
            }
            archives = result.0; usage = result.1; limits = result.2; ready = true
        } catch {
            ready = false
            pendingExternalArchive = nil
            fail(error)
        }
        changed()
    }

    private func fail(_ error: Error) { failMessage("Unable to Complete Operation", error.localizedDescription) }
    private func failMessage(_ title: String, _ message: String) {
        errors.append(["id": UUID().uuidString, "title": title, "message": message]); changed()
    }
    private func changed() {
        progressEmission?.cancel(); progressEmission = nil
        revision += 1
        NotificationCenter.default.post(name: Self.stateNotification, object: snapshot())
    }

    func snapshot() -> String {
        let prefs = preferencesStore.preferences
        var value: [String: Any] = [
            "protocolVersion": 1, "revision": revision, "ready": ready, "busy": working || operationID != nil || pendingExternalArchive != nil,
            "capabilities": ["pickerPreferences": false],
            "archives": archives.map { ["id": $0.id.uuidString, "title": $0.displayName, "pageCount": $0.imageCount,
                "retainedBytes": $0.retainedBytes, "available": $0.isAvailable, "progress": $0.imageCount > 0 ? Double(min(max(1, $0.position.index + 1), $0.imageCount)) / Double($0.imageCount) : 0,
                "currentPage": $0.imageCount > 0 ? min(max(1, $0.position.index + 1), $0.imageCount) : 0, "format": $0.format,
                "lastOpenedAt": ISO8601DateFormatter().string(from: $0.lastOpenedAt)] as [String: Any] },
            "preferences": ["showRotationButtons": prefs.showRotationButtons, "showSlider": prefs.showPageSlider, "showCount": prefs.showPageCount,
                "doubleTapZoom": prefs.enableDoubleTapZoom, "centerTap": prefs.centerTapTogglesControls, "reversed": prefs.readingDirectionReversed,
                "animate": prefs.enablePageTurnAnimation, "tapRatio": prefs.previousPageTapWidthRatio,
                "sortCriterion": prefs.sortCriterion == .filename ? "filename" : prefs.sortCriterion == .modifiedDate ? "modified" : "created",
                "descending": prefs.sortOrder == .descending, "thumbnailSize": prefs.thumbnailSize],
            "compressImages": limits.compressExtractedImages,
            "cache": ["maximumBytes": limits.maximumBytes, "maximumArchiveCount": limits.maximumArchiveCount as Any? ?? NSNull(),
                "retainedBytes": usage.retainedBytes, "archiveCount": usage.archiveCount, "pendingDeletionBytes": usage.pendingDeletionBytes],
            "import": importState as Any? ?? NSNull(), "error": errors.first as Any? ?? NSNull(),
            "reader": (session ?? pendingPresentation).map { opened -> [String: Any] in
                var surface = readerUI ?? ["page": 0, "count": opened.imageURLs.count, "displayedPage": NSNull(),
                    "controls": true, "sorting": true, "failed": false, "detailFailed": false]
                surface["sequence"] = seekSequence
                surface["tool"] = readerTool as Any? ?? NSNull()
                surface["temporary"] = opened.isTemporary
                surface["noticePending"] = readerNoticePending
                if let readerNotice { surface["notice"] = readerNotice }
                return ["id": readerID ?? opened.archiveID.uuidString, "archiveId": opened.archiveID.uuidString, "title": opened.displayName, "ui": surface]
            } as Any? ?? NSNull(),
            "cachePreview": NSNull()
        ]
        if let preview {
            value["cachePreview"] = ["reclaimedBytes": preview.impact.retainedBytes, "token": preview.token, "changed": preview.changed,
                "limits": ["maximumBytes": preview.preferences.maximumBytes, "maximumArchiveCount": preview.preferences.maximumArchiveCount as Any? ?? NSNull()],
                "victims": preview.impact.archives.map { ["id": $0.id.uuidString, "title": $0.displayName] }]
        }
        // Only property-list primitives are constructed here; serialization failure is a programmer error.
        guard let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("Invalid native snapshot")
        }
        return text
    }

    static func decodePreferences(_ raw: [String: Any]) throws -> ReaderPreferences {
        var prefs = ReaderPreferences()
        guard let slider = raw["showSlider"] as? Bool, let count = raw["showCount"] as? Bool,
              let doubleTap = raw["doubleTapZoom"] as? Bool, let center = raw["centerTap"] as? Bool, let reversed = raw["reversed"] as? Bool,
              let animate = raw["animate"] as? Bool, let ratio = raw["tapRatio"] as? Double,
              let sort = raw["sortCriterion"] as? String, let descending = raw["descending"] as? Bool,
              let size = raw["thumbnailSize"] as? Double,
              ["filename", "modified", "created"].contains(sort), ratio.isFinite, size.isFinite,
              (0.1...0.9).contains(ratio), (0...1).contains(size) else { throw ServiceError.invalidCommand }
        prefs.showPageSlider = slider; prefs.showPageCount = count; prefs.centerTapTogglesControls = center
        prefs.showRotationButtons = (raw["showRotationButtons"] as? Bool) ?? false
        prefs.enableDoubleTapZoom = doubleTap
        prefs.readingDirectionReversed = reversed; prefs.enablePageTurnAnimation = animate
        prefs.previousPageTapWidthRatio = ratio; prefs.thumbnailSize = size
        prefs.sortCriterion = sort == "filename" ? .filename : sort == "modified" ? .modifiedDate : .createdDate
        prefs.sortOrder = descending ? .descending : .ascending
        return prefs
    }

    private func onWorker<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            worker.async { continuation.resume(with: Result(catching: body)) }
        }
    }
    private func onWorkerValue<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in worker.async { continuation.resume(returning: body()) } }
    }
    enum ServiceError: LocalizedError {
        case invalidCommand, staleOperation, busy
        var errorDescription: String? {
            switch self {
            case .invalidCommand: return "The requested operation is invalid."
            case .staleOperation: return "This operation has already changed. Refresh and try again."
            case .busy: return "Finish the current operation before opening another archive or changing storage."
            }
        }
    }
}
