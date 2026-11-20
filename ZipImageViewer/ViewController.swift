//
//  ViewController.swift
//  ZipImageViewer
//
//  Created by Britey on 10/11/2024.
//

import UIKit
import UniformTypeIdentifiers

final class ViewController: UIViewController, UIDocumentPickerDelegate {

    private let cacheStore = ViewController.makeCacheStore()
    private let preferencesStore = ViewController.makePreferencesStore()
    private let library = ArchiveLibraryViewController()
    private var openButton: UIBarButtonItem!
    private var settingsButton: UIBarButtonItem!
    private weak var settingsController: SettingsViewController?
    private weak var activeReader: ImageViewerViewController?
    private var cacheUsage = ArchiveCacheUsage(retainedBytes: 0, archiveCount: 0, pendingDeletionBytes: 0)
    private var cacheError: String?
    private var awaitingStorageConfirmation = false
    private var importID: UUID?
    private var importFilename = "Archive"
    private var importDisplayGeneration = 0
    private var delayedImportDisplay: DispatchWorkItem?
    private var lastImportState: ImportPresentationState?

    private static func makePreferencesStore() -> ReaderPreferencesStore {
        #if DEBUG && targetEnvironment(simulator)
        if let rawID = ProcessInfo.processInfo.environment["ZIPIMAGEVIEWER_TEST_CACHE_ID"],
           let id = UUID(uuidString: rawID),
           let defaults = UserDefaults(suiteName: "ZipImageViewerUITests.Reader.\(id.uuidString)") {
            return ReaderPreferencesStore(defaults: defaults)
        }
        #endif
        return ReaderPreferencesStore()
    }

    private static func makeCacheStore() -> ArchiveCacheStore {
        #if DEBUG && targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        let requestedID = environment["ZIPIMAGEVIEWER_TEST_CACHE_ID"]
        if requestedID != nil || environment["ZIPIMAGEVIEWER_TEST_ARCHIVE"] != nil || environment["ZIPIMAGEVIEWER_TEST_RECENT_FIXTURES"] != nil {
            // Only UUIDs can select a persistent test namespace, never an arbitrary path.
            let id = requestedID.flatMap(UUID.init(uuidString:)) ?? UUID()
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ZipImageViewerUITests").appendingPathComponent(id.uuidString)
            return ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
                                     supportDirectory: root.appendingPathComponent("support"),
                                     defaults: UserDefaults(suiteName: "ZipImageViewerUITests.\(id.uuidString)")!)
        }
        #endif
        return .shared
    }
    private var recentArchives: [CachedArchiveSummary] = []
    private var cachePreferences = ArchiveCachePreferences()
    private var cacheReady = false
    private var recentRefreshGeneration = 0
    private var activeReaderSession: ArchiveReaderSession?
    private var pendingReaderPresentation: (images: [URL], session: ArchiveReaderSession?)?
    private var pendingProgressWrite: DispatchWorkItem?
    private var pendingProgress: (archiveID: UUID, relativePath: String?, index: Int)?
    private lazy var archiveService = ArchiveService(cacheStore: cacheStore)
    private let archiveQueue = DispatchQueue(label: "ZipImageViewer.archive", qos: .userInitiated)
    private var isImporting = false
    private lazy var sevenZipImporter = ArchiveImportCoordinator(cacheStore: cacheStore)
    private var importProgressView: ArchiveImportProgressView?
    private weak var archivePasswordAlert: UIAlertController?
    private var pendingErrors: [(String, String)] = []
    private var errorPresentationScheduled = false
    private var isShowingError = false
    private var isClearingCache = false
    private var backgroundCleanupTask: UIBackgroundTaskIdentifier = .invalid


    override func viewDidLoad() {
        super.viewDidLoad()
        configureLibrary()
        NotificationCenter.default.addObserver(self, selector: #selector(readerPreferencesChanged), name: ReaderPreferencesStore.didChangeNotification, object: preferencesStore)
        refreshRecentArchives()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        sevenZipImporter.onStateChange = { [weak self] state in
            self?.updateArchiveImportUI(state)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(cancelImportInBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    #if DEBUG && targetEnvironment(simulator)
    private var didImportUITestFixture = false
    private var testHomeAppeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        testHomeAppeared = true
        importUITestFixturesIfNeeded()
    }

    private func importUITestFixturesIfNeeded() {
        guard cacheReady, testHomeAppeared, !didImportUITestFixture else { return }
        didImportUITestFixture = true
        let environment = ProcessInfo.processInfo.environment
        if let json = environment["ZIPIMAGEVIEWER_TEST_RECENT_FIXTURES"], let data = json.data(using: .utf8) {
            struct Fixture: Decodable { let name: String; let base64: String }
            performArchiveOperation({ service in
                let fixtures = try JSONDecoder().decode([Fixture].self, from: data)
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                for fixture in fixtures {
                    guard fixture.name == (fixture.name as NSString).lastPathComponent,
                          let contents = Data(base64Encoded: fixture.base64) else { continue }
                    let source = root.appendingPathComponent(fixture.name)
                    try contents.write(to: source, options: .atomic)
                    switch try service.prepareArchive(at: source) {
                    case .archive(let request): _ = try service.extract(request, password: nil)
                    case .cached: break
                    }
                    service.takePreparedSession()?.release()
                }
            }) { [weak self] result in
                if case .failure(let error) = result { self?.showAlert(title: "Test Import Failed", message: error.localizedDescription) }
                self?.refreshRecentArchives()
            }
        } else if let encoded = environment["ZIPIMAGEVIEWER_TEST_ARCHIVE"], let data = Data(base64Encoded: encoded) {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("ui-test-source.7z")
            do {
                try data.write(to: source, options: .atomic)
                beginSevenZipImport(from: source)
            } catch {
                showAlert(title: "Test Import Failed", message: error.localizedDescription)
            }
        }
    }
    #endif

    private var operationBusy: Bool {
        !cacheReady || importID != nil || isImporting || sevenZipImporter.isBusy || isClearingCache || awaitingStorageConfirmation || pendingReaderPresentation != nil
    }

    private func configureLibrary() {
        title = "Library"
        view.backgroundColor = .systemGroupedBackground
        navigationController?.navigationBar.prefersLargeTitles = true
        openButton = UIBarButtonItem(title: "Open Archive", style: .done, target: self, action: #selector(openArchive))
        openButton.accessibilityIdentifier = "openArchive"
        settingsButton = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(openSettings))
        settingsButton.accessibilityLabel = "Settings"
        settingsButton.accessibilityIdentifier = "openSettings"
        navigationItem.rightBarButtonItem = openButton
        navigationItem.leftBarButtonItem = settingsButton
        addChild(library)
        library.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(library.view)
        NSLayoutConstraint.activate([
            library.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            library.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            library.view.topAnchor.constraint(equalTo: view.topAnchor),
            library.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        library.didMove(toParent: self)
        navigationItem.searchController = library.searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = traitCollection.horizontalSizeClass == .compact ? .stacked : .automatic
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: ViewController, _) in
            self.navigationItem.preferredSearchBarPlacement = self.traitCollection.horizontalSizeClass == .compact ? .stacked : .automatic
        }
        navigationItem.largeTitleDisplayMode = .always
        definesPresentationContext = true
        library.onOpen = { [weak self] in self?.openArchive() }
        library.onRetry = { [weak self] in self?.refreshRecentArchives() }
        library.onSelect = { [weak self] in self?.openRecentArchive($0) }
        library.onRemove = { [weak self] in self?.confirmRemoval($0) }
    }

    @objc private func readerPreferencesChanged() {
        activeReader?.applyPreferences(preferencesStore.preferences)
    }

    @objc private func openSettings() { showSettings(from: nil) }

    private func showSettings(from reader: ImageViewerViewController?) {
        let settings = SettingsViewController(store: preferencesStore, includesStorage: reader == nil)
        settingsController = settings
        settings.updateStorage(preferences: cachePreferences, usage: cacheUsage, isBusy: operationBusy, archiveCount: recentArchives.count)
        settings.onRemoveAllCachedArchives = { [weak self] in self?.confirmRemoval(nil) }
        settings.onStoragePreferencesChange = { [weak self] in self?.requestCachePreferences($0) }
        if reader == nil, traitCollection.horizontalSizeClass == .compact, let navigationController {
            navigationController.pushViewController(settings, animated: true)
        } else {
            let navigation = UINavigationController(rootViewController: settings)
            navigation.modalPresentationStyle = .formSheet
            navigation.preferredContentSize = CGSize(width: 620, height: 720)
            (reader ?? self).present(navigation, animated: true)
        }
    }

    private var visiblePresenter: UIViewController {
        var controller: UIViewController = navigationController ?? self
        while true {
            if let presented = controller.presentedViewController { controller = presented }
            else if let navigation = controller as? UINavigationController, let top = navigation.topViewController { controller = top }
            else { return controller }
        }
    }

    private func confirmRemoval(_ archive: CachedArchiveSummary?) {
        guard !operationBusy, archive != nil || !recentArchives.isEmpty else { return }
        awaitingStorageConfirmation = true
        refreshImportControls()
        let title = archive == nil ? "Remove All Cached Archives?" : "Remove Cached Archive?"
        let subject = archive.map { "“\($0.displayName)”" } ?? "\(recentArchives.count) archives"
        let alert = UIAlertController(title: title, message: "Remove cached copies and saved reading positions for \(subject)? Original files will remain.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.awaitingStorageConfirmation = false
            self?.refreshImportControls()
        })
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.awaitingStorageConfirmation = false
            self.mutateCache { store in
                if let archive { try store.remove(id: archive.id) } else { try store.clear() }
            }
        })
        visiblePresenter.present(alert, animated: true)
    }

    private func requestCachePreferences(_ preferences: ArchiveCachePreferences) {
        guard !operationBusy else { return }
        // A compression choice affects future extractions, not retained entries or limits.
        if preferences.maximumBytes == cachePreferences.maximumBytes,
           preferences.maximumArchiveCount == cachePreferences.maximumArchiveCount {
            mutateCache { try $0.updatePreferences(preferences) }
            return
        }
        awaitingStorageConfirmation = true
        refreshImportControls()
        let store = cacheStore
        archiveQueue.async {
            let result = Result { try store.evictionImpact(for: preferences) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let impact):
                    let apply = { [weak self] in
                        guard let self else { return }
                        self.awaitingStorageConfirmation = false
                        self.mutateCache { try $0.updatePreferences(preferences) }
                    }
                    guard impact.count > 0 else { apply(); return }
                    let alert = UIAlertController(title: "Reduce Cache Limit?", message: "This will remove \(impact.count) least recently opened cached archives. Original files will remain. You may need to select them again to read.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                        self?.awaitingStorageConfirmation = false
                        self?.refreshImportControls()
                    })
                    alert.addAction(UIAlertAction(title: "Update Limit", style: .destructive) { _ in apply() })
                    self.visiblePresenter.present(alert, animated: true)
                case .failure(let error):
                    self.awaitingStorageConfirmation = false
                    self.refreshImportControls()
                    self.showAlert(title: "Unable to Update Cache", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func openArchive() {
        guard !operationBusy else { return }
        let supportedArchiveTypes = [
            UTType.zip,
            UTType(filenameExtension: "cbz"),
            UTType(filenameExtension: "7z")
        ].compactMap { $0 }
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: supportedArchiveTypes)
        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = false
        library.searchController.isActive = false
        present(documentPicker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let selectedFileURL = urls.first, !operationBusy else { return }
        beginImportPresentation(filename: selectedFileURL.lastPathComponent)
        if selectedFileURL.pathExtension.lowercased() == "7z" {
            beginSevenZipImport(from: selectedFileURL)
            return
        }
        let stageCallback = importStageCallback()
        let compress = cachePreferences.compressExtractedImages
        performArchiveOperation({ service in
            let preparation = try service.prepareArchive(at: selectedFileURL, compressExtractedImages: compress, onStage: stageCallback)
            return (preparation, service.takePreparedSession())
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success((.cached(let images), let session)):
                self.presentSortedImages(images, session: session)
            case .success((.archive(let request), _)):
                if request.requiresPassword {
                    self.promptForArchivePassword(request: request)
                } else {
                    self.extractArchive(request, password: nil)
                }
            case .failure(let error):
                self.finishImportPresentation()
                self.showAlert(title: "Import Failed", message: error.localizedDescription)
            }
        }
    }

    private func extractArchive(_ request: ArchiveService.Request, password: String?) {
        let stageCallback = importStageCallback()
        performArchiveOperation({ service in
            let images = try service.extract(request, password: password, onStage: stageCallback)
            return (images, service.takePreparedSession())
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success((let images, let session)):
                self.presentSortedImages(images, session: session)
            case .failure(let error):
                if case ArchiveService.ImportError.zipExtractionFailed = error, password != nil {
                    self.promptForArchivePassword(request: request, retry: true)
                } else {
                    self.discardZIPRequest(request)
                    self.finishImportPresentation()
                    self.showAlert(title: "Import Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func presentSortedImages(_ images: [URL], session: ArchiveReaderSession?) {
        let criterion = preferencesStore.preferences.sortCriterion
        let order = preferencesStore.preferences.sortOrder
        let metadata = session?.pageMetadata ?? [:]
        if importID != nil { displayImportState(ImportPresentationState(stage: .preparingPages, filename: importFilename)) }
        performArchiveOperation({ _ in
            ImageFileSorter.sort(images, criterion: criterion, order: order, metadata: metadata)
        }) { [weak self] result in
            switch result {
            case .success(let sortedImages):
                guard let self else { session?.release(); return }
                self.presentImageViewer(with: sortedImages, session: session)
            case .failure(let error):
                self?.finishImportPresentation()
                self?.showAlert(title: "Import Failed", message: error.localizedDescription)
            }
        }
    }

    // ArchiveService state and all filesystem work are confined to this serial queue.
    // Only this main-queue completion may read or update UIKit objects.
    private func performArchiveOperation<Value>(
        _ operation: @escaping (ArchiveService) throws -> Value,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        guard cacheReady, !isImporting, !sevenZipImporter.isBusy, !isClearingCache else { return }
        isImporting = true
        refreshImportControls()
        let service = archiveService
        archiveQueue.async {
            let result = Result { try operation(service) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isImporting = false
                self.refreshImportControls()
                completion(result)
            }
        }
    }

    private func beginSevenZipImport(from source: URL) {
        if importID == nil { beginImportPresentation(filename: source.lastPathComponent) }
        guard cacheReady, !isImporting, !sevenZipImporter.isBusy, !isClearingCache else { return }
        // Reserve the UI before the main-actor task gets its first turn.
        isImporting = true
        refreshImportControls()
        let compress = cachePreferences.compressExtractedImages
        Task {
            isImporting = false
            await sevenZipImporter.beginImport(from: source, compressExtractedImages: compress)
            refreshImportControls()
        }
    }

    private func refreshImportControls() {
        let busy = operationBusy
        openButton?.isEnabled = !busy
        settingsButton?.isEnabled = !isImporting && !sevenZipImporter.isBusy
        library.update(archives: recentArchives, ready: cacheReady, busy: busy, error: cacheError)
        settingsController?.updateStorage(preferences: cachePreferences, usage: cacheUsage, isBusy: busy, archiveCount: recentArchives.count)
    }

    private func beginImportPresentation(filename: String) {
        importID = UUID()
        importFilename = filename
        displayImportState(ImportPresentationState(stage: .preparingSource, filename: filename))
    }

    private func importStageCallback() -> (ImportPresentationState) -> Void {
        let token = importID
        return { [weak self] state in
            DispatchQueue.main.async {
                guard let self, let token, self.importID == token else { return }
                if state.stage == .failed || state.stage == .completed { return }
                if state.stage == .waitingForPassword { self.removeImportProgress(); return }
                self.displayImportState(state)
            }
        }
    }

    private func updateArchiveImportUI(_ state: ArchiveImportCoordinator.State) {
        refreshImportControls()
        switch state {
        case .idle:
            finishImportPresentation()
        case .awaitingPassword(let error):
            removeImportProgress()
            promptForSevenZipPassword(after: error)
        case .completed(let images):
            presentSortedImages(images, session: sevenZipImporter.takePreparedSession())
        case .failed(let error):
            finishImportPresentation()
            showAlert(title: "Import Failed", message: error.localizedDescription)
        default:
            if let presentation = ImportPresentationState.from(coordinatorState: state, filename: importFilename) {
                displayImportState(presentation)
            }
        }
    }

    private func displayImportState(_ state: ImportPresentationState) {
        lastImportState = state
        if let overlay = importProgressView { overlay.update(state); return }
        guard delayedImportDisplay == nil else { return }
        let token = importID
        let generation = importDisplayGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, let token, self.importID == token, self.importDisplayGeneration == generation else { return }
            self.delayedImportDisplay = nil
            guard let state = self.lastImportState, self.viewIfLoaded?.window != nil else { return }
            let overlay = ArchiveImportProgressView()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.onCancel = { [weak self] in
                guard let self, self.sevenZipImporter.isBusy else { return }
                Task { await self.sevenZipImporter.cancel() }
            }
            self.view.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: self.view.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
            ])
            self.importProgressView = overlay
            overlay.update(state)
        }
        delayedImportDisplay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    private func removeImportProgress() {
        importDisplayGeneration += 1
        delayedImportDisplay?.cancel()
        delayedImportDisplay = nil
        lastImportState = nil
        importProgressView?.removeFromSuperview()
        importProgressView = nil
    }

    private func finishImportPresentation() {
        removeImportProgress()
        importID = nil
        refreshImportControls()
    }

    private func promptForSevenZipPassword(after error: ArchiveImportError) {
        let title: String
        let message: String
        let actionTitle: String
        switch error {
        case .passwordRequired:
            title = "Password Required"
            message = "Enter the password to open this archive."
            actionTitle = "Open"
        case .openFailed:
            title = "Unable to Open Archive"
            message = "The archive may require a password, or it may be damaged or unsupported. Enter its password to try again."
            actionTitle = "Try Password"
        default:
            title = "Unable to Extract Archive"
            message = "The password may be incorrect, or the archive may be damaged. You can try another password."
            actionTitle = "Try Again"
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField {
            $0.isSecureTextEntry = true
            $0.placeholder = "Archive password"
            $0.accessibilityIdentifier = "sevenZipPassword"
            $0.autocorrectionType = .no
            $0.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            guard let self else { return }
            self.archivePasswordAlert = nil
            Task { await self.sevenZipImporter.cancel() }
        })
        alert.addAction(UIAlertAction(title: actionTitle, style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            // Empty input and cancellation are distinct; never trim a password.
            let password = alert?.textFields?.first?.text ?? ""
            self.archivePasswordAlert = nil
            // Finish the alert transition before a fast retry can present another result.
            alert?.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                Task { await self.sevenZipImporter.submitPassword(password) }
            }
        })
        archivePasswordAlert = alert
        presentImportResult(alert) { [weak self, weak alert] in
            guard let self, let alert, self.archivePasswordAlert === alert,
                  case .awaitingPassword = self.sevenZipImporter.state else { return false }
            return true
        }
    }

    /// A small archive may finish before the document picker has dismissed.
    private func presentImportResult(_ controller: UIViewController,
                                     when isCurrent: @escaping () -> Bool = { true },
                                     onRejection: @escaping () -> Void = {}) {
        guard isCurrent(), viewIfLoaded?.window != nil else { onRejection(); return }
        if let picker = presentedViewController as? UIDocumentPickerViewController {
            picker.dismiss(animated: true) { [weak self] in
                guard let self, isCurrent(), self.viewIfLoaded?.window != nil,
                      self.presentedViewController == nil else { onRejection(); return }
                self.present(controller, animated: true)
            }
        } else if presentedViewController == nil {
            present(controller, animated: true)
        } else {
            onRejection()
        }
    }

    @objc private func cancelImportInBackground() {
        flushReadingProgress()
        guard sevenZipImporter.isBusy else { return }
        archivePasswordAlert?.dismiss(animated: false)
        archivePasswordAlert = nil
        if backgroundCleanupTask == .invalid {
            backgroundCleanupTask = UIApplication.shared.beginBackgroundTask(withName: "Archive cleanup") { [weak self] in
                // Stop claiming background time even if a provider copy has not returned yet.
                // Cancellation still owns the files until the worker drains.
                Task { @MainActor in self?.endArchiveCleanupBackgroundTask() }
            }
        }
        Task {
            await sevenZipImporter.cancel()
            endArchiveCleanupBackgroundTask()
        }
    }

    private func endArchiveCleanupBackgroundTask() {
        guard backgroundCleanupTask != .invalid else { return }
        let identifier = backgroundCleanupTask
        backgroundCleanupTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func promptForArchivePassword(request: ArchiveService.Request, retry: Bool = false) {
        removeImportProgress()
        let alert = UIAlertController(
            title: retry ? "Unable to Extract ZIP" : "Password Required",
            message: retry
                ? "The password may be incorrect or the archive may be damaged. You can try another password."
                : "This archive is encrypted. Enter the password to continue.",
            preferredStyle: .alert
        )
        alert.addTextField {
            $0.isSecureTextEntry = true
            $0.placeholder = "Archive password"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.discardZIPRequest(request)
            self?.finishImportPresentation()
        })
        alert.addAction(UIAlertAction(title: retry ? "Try Again" : "Open", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            // Spaces are valid password characters; preserve the exact input.
            let password = alert?.textFields?.first?.text ?? ""
            alert?.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                self.extractArchive(request, password: password)
            }
        })
        presentImportResult(alert)
    }

    private func presentImageViewer(with imageUrls: [URL], session: ArchiveReaderSession?) {
        finishImportPresentation()
        guard UIApplication.shared.applicationState == .active else {
            pendingReaderPresentation?.session?.release()
            pendingReaderPresentation = (imageUrls, session)
            refreshImportControls()
            return
        }
        guard !imageUrls.isEmpty, activeReaderSession == nil,
              viewIfLoaded?.window != nil,
              presentedViewController == nil || presentedViewController is UIDocumentPickerViewController else {
            session?.release()
            return
        }
        activeReaderSession = session
        let imageViewerVC = ImageViewerViewController()
        imageViewerVC.imageUrls = imageUrls
        imageViewerVC.pageMetadata = session?.pageMetadata ?? [:]
        imageViewerVC.previewURLs = session?.previewURLs ?? [:]
        if let session {
            imageViewerVC.retainImageWork = { session.retainForImageWork() }
        }
        imageViewerVC.currentIndex = session?.restoredIndex(in: imageUrls) ?? 0
        imageViewerVC.archiveTitle = session?.displayName ?? importFilename
        imageViewerVC.applyPreferences(preferencesStore.preferences)
        imageViewerVC.onSettingsRequested = { [weak self, weak imageViewerVC] in
            guard let imageViewerVC else { return }
            self?.showSettings(from: imageViewerVC)
        }
        activeReader = imageViewerVC
        imageViewerVC.onPositionChange = { [weak self, weak session] url, index in
            guard let self, let session else { return }
            self.scheduleReadingProgress(session: session, imageURL: url, index: index)
        }
        imageViewerVC.onFlushProgress = { [weak self] in self?.flushReadingProgress() }
        imageViewerVC.onClose = { [weak self, session] in
            guard let self else { session?.release(); return }
            self.flushReadingProgress()
            self.activeReaderSession = nil
            self.archiveQueue.async {
                session?.release()
                DispatchQueue.main.async { [weak self] in self?.refreshRecentArchives() }
            }
        }
        imageViewerVC.view.accessibilityIdentifier = "imageViewer"
        imageViewerVC.modalPresentationStyle = .fullScreen
        let presentReader = { [weak self, weak imageViewerVC] in
            guard let self, let imageViewerVC else { session?.release(); return }
            guard self.viewIfLoaded?.window != nil,
                  self.presentedViewController == nil || self.presentedViewController is UIDocumentPickerViewController else {
                self.activeReaderSession = nil
                session?.release()
                self.refreshRecentArchives()
                return
            }
            self.presentImportResult(imageViewerVC, onRejection: { [weak self] in
                self?.activeReaderSession = nil
                session?.release()
                self?.refreshRecentArchives()
            })
            self.refreshRecentArchives()
        }
        var notices: [String] = []
        if session?.isTemporary == true {
            notices.append("This archive exceeds your cache limit and will be removed when you close it.")
        }
        if let warning = session?.cleanupWarning { notices.append(warning) }
        if !notices.isEmpty {
            let notice = UIAlertController(title: session?.isTemporary == true ? "Temporary Archive" : "Cache Cleanup", message: notices.joined(separator: "\n\n"), preferredStyle: .alert)
            notice.addAction(UIAlertAction(title: "Continue", style: .default) { [weak notice, imageViewerVC] _ in
                // Retain the pending reader until the informational alert has finished dismissing.
                notice?.dismiss(animated: true) { [imageViewerVC] in
                    _ = imageViewerVC
                    presentReader()
                }
            })
            presentImportResult(notice, onRejection: { [weak self] in
                self?.activeReaderSession = nil
                session?.release()
            })
        } else {
            presentReader()
        }
    }

    private func openRecentArchive(_ archive: CachedArchiveSummary) {
        guard !operationBusy else { return }
        library.searchController.isActive = false
        guard archive.isAvailable else { presentUnavailableArchive(); return }
        let store = cacheStore
        performArchiveOperation({ _ in try store.acquire(id: archive.id) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let session): self.presentSortedImages(session.imageURLs, session: session)
            case .failure(let error):
                self.refreshRecentArchives()
                if case ArchiveCacheError.unavailable = error { self.presentUnavailableArchive() }
                else { self.showAlert(title: "Unable to Open Cache", message: error.localizedDescription) }
            }
        }
    }

    private func presentUnavailableArchive() {
        let alert = UIAlertController(title: "Cached Copy Unavailable", message: "Select the archive again to continue reading.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Select archive again", style: .default) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) { [weak self] in
                self?.openArchive()
            }
        })
        presentImportResult(alert)
    }

    @objc private func applicationWillEnterForeground() {
        refreshRecentArchives()
    }

    @objc private func applicationDidBecomeActive() {
        guard let pending = pendingReaderPresentation else { presentNextError(); return }
        pendingReaderPresentation = nil
        presentImageViewer(with: pending.images, session: pending.session)
        refreshImportControls()
        presentNextError()
    }

    private func refreshRecentArchives() {
        recentRefreshGeneration += 1
        let generation = recentRefreshGeneration
        let store = cacheStore
        archiveQueue.async {
            let result = Result {
                ArchiveImportWorkspace.prepare()
                return (try store.list(), try store.usage(), store.preferences)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.recentRefreshGeneration else { return }
                switch result {
                case .success((let archives, let usage, let preferences)):
                    self.recentArchives = archives
                    self.cachePreferences = preferences
                    self.cacheUsage = usage
                    self.cacheReady = true
                    self.cacheError = nil
                case .failure(let error):
                    self.cacheReady = false
                    self.cacheError = error.localizedDescription
                }
                self.refreshImportControls()
                #if DEBUG && targetEnvironment(simulator)
                self.importUITestFixturesIfNeeded()
                #endif
            }
        }
    }

    private func mutateCache(_ operation: @escaping (ArchiveCacheStore) throws -> Void) {
        guard cacheReady, !isImporting, !sevenZipImporter.isBusy, !isClearingCache else { return }
        isClearingCache = true
        refreshImportControls()
        let store = cacheStore
        archiveQueue.async {
            let result = Result { try operation(store) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isClearingCache = false
                if case .failure(let error) = result {
                    self.showAlert(title: "Unable to Update Cache", message: error.localizedDescription)
                }
                self.refreshRecentArchives()
                self.refreshImportControls()
            }
        }
    }

    private func discardZIPRequest(_ request: ArchiveService.Request) {
        let service = archiveService
        archiveQueue.async { try? service.discard(request) }
    }

    // Debounce navigation on the main actor, then serialize persistence before release.
    private func scheduleReadingProgress(session: ArchiveReaderSession, imageURL: URL, index: Int) {
        pendingProgress = (session.archiveID, session.relativePath(for: imageURL), index)
        pendingProgressWrite?.cancel()
        let write = DispatchWorkItem { [weak self] in self?.flushReadingProgress() }
        pendingProgressWrite = write
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: write)
    }

    private func flushReadingProgress() {
        pendingProgressWrite?.cancel()
        pendingProgressWrite = nil
        guard let progress = pendingProgress else { return }
        pendingProgress = nil
        let store = cacheStore
        archiveQueue.async {
            do {
                try store.saveProgress(archiveID: progress.archiveID, relativePath: progress.relativePath, index: progress.index)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.showAlert(title: "Unable to Save Position", message: error.localizedDescription)
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        pendingErrors.append((title, message))
        presentNextError()
    }

    private func presentNextError() {
        guard !pendingErrors.isEmpty, !isShowingError, !errorPresentationScheduled,
              UIApplication.shared.applicationState == .active, viewIfLoaded?.window != nil else { return }
        let presenter = visiblePresenter
        if let picker = presenter as? UIDocumentPickerViewController {
            errorPresentationScheduled = true
            picker.dismiss(animated: true) { [weak self] in
                self?.errorPresentationScheduled = false
                self?.presentNextError()
            }
            return
        }
        // Keep errors queued while password/confirmation alerts or their transitions finish.
        guard !(presenter is UIAlertController), !presenter.isBeingDismissed,
              !presenter.isBeingPresented, presenter.transitionCoordinator == nil else {
            errorPresentationScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                self?.errorPresentationScheduled = false
                self?.presentNextError()
            }
            return
        }
        let (title, message) = pendingErrors.removeFirst()
        isShowingError = true
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) {
                self?.isShowingError = false
                self?.presentNextError()
            }
        })
        presenter.present(alert, animated: true)
    }
}
