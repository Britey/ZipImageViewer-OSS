import XCTest
import UIKit
@testable import ZipImageViewer

/// A real catalog write failure must reach the active shared reader.
@MainActor
final class ReaderProgressFailureTests: XCTestCase {
    func testReaderReportsProgressWriteFailureBeforeClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ReaderProgressFailureTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let imageRoot = root.appendingPathComponent("input")
        let support = root.appendingPathComponent("support")
        let manager = FileManager.default
        try manager.createDirectory(at: imageRoot, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? manager.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 48), format: format)
        let data = renderer.pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        }
        let files = ["01.png", "02.png"].map { imageRoot.appendingPathComponent($0) }
        for file in files { try data.write(to: file) }
        let store = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
            supportDirectory: support, defaults: defaults)
        let imported = try store.publish(images: files, imageRoot: imageRoot, displayName: "Probe.zip",
            sourceIdentity: "probe", signature: "probe", format: "zip")
        let archiveID = imported.archiveID; imported.release()
        _ = try store.list() // Serial queue barrier for release.
        let service = NativeAppService(cacheStore: store, preferencesStore: ReaderPreferencesStore(defaults: defaults))
        let presenter = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = presenter; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        service.attach(presenter: presenter)
        _ = try await bootstrap(service)
        _ = try await dispatch(service, "{\"type\":\"openArchive\",\"id\":\"\(archiveID.uuidString)\"}")
        var viewer: ImageViewerViewController?
        for _ in 0..<100 {
            if let opened = presenter.presentedViewController as? ImageViewerViewController,
               opened.isViewLoaded, !opened.isBeingPresented { viewer = opened; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let reader = try XCTUnwrap(viewer, "The native service must present its reader")
        XCTAssertTrue(try decoded(service.snapshot())["error"] is NSNull)

        // A directory at the catalog filename forces JSON Data.write(.atomic)
        // to fail, modeling a real storage-write failure without filling the disk.
        let catalog = support.appendingPathComponent("recent-archives.json")
        try manager.removeItem(at: catalog)
        try manager.createDirectory(at: catalog, withIntermediateDirectories: false)
        reader.navigate(to: 1)
        try await Task.sleep(for: .milliseconds(1000)) // Native progress debounce + worker + main delivery.
        let active = try decoded(service.snapshot())
        print("READER_ACTIVE=\(service.snapshot())")
        XCTAssertNotNil(active["reader"] as? [String: Any])
        XCTAssertNotNil(active["error"] as? [String: Any],
            "An active reader must report that its reading position could not be saved")
        XCTAssertEqual((active["error"] as? [String: Any])?["title"] as? String, "Unable to Save Position")
        let activeAttachment = XCTAttachment(string: service.snapshot())
        activeAttachment.name = "Error snapshot while native reader remains open"
        activeAttachment.lifetime = .keepAlways; add(activeAttachment)

        reader.closeFromHost()
        var closed: [String: Any] = [:]
        for _ in 0..<100 {
            closed = try decoded(service.snapshot())
            if closed["reader"] is NSNull, closed["error"] is [String: Any] { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        print("READER_CLOSED=\(service.snapshot())")
        XCTAssertTrue(closed["reader"] is NSNull)
        XCTAssertNotNil(closed["error"] as? [String: Any], "The same queued failure becomes visible after close")
        let closedAttachment = XCTAttachment(string: service.snapshot())
        closedAttachment.name = "Queued error finally appears after reader closes"
        closedAttachment.lifetime = .keepAlways; add(closedAttachment)
    }

    private func decoded(_ value: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }
    private func bootstrap(_ service: NativeAppService) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            service.getSnapshot { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value!) }
            }
        }
    }
    private func dispatch(_ service: NativeAppService, _ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            service.dispatch(command) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value!) }
            }
        }
    }
}
