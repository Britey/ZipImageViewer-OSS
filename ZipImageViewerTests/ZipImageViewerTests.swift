import Foundation
import Testing
import UIKit
@testable import ZipImageViewer

struct ZipImageViewerTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func filenameSortIsNaturalAndReversible() {
        let urls = ["10.jpg", "2.jpg", "1.jpg"].map { URL(fileURLWithPath: "/images/\($0)") }
        let ascending = ImageFileSorter.sort(urls, criterion: .filename, order: .ascending)
        #expect(ascending.map(\.lastPathComponent) == ["1.jpg", "2.jpg", "10.jpg"])
        #expect(ImageFileSorter.sort(urls, criterion: .filename, order: .descending) == Array(ascending.reversed()))
    }

    @Test(arguments: SortCriterion.allCases)
    func duplicateNamesAndMissingDatesHaveDeterministicOrder(criterion: SortCriterion) {
        let a = URL(fileURLWithPath: "/missing/a/1.jpg")
        let b = URL(fileURLWithPath: "/missing/b/1.jpg")
        for input in [[b, a, a], [a, b, a], [a, a, b]] {
            #expect(ImageFileSorter.sort(input, criterion: criterion, order: .ascending) == [a, a, b])
            #expect(ImageFileSorter.sort(input, criterion: criterion, order: .descending) == [b, a, a])
        }
    }

    @Test func modifiedDateSortUsesDatesBeforeNames() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let older = root.appendingPathComponent("10.jpg")
        let newer = root.appendingPathComponent("1.jpg")
        try Data([1]).write(to: older)
        try Data([2]).write(to: newer)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: newer.path)
        #expect(ImageFileSorter.sort([newer, older], criterion: .modifiedDate, order: .ascending) == [older, newer])
        #expect(ImageFileSorter.sort([older, newer], criterion: .modifiedDate, order: .descending) == [newer, older])
    }

    @Test func relativeArchivePathsStayRelative() throws {
        let root = URL(fileURLWithPath: "/cache/images", isDirectory: true)
        #expect(try ArchiveService.outputURL(forEntryName: "chapter/1.png", destinationRoot: root).path == "/cache/images/chapter/1.png")
        #expect(try ArchiveService.outputURL(forEntryName: "chapter\\1.png", destinationRoot: root).path == "/cache/images/chapter/1.png")
        #expect(try ArchiveService.outputURL(forEntryName: "./chapter//1.png", destinationRoot: root).path == "/cache/images/chapter/1.png")
    }

    @Test(arguments: ["../1.png", "chapter/../../1.png", "/1.png", "C:\\1.png", "\\\\server\\1.png", "bad\0.png", ".", ""])
    func unsafeArchivePathsAreRejected(name: String) {
        #expect(throws: ArchiveService.ImportError.self) {
            try ArchiveService.outputURL(forEntryName: name, destinationRoot: URL(fileURLWithPath: "/cache/images"))
        }
    }

    @Test func collectionSkipsDirectoriesHiddenFilesAndSymlinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.jpg"), withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("page.PNG"))
        try Data([1]).write(to: root.appendingPathComponent(".hidden.png"))
        try Data([1]).write(to: root.appendingPathComponent("readme.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.png").path,
                                                 withDestinationPath: root.appendingPathComponent("page.PNG").path)
        let images = try ArchiveService(workDirectory: root.appendingPathComponent("cache")).collectImageFiles(in: root)
        #expect(images.map(\.lastPathComponent) == ["page.PNG"])
    }

    @Test func purgedFilesAreNotAcceptedThroughCachedURLMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("page.jpg")
        try Data([1]).write(to: page)
        _ = try page.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        try FileManager.default.removeItem(at: page)
        #expect(!ArchiveService.isRegularImage(at: page))
    }

    @Test func successfulImportIsReusedUntilCacheIsCleared() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.cbz")
        try Self.imageZIP.write(to: source)
        let cache = root.appendingPathComponent("cache")
        let service = ArchiveService(workDirectory: cache)
        guard case .archive(let request) = try service.prepareArchive(at: source) else {
            Issue.record("First import must prepare an archive"); return
        }
        #expect(!request.requiresPassword)
        let images = try service.extract(request, password: nil)
        #expect(images.count == 1)
        #expect(try Data(contentsOf: images[0]) == Data("page-a".utf8))
        guard case .cached(let reused) = try service.prepareArchive(at: source) else {
            Issue.record("Unchanged archive must reuse extracted images"); return
        }
        #expect(reused == images)
        try service.clearCache()
        #expect(images.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: source.path))
        guard case .archive = try service.prepareArchive(at: source) else {
            Issue.record("Cleared cache must be rebuilt"); return
        }
    }

    @Test func changedBytesWithSameSizeAndTimestampInvalidateCache() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.zip")
        try Self.imageZIP.write(to: source)
        let timestamp = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let service = ArchiveService(workDirectory: root.appendingPathComponent("cache"))
        guard case .archive(let first) = try service.prepareArchive(at: source) else { Issue.record("Missing request"); return }
        _ = try service.extract(first, password: nil)
        #expect(Self.changedImageZIP.count == Self.imageZIP.count)
        try Self.changedImageZIP.write(to: source)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)
        guard case .archive(let second) = try service.prepareArchive(at: source) else {
            Issue.record("Same metadata must not hide changed bytes"); return
        }
        let images = try service.extract(second, password: nil)
        #expect(try Data(contentsOf: images[0]) == Data("page-b".utf8))
    }

    @Test func failedRebuildCannotPublishPartialCache() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.zip")
        try Self.imageZIP.write(to: source)
        let cache = root.appendingPathComponent("cache")
        let service = ArchiveService(workDirectory: cache)
        guard case .archive(let first) = try service.prepareArchive(at: source) else { Issue.record("Missing request"); return }
        let images = try service.extract(first, password: nil)
        try FileManager.default.removeItem(at: images[0])
        guard case .archive(let rebuild) = try service.prepareArchive(at: source) else { Issue.record("Missing rebuild"); return }
        try Data("not a zip".utf8).write(to: rebuild.url)
        #expect(throws: (any Error).self) { try service.extract(rebuild, password: nil) }
        // A damaged ZIP is not a password retry: its copied source and partial
        // staging output must both be removed before another import begins.
        #expect(!FileManager.default.fileExists(atPath: rebuild.directory.path))
        guard case .archive = try service.prepareArchive(at: source) else {
            Issue.record("Failed extraction must not become a cache hit"); return
        }
    }

    @Test func multipleZIPArchivesSurviveRelaunchAndFailedReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstSource = root.appendingPathComponent("first.zip")
        let secondSource = root.appendingPathComponent("second.cbz")
        try Self.imageZIP.write(to: firstSource)
        try Self.changedImageZIP.write(to: secondSource)
        let work = root.appendingPathComponent("cache")
        var firstImages: [URL] = []
        do {
            let service = ArchiveService(workDirectory: work)
            for source in [firstSource, secondSource] {
                guard case .archive(let request) = try service.prepareArchive(at: source) else {
                    Issue.record("Expected new archive"); return
                }
                let images = try service.extract(request, password: nil)
                if source == firstSource { firstImages = images }
            }
            #expect(firstImages.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            try Self.textZIP.write(to: firstSource)
            guard case .archive(let replacement) = try service.prepareArchive(at: firstSource) else {
                Issue.record("Changed source must prepare replacement"); return
            }
            #expect(throws: ArchiveService.ImportError.self) { try service.extract(replacement, password: nil) }
            #expect(firstImages.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }
        try Self.imageZIP.write(to: firstSource)
        let relaunched = ArchiveService(workDirectory: work)
        for source in [firstSource, secondSource] {
            guard case .cached(let images) = try relaunched.prepareArchive(at: source) else {
                Issue.record("Both completed archives must survive importer recreation"); return
            }
            #expect(images.count == 1)
        }
    }

    @Test func noImagesIsNotAPasswordFailure() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.zip")
        try Self.textZIP.write(to: source)
        let service = ArchiveService(workDirectory: root.appendingPathComponent("cache"))
        guard case .archive(let request) = try service.prepareArchive(at: source) else { Issue.record("Missing request"); return }
        do {
            _ = try service.extract(request, password: "correct password")
            Issue.record("Expected noImages")
        } catch ArchiveService.ImportError.noImages {
            // The extraction succeeded, so asking for another password is wrong.
        }
    }

    @MainActor @Test func corruptPageKeepsSliderAndPageNumberInSync() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("valid.png")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let data = renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        try data.write(to: valid)
        let viewer = ImageViewerViewController()
        viewer.imageUrls = [valid, root.appendingPathComponent("missing.png"), valid]
        viewer.enablePageTurnAnimation = false
        viewer.loadViewIfNeeded()
        func descendants(of view: UIView) -> [UIView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let controls = descendants(of: viewer.view)
        let slider = try #require(controls.compactMap { $0 as? UISlider }.first)
        let pageButton = try #require(controls.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "readerPageButton" })
        slider.value = 1
        slider.sendActions(for: .valueChanged)
        #expect(viewer.currentIndex == 1)
        let labels = viewer.view.subviews.compactMap { $0 as? UILabel }
        #expect(pageButton.accessibilityValue == "Current page 2 of 3")
        #expect(slider.accessibilityValue == "Page 2 of 3")
        for _ in 0..<100 where !labels.contains(where: { $0.text == "This image could not be opened." && !$0.isHidden }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(labels.contains { $0.text == "This image could not be opened." && !$0.isHidden })
        slider.value = 2
        slider.sendActions(for: .valueChanged)
        #expect(viewer.currentIndex == 2)
        #expect(pageButton.accessibilityValue == "Current page 3 of 3")
        #expect(slider.accessibilityValue == "Page 3 of 3")
        for _ in 0..<100 where viewer.displayedIndex != 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(labels.contains { $0.text == "This image could not be opened." && $0.isHidden })
    }

    // Tiny ZIP_STORED fixtures with fixed timestamps. Image bytes are deliberately
    // opaque: these cases exercise archive handling, not UIKit image decoding.
    private static let imageZIP = Data(base64Encoded: "UEsDBBQAAAAAAAAAIVDPP8DsBgAAAAYAAAANAAAAY2hhcHRlci8xLmpwZ3BhZ2UtYVBLAQIUAxQAAAAAAAAAIVDPP8DsBgAAAAYAAAANAAAAAAAAAAAAAACAAQAAAABjaGFwdGVyLzEuanBnUEsFBgAAAAABAAEAOwAAADEAAAAAAA==")!
    private static let changedImageZIP = Data(base64Encoded: "UEsDBBQAAAAAAAAAIVB1bsl1BgAAAAYAAAANAAAAY2hhcHRlci8xLmpwZ3BhZ2UtYlBLAQIUAxQAAAAAAAAAIVB1bsl1BgAAAAYAAAANAAAAAAAAAAAAAACAAQAAAABjaGFwdGVyLzEuanBnUEsFBgAAAAABAAEAOwAAADEAAAAAAA==")!
    private static let textZIP = Data(base64Encoded: "UEsDBBQAAAAAAAAAIVDa2gPlCQAAAAkAAAAKAAAAcmVhZG1lLnR4dG5vIGltYWdlc1BLAQIUAxQAAAAAAAAAIVDa2gPlCQAAAAkAAAAKAAAAAAAAAAAAAACAAQAAAAByZWFkbWUudHh0UEsFBgAAAAABAAEAOAAAADEAAAAAAA==")!
}
