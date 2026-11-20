import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import ZipImageViewer

@MainActor
final class NativeAppServiceTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var service: NativeAppService!
    private var store: ArchiveCacheStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "NativeAppServiceTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        store = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
            supportDirectory: root.appendingPathComponent("support"), defaults: defaults)
        service = NativeAppService(cacheStore: store, preferencesStore: ReaderPreferencesStore(defaults: defaults),
                                   inboxDirectory: root.appendingPathComponent("Documents/Inbox"))
    }

    override func tearDownWithError() throws {
        service = nil
        _ = try? store.list()
        store = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testNativeRootPreservesControllerBasedStatusBarOwnership() {
        let root = ReactRootViewController()
        root.loadViewIfNeeded()
        root.overrideUserInterfaceStyle = .dark
        XCTAssertEqual(root.preferredStatusBarStyle, .lightContent)
        root.overrideUserInterfaceStyle = .light
        XCTAssertEqual(root.preferredStatusBarStyle, .darkContent)
        XCTAssertFalse(root.prefersStatusBarHidden)
        XCTAssertTrue(ImageViewerViewController().prefersStatusBarHidden)
    }

    func testRepeatedBootstrapKeepsTheSameOwnerAndMonotonicSnapshot() async throws {
        let first = try await snapshot()
        let second = try await snapshot()
        XCTAssertTrue(service.cacheStore === store)
        XCTAssertEqual(first["protocolVersion"] as? Int, 1)
        XCTAssertEqual(second["ready"] as? Bool, true)
        let firstRevision = (first["revision"] as? Int) ?? 0
        let secondRevision = (second["revision"] as? Int) ?? -1
        XCTAssertGreaterThanOrEqual(secondRevision, firstRevision)
        XCTAssertTrue(second["reader"] is NSNull)
    }

    func testStalePasswordAndUnknownCommandsNeverStartAnImport() async throws {
        _ = try await snapshot()
        for command in [#"{"type":"submitPassword","operationId":"expired","password":"secret"}"#,
                        #"{"type":"cancelImport","operationId":"expired"}"#,
                        #"{"type":"unknown"}"#] {
            do { _ = try await dispatch(command); XCTFail("Expected rejection") }
            catch { XCTAssertNotNil(error as NSError) }
        }
        let value = try await snapshot()
        XCTAssertTrue(value["import"] is NSNull)
        XCTAssertEqual((value["archives"] as? [Any])?.count, 0)
    }

    func testPreferencesUseExistingNativeStorageAndRejectInvalidRanges() async throws {
        _ = try await snapshot()
        let raw: [String: Any] = ["showRotationButtons": true, "showSlider": false, "showCount": true, "centerTap": false, "doubleTapZoom": false,
            "reversed": true, "animate": true, "tapRatio": 0.7, "sortCriterion": "created",
            "descending": true, "thumbnailSize": 0.5]
        let data = try JSONSerialization.data(withJSONObject: ["type": "updatePreferences", "preferences": raw])
        _ = try await dispatch(String(decoding: data, as: UTF8.self))
        let restored = ReaderPreferencesStore(defaults: defaults).preferences
        XCTAssertTrue(restored.showRotationButtons)
        XCTAssertFalse(restored.showPageSlider)
        XCTAssertFalse(restored.enableDoubleTapZoom)
        XCTAssertEqual(restored.sortCriterion, .createdDate)
        XCTAssertEqual(restored.previousPageTapWidthRatio, 0.7)
        var invalid = raw; invalid["tapRatio"] = 2.0
        XCTAssertThrowsError(try NativeAppService.decodePreferences(invalid))
    }

    func testPickerWaitsForPresentationHandshakeAndKeepsItsReservation() async throws {
        let presenter = PickerPresentationProbe()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = presenter
        window.isHidden = false
        defer { window.isHidden = true }
        presenter.blockingModal = UIViewController()
        service.attach(presenter: presenter)
        _ = try await snapshot()

        // Models Details -> Select archive again: UIKit still owns the RN modal.
        _ = try await dispatch(#"{"type":"pickArchive"}"#)
        XCTAssertTrue(presenter.presentations.isEmpty)
        do { _ = try await dispatch(#"{"type":"pickArchive"}"#); XCTFail("The pending picker must reserve the operation") }
        catch { }

        presenter.blockingModal = nil
        _ = try await dispatch(#"{"type":"presentationReady"}"#)
        XCTAssertEqual(presenter.presentations.count, 1)
        XCTAssertTrue(presenter.presentations.first is UIDocumentPickerViewController)
        _ = try await dispatch(#"{"type":"presentationReady"}"#)
        XCTAssertEqual(presenter.presentations.count, 1, "Repeated acknowledgments must not duplicate a picker")
        do { _ = try await dispatch(#"{"type":"clearArchives"}"#); XCTFail("The displayed picker must reserve the operation") }
        catch { }
    }

    func testReaderNumbersRejectCoercionAndUnsafeSequences() {
        XCTAssertNil(NativeAppService.readerInteger(NSNumber(value: true)))
        XCTAssertNil(NativeAppService.readerInteger(NSNumber(value: 1.5)))
        XCTAssertNil(NativeAppService.readerInteger("2"))
        XCTAssertNil(NativeAppService.readerInteger(NSNumber(value: -1)))
        XCTAssertNil(NativeAppService.readerInteger(NSNumber(value: 9_007_199_254_740_992 as Int64)))
        XCTAssertEqual(NativeAppService.readerInteger(NSNumber(value: 100)), 100)
    }

    func testQuotaTokensAreSingleUse() async throws {
        _ = try await snapshot()
        let preview = try await dispatch(#"{"type":"previewCacheLimits","limits":{"maximumBytes":1000000000,"maximumArchiveCount":5}}"#)
        let token = try XCTUnwrap((preview["cachePreview"] as? [String: Any])?["token"] as? String)
        _ = try await dispatch("{\"type\":\"applyCachePreview\",\"token\":\"\(token)\"}")
        XCTAssertEqual(store.preferences.maximumArchiveCount, 5)
        do { _ = try await dispatch("{\"type\":\"applyCachePreview\",\"token\":\"\(token)\"}"); XCTFail("Expected stale token rejection") }
        catch { }
    }

    func testFilesDocumentTypesResolveSupportedExtensions() throws {
        let documents = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let identifiers = documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        let handlers = identifiers.compactMap { UTType($0) }
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool, true)
        XCTAssertEqual(documents.first?["CFBundleTypeRole"] as? String, "Viewer")
        for ext in ["zip", "cbz", "7z"] {
            // Other apps may register additional identifiers for these extensions.
            let types = UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: .data)
            XCTAssertFalse(types.isEmpty)
            XCTAssertTrue(types.contains { type in handlers.contains { type.conforms(to: $0) } },
                          "Missing document registration for \(ext): \(types)")
        }
    }

    func testExternalInboxCopiesAreRemovedButInPlaceAndOutsideSourcesArePreserved() async throws {
        let window = attachBlockedPresenter()
        defer { window.isHidden = true }
        _ = try await snapshot()
        let owned = try inboxCopy(of: externalZIP("owned.zip"))
        let inPlace = try inboxCopy(of: externalZIP("in-place.cbz"))
        let outside = try externalZIP("outside.zip")
        for (source, openInPlace, removed) in [(owned, false, true), (inPlace, true, false), (outside, false, false)] {
            service.openExternalArchive(source, openInPlace: openInPlace)
            _ = try await waitForState { $0["busy"] as? Bool == false &&
                ($0["reader"] as? [String: Any])?["title"] as? String == source.lastPathComponent }
            XCTAssertEqual(FileManager.default.fileExists(atPath: source.path), !removed)
            _ = try await dispatch(#"{"type":"closeReader"}"#)
        }
        XCTAssertEqual(try store.list().count, 3)
    }

    func testRejectedAndFailedInboxCopiesAreRemovedWithoutFollowingSymlinks() async throws {
        let window = attachBlockedPresenter()
        defer { window.isHidden = true }
        _ = try await snapshot()
        let unsupported = try inboxCopy(of: externalZIP("unsupported.rar"))
        let damaged = try inboxCopy(of: externalZIP("damaged.zip"))
        try Data("Not an archive".utf8).write(to: damaged)
        for source in [unsupported, damaged] {
            service.openExternalArchive(source, openInPlace: false)
            let state = try await waitForState { $0["error"] is [String: Any] && $0["busy"] as? Bool == false }
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            let id = try XCTUnwrap((state["error"] as? [String: Any])?["id"] as? String)
            _ = try await dispatch("{\"type\":\"dismissError\",\"id\":\"\(id)\"}")
        }
        let original = try externalZIP("original.zip")
        let bytes = try Data(contentsOf: original)
        let link = unsupported.deletingLastPathComponent().appendingPathComponent("link.rar")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        service.openExternalArchive(link, openInPlace: false)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), original.path)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testBusyInboxDeliveryPreservesActiveCopyAndCancellationRemovesIt() async throws {
        let window = attachBlockedPresenter()
        defer { window.isHidden = true }
        _ = try await snapshot()
        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(bundle.url(forResource: "headers-lzma-solid", withExtension: "7z", subdirectory: "SevenZip")
            ?? bundle.url(forResource: "headers-lzma-solid", withExtension: "7z"))
        let source = try inboxCopy(of: fixture)
        service.openExternalArchive(source, openInPlace: false)
        let waiting = try await waitForState { ($0["import"] as? [String: Any])?["passwordRequired"] as? Bool == true }
        let operation = try XCTUnwrap((waiting["import"] as? [String: Any])?["id"] as? String)
        service.openExternalArchive(source, openInPlace: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let rejected = try inboxCopy(of: externalZIP("busy-copy.zip"))
        service.openExternalArchive(rejected, openInPlace: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        _ = try await dispatch("{\"type\":\"cancelImport\",\"operationId\":\"\(operation)\"}")
        _ = try await waitForState { $0["busy"] as? Bool == false }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
    }

    func testMultipleExternalURLsOpenFirstSupportedArchiveWithoutBusyErrors() async throws {
        let window = attachBlockedPresenter()
        defer { window.isHidden = true }
        _ = try await snapshot()
        let unsupported = try inboxCopy(of: externalZIP("a.rar"))
        let first = try inboxCopy(of: externalZIP("b.zip"))
        let ignored = try inboxCopy(of: externalZIP("c.cbz"))
        service.openExternalArchives([(url: unsupported, openInPlace: false), (url: first, openInPlace: false),
                                      (url: first, openInPlace: false), (url: ignored, openInPlace: false)])
        let opened = try await waitForState { $0["busy"] as? Bool == false && $0["reader"] is [String: Any] }
        XCTAssertEqual((opened["reader"] as? [String: Any])?["title"] as? String, "b.zip")
        XCTAssertTrue(opened["error"] is NSNull)
        for source in [unsupported, first, ignored] { XCTAssertFalse(FileManager.default.fileExists(atPath: source.path)) }
        XCTAssertEqual(try store.list().count, 1)
        _ = try await dispatch(#"{"type":"closeReader"}"#)
    }

    func testFailedExternalBootstrapReleasesReservationAndCanRetry() async throws {
        let source = try externalZIP("retry.zip")
        let cache = root.appendingPathComponent("cache")
        try Data("Blocks directory creation".utf8).write(to: cache)
        service.openExternalArchive(source)
        let failed = try await waitForState { $0["error"] is [String: Any] && $0["busy"] as? Bool == false }
        XCTAssertEqual(failed["ready"] as? Bool, false)
        try FileManager.default.removeItem(at: cache)
        let window = attachBlockedPresenter()
        defer { window.isHidden = true }
        _ = try await snapshot()
        service.openExternalArchive(source)
        _ = try await waitForState { $0["reader"] is [String: Any] }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        _ = try await dispatch(#"{"type":"closeReader"}"#)
    }

    func testExternalArchiveClosesSessionWhoseControllerWasNeverPresented() async throws {
        let presenter = PickerPresentationProbe()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = presenter
        window.isHidden = false
        defer { window.isHidden = true }
        service.attach(presenter: presenter)
        _ = try await snapshot()
        service.openExternalArchive(try externalZIP("unpresented.zip"))
        _ = try await waitForState { $0["busy"] as? Bool == false && $0["reader"] is [String: Any] }
        XCTAssertEqual(presenter.presentations.count, 1)
        XCTAssertNil(presenter.presentations.first?.presentingViewController)
        service.openExternalArchive(try externalZIP("replacement.zip"))
        _ = try await waitForState { $0["busy"] as? Bool == false &&
            ($0["reader"] as? [String: Any])?["title"] as? String == "replacement.zip" }
        XCTAssertEqual(presenter.presentations.count, 2)
        _ = try await dispatch(#"{"type":"closeReader"}"#)
    }

    private func inboxCopy(of source: URL) throws -> URL {
        let inbox = root.appendingPathComponent("Documents/Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let copy = inbox.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    func testExternalArchiveBeforeBootstrapWaitsForPresenterAndOpensWithoutChangingSource() async throws {
        let source = try externalZIP("Files 空白.CBZ")
        let original = try Data(contentsOf: source)
        service.openExternalArchive(source)
        let initial = try await snapshot()
        XCTAssertEqual(initial["busy"] as? Bool, true)
        XCTAssertTrue(initial["import"] is NSNull)
        let window = attachBlockedPresenter()
        defer { window.isHidden = true }
        let opened = try await waitForState { $0["reader"] is [String: Any] }
        XCTAssertEqual((opened["reader"] as? [String: Any])?["title"] as? String, source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try store.list().count, 1)
        _ = try await dispatch(#"{"type":"closeReader"}"#)
    }

    func testExternalArchiveReplacesPendingReaderAndReusesCachedArchive() async throws {
        let window = attachBlockedPresenter()
        defer { window.isHidden = true }
        _ = try await snapshot()
        let first = try externalZIP("first.zip")
        service.openExternalArchive(first)
        let opened = try await waitForState { ($0["reader"] as? [String: Any])?["title"] as? String == "first.zip" }
        let id = (opened["reader"] as? [String: Any])?["archiveId"] as? String
        service.openExternalArchive(first)
        _ = try await waitForState { value in
            value["import"] is NSNull && value["busy"] as? Bool == false &&
                (value["reader"] as? [String: Any])?["archiveId"] as? String == id
        }
        XCTAssertEqual(try store.list().count, 1)
        let second = try externalZIP("second.cbz")
        service.openExternalArchive(second)
        _ = try await waitForState { ($0["reader"] as? [String: Any])?["title"] as? String == "second.cbz" }
        XCTAssertEqual(try store.list().count, 2)
        _ = try await dispatch(#"{"type":"closeReader"}"#)
    }

    func testExternalEncryptedSevenZipUsesExistingPasswordAndCancellationFlow() async throws {
        let window = attachBlockedPresenter()
        defer { window.isHidden = true }
        _ = try await snapshot()
        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(bundle.url(forResource: "headers-lzma-solid", withExtension: "7z", subdirectory: "SevenZip")
            ?? bundle.url(forResource: "headers-lzma-solid", withExtension: "7z"))
        let original = try Data(contentsOf: fixture)
        service.openExternalArchive(fixture)
        let waiting = try await waitForState { ($0["import"] as? [String: Any])?["passwordRequired"] as? Bool == true }
        let operation = try XCTUnwrap((waiting["import"] as? [String: Any])?["id"] as? String)
        service.openExternalArchive(try externalZIP("blocked.zip"))
        let blocked = try await snapshot()
        XCTAssertEqual((blocked["import"] as? [String: Any])?["id"] as? String, operation)
        XCTAssertEqual((blocked["import"] as? [String: Any])?["passwordRequired"] as? Bool, true)
        let error = try XCTUnwrap((blocked["error"] as? [String: Any])?["id"] as? String)
        _ = try await dispatch("{\"type\":\"dismissError\",\"id\":\"\(error)\"}")
        _ = try await dispatch("{\"type\":\"cancelImport\",\"operationId\":\"\(operation)\"}")
        _ = try await waitForState { $0["import"] is NSNull }
        XCTAssertTrue(try store.list().isEmpty)
        service.openExternalArchive(fixture)
        let retry = try await waitForState { ($0["import"] as? [String: Any])?["passwordRequired"] as? Bool == true }
        let retryOperation = try XCTUnwrap((retry["import"] as? [String: Any])?["id"] as? String)
        _ = try await dispatch("{\"type\":\"submitPassword\",\"operationId\":\"\(retryOperation)\",\"password\":\"test-password\"}")
        _ = try await waitForState { $0["reader"] is [String: Any] }
        XCTAssertEqual(try Data(contentsOf: fixture), original)
        _ = try await dispatch(#"{"type":"closeReader"}"#)
    }

    func testExternalUnsupportedAndUnavailableFilesReportErrors() async throws {
        let window = attachBlockedPresenter()
        defer { window.isHidden = true }
        _ = try await snapshot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let damaged = root.appendingPathComponent("damaged.zip")
        try Data("Not an archive".utf8).write(to: damaged)
        for source in [URL(string: "https://example.com/archive.zip")!, root.appendingPathComponent("archive.rar"),
                       root.appendingPathComponent("missing.zip"), damaged] {
            service.openExternalArchive(source)
            let failed = try await waitForState { $0["error"] is [String: Any] && $0["import"] is NSNull }
            let error = try XCTUnwrap((failed["error"] as? [String: Any])?["id"] as? String)
            _ = try await dispatch("{\"type\":\"dismissError\",\"id\":\"\(error)\"}")
            XCTAssertTrue(try store.list().isEmpty)
        }
    }

    func testExternalArchiveDuringPickerReportsBusyWithoutDiscardingPicker() async throws {
        let window = attachBlockedPresenter()
        defer { window.isHidden = true }
        _ = try await snapshot()
        _ = try await dispatch(#"{"type":"pickArchive"}"#)
        service.openExternalArchive(try externalZIP("busy.zip"))
        let state = try await snapshot()
        XCTAssertNotNil((state["error"] as? [String: Any])?["message"])
        XCTAssertEqual(state["busy"] as? Bool, true)
        XCTAssertTrue(state["import"] is NSNull)
    }

    private func externalZIP(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent(name)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        try ZipExtractorTests.fixture([.init(name: name + ".png", bytes: image)]).write(to: source)
        return source
    }

    private func attachBlockedPresenter() -> UIWindow {
        let presenter = PickerPresentationProbe()
        presenter.blockingModal = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = presenter
        window.isHidden = false
        service.attach(presenter: presenter)
        return window
    }

    private func waitForState(_ predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let state = try await snapshot()
            if predicate(state) { return state }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for native archive state: \(service.snapshot())")
        throw ServiceTestError.timedOut
    }

    private enum ServiceTestError: Error { case timedOut }

    private func snapshot() async throws -> [String: Any] {
        let value: String = try await withCheckedThrowingContinuation { continuation in
            service.getSnapshot { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value!) }
            }
        }
        return try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
    }
    private func dispatch(_ command: String) async throws -> [String: Any] {
        let value: String = try await withCheckedThrowingContinuation { continuation in
            service.dispatch(command) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value!) }
            }
        }
        return try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
    }
}

@MainActor
private final class PickerPresentationProbe: UIViewController {
    var blockingModal: UIViewController?
    var presentations: [UIViewController] = []
    override var presentedViewController: UIViewController? { blockingModal }
    override func present(_ viewControllerToPresent: UIViewController, animated: Bool,
                          completion: (() -> Void)? = nil) {
        presentations.append(viewControllerToPresent)
        completion?()
    }
}
