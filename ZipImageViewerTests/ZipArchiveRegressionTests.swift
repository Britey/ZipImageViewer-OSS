import CryptoKit
import Foundation
import XCTest
import ZipArchive
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ZipImageViewer

/// Existing ZIP/CBZ backend remains compatible after the 7z dependency replacement.
final class ZipArchiveRegressionTests: XCTestCase {
    func testRealZIPCompressionReopensWithoutRewritingAndOffImportKeepsOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inputs = root.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ZIPCompression-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let originals = try realisticImagePair()
        let inputURLs = try originals.map { name, data in
            let url = inputs.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        let archive = root.appendingPathComponent("pages.zip")
        XCTAssertTrue(SSZipArchive.createZipFile(atPath: archive.path, withFilesAtPaths: inputURLs.map(\.path)))
        let cache = root.appendingPathComponent("cache")
        let support = root.appendingPathComponent("support")
        let store = ArchiveCacheStore(cacheDirectory: cache, supportDirectory: support, defaults: defaults)
        var preferences = store.preferences
        preferences.compressExtractedImages = true
        try store.updatePreferences(preferences)
        let service = ArchiveService(workDirectory: root.appendingPathComponent("imports"), cacheStore: store)
        guard case .archive(let request) = try service.prepareArchive(at: archive) else {
            return XCTFail("Expected new ZIP extraction")
        }
        _ = try service.extract(request, password: nil)
        let session = try XCTUnwrap(service.takePreparedSession())
        let id = session.archiveID
        XCTAssertEqual(Set(session.imageURLs.compactMap(session.relativePath)), Set(originals.keys))
        XCTAssertTrue(session.imageURLs.contains { $0.pathExtension == "jxl" })
        XCTAssertEqual(session.previewURLs.count, originals.count)
        let sorted = ImageFileSorter.sort(session.imageURLs, criterion: .filename, order: .ascending,
                                          metadata: session.pageMetadata)
        XCTAssertEqual(sorted.compactMap(session.relativePath), ["page2.png", "page10.jpg"])
        var storedBytes: [String: Data] = [:]
        for url in session.imageURLs {
            storedBytes[try XCTUnwrap(session.relativePath(for: url))] = try Data(contentsOf: url)
            XCTAssertNotNil(CGImageSourceCreateWithURL(url as CFURL, nil))
        }
        try store.saveProgress(archiveID: id, relativePath: "page10.jpg", index: 1)
        session.release()

        preferences.compressExtractedImages = false
        try store.updatePreferences(preferences)
        guard case .cached = try service.prepareArchive(at: archive) else {
            return XCTFail("Changing compression must reuse an existing cache")
        }
        let reused = try XCTUnwrap(service.takePreparedSession())
        XCTAssertEqual(reused.archiveID, id)
        for url in reused.imageURLs {
            XCTAssertEqual(try Data(contentsOf: url), storedBytes[try XCTUnwrap(reused.relativePath(for: url))])
        }
        reused.release()

        let relaunched = ArchiveCacheStore(cacheDirectory: cache, supportDirectory: support, defaults: defaults)
        let reopened = try relaunched.acquire(id: id)
        XCTAssertEqual(reopened.position.relativePath, "page10.jpg")
        let reopenedSorted = ImageFileSorter.sort(reopened.imageURLs, criterion: .filename, order: .ascending,
                                                  metadata: reopened.pageMetadata)
        XCTAssertEqual(reopenedSorted.compactMap(reopened.relativePath), ["page2.png", "page10.jpg"])
        XCTAssertEqual(reopened.restoredIndex(in: reopenedSorted), 1)
        reopened.release()

        let offStore = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("off-cache"),
                                         supportDirectory: root.appendingPathComponent("off-support"), defaults: defaults)
        XCTAssertFalse(offStore.preferences.compressExtractedImages)
        let offService = ArchiveService(workDirectory: root.appendingPathComponent("off-imports"), cacheStore: offStore)
        guard case .archive(let offRequest) = try offService.prepareArchive(at: archive) else {
            return XCTFail("Expected extraction into a fresh cache with compression off")
        }
        _ = try offService.extract(offRequest, password: nil)
        let offSession = try XCTUnwrap(offService.takePreparedSession())
        defer { offSession.release() }
        XCTAssertEqual(offSession.previewURLs.count, originals.count)
        for url in offSession.imageURLs {
            let identity = try XCTUnwrap(offSession.relativePath(for: url))
            XCTAssertEqual(url.pathExtension, (identity as NSString).pathExtension)
            XCTAssertEqual(try Data(contentsOf: url), originals[identity])
        }
    }

    private func realisticImagePair() throws -> [String: Data] {
        let width = 1024, height = 768
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4,
                                            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let pixels = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        var random: UInt32 = 42
        for y in 0..<height {
            for x in 0..<width {
                random = random &* 1664525 &+ 1013904223
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(clamping: x / 5 + Int(random >> 28))
                pixels[offset + 1] = UInt8(clamping: y / 4 + Int(random >> 28))
                pixels[offset + 2] = UInt8(clamping: (x + y) / 9 + Int(random >> 28))
                pixels[offset + 3] = 255
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        var images: [String: Data] = [:]
        for (name, type) in [("page2.png", UTType.png), ("page10.jpg", UTType.jpeg)] {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            images[name] = data as Data
        }
        return images
    }

    private struct Manifest: Decodable {
        struct Image: Decodable { let sha256: String }
        let expected_images: [String: Image]
    }

    private func fixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: ZipArchiveRegressionTests.self)
        for directory in ["Fixtures/SevenZip", "SevenZip", "Fixtures", ""] {
            if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: directory) { return url }
        }
        XCTFail("Missing fixture \(name)")
        throw CocoaError(.fileNoSuchFile)
    }

    func testStandardAndAESEncryptedZIPAndCBZ() throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixture("manifest.json")))
        for suffix in ["zip", "cbz"] {
            for encrypted in [false, true] {
                let archive = try fixture((encrypted ? "encrypted" : "plain") + "." + suffix)
                XCTAssertEqual(SSZipArchive.isFilePasswordProtected(atPath: archive.path), encrypted)
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: destination) }
                try SSZipArchive.unzipFile(atPath: archive.path, toDestination: destination.path,
                                          overwrite: true, password: encrypted ? "test-password" : nil)
                for (name, image) in manifest.expected_images {
                    let data = try Data(contentsOf: destination.appendingPathComponent(name))
                    XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), image.sha256)
                }
            }
        }
    }

    @MainActor
    func testProductionImportersSharePersistentZIPCBZAndSevenZipCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("retained")
        let support = root.appendingPathComponent("catalog")
        var archiveIDs: [UUID] = []
        do {
            let store = ArchiveCacheStore(cacheDirectory: cache, supportDirectory: support)
            let zip = ArchiveService(workDirectory: root.appendingPathComponent("zip-work"), cacheStore: store)
            for name in ["plain.zip", "encrypted.cbz"] {
                guard case .archive(let request) = try zip.prepareArchive(at: fixture(name)) else {
                    return XCTFail("Expected fixture extraction")
                }
                let images = try zip.extract(request, password: name.hasPrefix("encrypted") ? "test-password" : nil)
                XCTAssertFalse(images.isEmpty)
                let session = try XCTUnwrap(zip.takePreparedSession())
                archiveIDs.append(session.archiveID)
                session.release()
            }
            let sevenZip = ArchiveImportCoordinator(rootDirectory: root.appendingPathComponent("7z-work"), cacheStore: store)
            await sevenZip.beginImport(from: try fixture("plain-lzma-solid.7z"))
            guard case .completed(let images) = sevenZip.state else { return XCTFail("Expected native 7z extraction") }
            XCTAssertFalse(images.isEmpty)
            let session = try XCTUnwrap(sevenZip.takePreparedSession())
            archiveIDs.append(session.archiveID)
            session.release()
        }
        // Opening from the new store requires neither source access nor another password.
        let relaunched = ArchiveCacheStore(cacheDirectory: cache, supportDirectory: support)
        for id in archiveIDs {
            let session = try relaunched.acquire(id: id)
            XCTAssertTrue(session.imageURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertFalse(session.imageURLs.isEmpty)
            session.release()
        }
        XCTAssertEqual(Set(archiveIDs).count, 3)
    }

    func testWrongZIPPasswordFailsThenCorrectPasswordSucceeds() throws {
        let archive = try fixture("encrypted.zip")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        XCTAssertThrowsError(try SSZipArchive.unzipFile(atPath: archive.path, toDestination: destination.path,
                                                     overwrite: true, password: "wrong"))
        try SSZipArchive.unzipFile(atPath: archive.path, toDestination: destination.path,
                                  overwrite: true, password: "test-password")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("panel.png").path))
    }

    func testZIPStagesSupportCancellationAndCachedReopenSkipsExtraction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ArchiveService(workDirectory: root)
        var states: [ImportPresentationState] = []
        let cancellation = ArchiveCancellationToken()
        let source = try fixture("plain.zip")
        guard case .archive(let request) = try service.prepareArchive(at: source, cancellation: cancellation, onStage: { states.append($0) }) else {
            return XCTFail("Expected a new import")
        }
        _ = try service.extract(request, password: nil, cancellation: cancellation, onStage: { states.append($0) })
        var distinctStages: [ImportPresentationState.Stage] = []
        for state in states where distinctStages.last != state.stage { distinctStages.append(state.stage) }
        XCTAssertEqual(distinctStages, [.preparingSource, .copying, .opening, .extracting, .preparingPages,
                                        .preparingPreviews, .preparingPages, .completed])
        XCTAssertTrue(states.allSatisfy { $0.filename == "plain.zip" })
        XCTAssertTrue(states.filter { $0.stage != .completed }.allSatisfy(\.canCancel))
        XCTAssertEqual(states.last?.canCancel, false)
        XCTAssertTrue(states.filter { $0.stage != .preparingPreviews && $0.stage != .extracting }.allSatisfy { $0.progress == nil })
        let session = try XCTUnwrap(service.takePreparedSession())
        session.release()
        states.removeAll()
        guard case .cached = try service.prepareArchive(at: source, cancellation: cancellation, onStage: { states.append($0) }) else {
            return XCTFail("Expected a cached reopen")
        }
        XCTAssertEqual(states.map(\.stage), [.preparingSource, .completed])
        service.takePreparedSession()?.release()
    }

    func testZIPPasswordRetryKeepsSourceAndReportsPreparationStages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ArchiveService(workDirectory: root)
        var states: [ImportPresentationState] = []
        let cancellation = ArchiveCancellationToken()
        guard case .archive(let request) = try service.prepareArchive(at: fixture("encrypted.cbz"),
                cancellation: cancellation, onStage: { states.append($0) }) else { return XCTFail("Expected an encrypted import") }
        XCTAssertEqual(states.last?.stage, .waitingForPassword)
        XCTAssertThrowsError(try service.extract(request, password: "wrong", cancellation: cancellation, onStage: { states.append($0) }))
        XCTAssertEqual(states.last?.stage, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.url.path))
        XCTAssertFalse(try service.extract(request, password: "test-password", cancellation: cancellation, onStage: { states.append($0) }).isEmpty)
        XCTAssertEqual(states.last?.stage, .completed)
        XCTAssertTrue(states.filter { $0.stage != .completed && $0.stage != .failed }.allSatisfy(\.canCancel))
        service.takePreparedSession()?.release()
    }

    @MainActor
    func testNativeSevenZipImportFromAliasedWorkspaceCanBeReopened() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("workspace-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace)
        let store = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"),
                                      supportDirectory: root.appendingPathComponent("support"))
        let importer = ArchiveImportCoordinator(rootDirectory: alias.appendingPathComponent("imports"), cacheStore: store)
        await importer.beginImport(from: try fixture("plain-lzma-solid.7z"))
        guard case .completed(let images) = importer.state else {
            return XCTFail("Expected the native extractor's resolved paths to publish, got \(importer.state)")
        }
        let session = try XCTUnwrap(importer.takePreparedSession())
        let id = session.archiveID
        session.release()
        let reopened = try store.acquire(id: id)
        defer { reopened.release() }
        XCTAssertEqual(Set(reopened.imageURLs), Set(images))
        XCTAssertTrue(images.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
}
