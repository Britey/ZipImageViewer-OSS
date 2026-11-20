import Testing
import UIKit
@testable import ZipImageViewer

@Suite(.serialized)
@MainActor
struct NavigationIntegrationTests {
    private func pageFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        try renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.write(to: url)
        return url
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test(arguments: ["nextImage", "previousImage", "swipeNextImage", "swipePreviousImage"], [false, true])
    func animationFollowsInputWhenReadingOrderChanges(action: String, reversed: Bool) async throws {
        let page = try pageFixture()
        defer { try? FileManager.default.removeItem(at: page) }
        let viewer = ImageViewerViewController()
        viewer.imageUrls = [page, page, page]
        viewer.currentIndex = 1
        viewer.readingDirectionReversed = reversed
        viewer.enablePageTurnAnimation = true
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = viewer
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        viewer.view.layoutIfNeeded()
        let scrollView = try #require(viewer.view.subviews.compactMap { $0 as? UIScrollView }.first)
        let currentImage = try #require(scrollView.subviews.compactMap { $0 as? UIImageView }.first)
        let slider = try #require(descendants(of: viewer.view).compactMap { $0 as? UISlider }.first)
        let selector = NSSelectorFromString(action)
        #expect(viewer.responds(to: selector))
        for _ in 0..<100 where viewer.displayedIndex != 1 { try await Task.sleep(for: .milliseconds(10)) }
        // Let the fitted image and neighbor preparation settle before measuring a warm turn.
        try await Task.sleep(for: .milliseconds(50))
        viewer.perform(selector)

        let movesLeft = action == "nextImage" || action == "swipeNextImage"
        let expectedIndex = movesLeft ? (reversed ? 0 : 2) : (reversed ? 2 : 0)
        #expect(viewer.currentIndex == expectedIndex)
        for _ in 0..<100 where currentImage.transform.tx == 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(viewer.view.isUserInteractionEnabled)
        // Read the actual outgoing image transform, not just a navigation helper.
        #expect(currentImage.transform.tx == (movesLeft ? -scrollView.bounds.width : scrollView.bounds.width))

        for _ in 0..<100 where currentImage.transform != .identity {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewer.view.isUserInteractionEnabled)
        #expect(currentImage.transform == .identity)
        #expect(slider.value == Float(expectedIndex))
        #expect(descendants(of: viewer.view).compactMap { $0 as? UIButton }.contains { $0.accessibilityIdentifier == "readerPageButton" && $0.accessibilityValue == "Current page \(expectedIndex + 1) of 3" })

        // Repeating the same input at the edge must leave all state unchanged.
        viewer.perform(selector)
        #expect(viewer.currentIndex == expectedIndex)
        #expect(slider.value == Float(expectedIndex))
        #expect(viewer.view.isUserInteractionEnabled)
    }

    @Test(arguments: ["nextImage", "previousImage", "swipeNextImage", "swipePreviousImage"], [false, true])
    func adjacentNavigationCanPassACorruptPage(action: String, reversed: Bool) async throws {
        let page = try pageFixture()
        let corruptPage = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer {
            try? FileManager.default.removeItem(at: page)
            try? FileManager.default.removeItem(at: corruptPage)
        }
        try Data("invalid image bytes".utf8).write(to: corruptPage)
        try #require(UIImage(contentsOfFile: corruptPage.path) == nil)
        let viewer = ImageViewerViewController()
        viewer.imageUrls = [page, corruptPage, page]
        let movesLeft = action == "nextImage" || action == "swipeNextImage"
        let startsAtFirst = movesLeft != reversed
        viewer.currentIndex = startsAtFirst ? 0 : 2
        viewer.readingDirectionReversed = reversed
        viewer.enablePageTurnAnimation = true
        viewer.loadViewIfNeeded()
        let slider = try #require(descendants(of: viewer.view).compactMap { $0 as? UISlider }.first)
        let labels = viewer.view.subviews.compactMap { $0 as? UILabel }
        let selector = NSSelectorFromString(action)
        viewer.perform(selector)
        #expect(viewer.currentIndex == 1)
        #expect(slider.value == 1)
        #expect(slider.accessibilityValue == "Page 2 of 3")
        for _ in 0..<100 where !labels.contains(where: { $0.text == "This image could not be opened." && !$0.isHidden }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(labels.contains { $0.text == "This image could not be opened." && !$0.isHidden })
        viewer.perform(selector)
        let destination = startsAtFirst ? 2 : 0
        #expect(viewer.currentIndex == destination)
        #expect(slider.value == Float(destination))
        #expect(slider.accessibilityValue == "Page \(destination + 1) of 3")
        for _ in 0..<100 where viewer.displayedIndex != destination { try await Task.sleep(for: .milliseconds(10)) }
        #expect(labels.contains { $0.text == "This image could not be opened." && $0.isHidden })
        #expect(viewer.view.isUserInteractionEnabled)
    }

    @Test func tapAreaPresetsPreserveRecommendedDefault() {
        let preferences = ReaderPreferences()
        #expect(ReaderPreferences.tapAreaPresets == [0.1, 0.3, 0.5, 0.7, 0.9])
        #expect(preferences.previousPageTapWidthRatio == 0.3)
    }

    @Test func hiddenChromePreservesPageAndPreferences() throws {
        let viewer = ImageViewerViewController()
        viewer.imageUrls = [URL(fileURLWithPath: "/missing/one.png"), URL(fileURLWithPath: "/missing/two.png")]
        var preferences = ReaderPreferences()
        preferences.showPageSlider = false
        viewer.applyPreferences(preferences)
        viewer.loadViewIfNeeded()
        viewer.setChromeVisible(false)
        #expect(!viewer.chromeVisible)
        #expect(viewer.currentIndex == 0)
        viewer.setChromeVisible(true)
        #expect(viewer.chromeVisible)
        let slider = try #require(descendants(of: viewer.view).compactMap { $0 as? UISlider }.first)
        #expect(slider.isHidden)
        #expect(viewer.currentIndex == 0)
    }

    @Test func liveReorderingPreservesCurrentImageAndLatestRequest() async throws {
        let viewer = ImageViewerViewController()
        let urls = ["one", "two", "three"].map { URL(fileURLWithPath: "/missing/\($0).png") }
        viewer.imageUrls = urls
        viewer.currentIndex = 1
        var preferences = ReaderPreferences()
        viewer.applyPreferences(preferences)
        viewer.loadViewIfNeeded()
        preferences.sortOrder = .descending
        viewer.applyPreferences(preferences)
        preferences.sortOrder = .ascending
        viewer.applyPreferences(preferences)
        for _ in 0..<100 where viewer.imageUrls != ImageFileSorter.sort(urls, criterion: .filename, order: .ascending) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewer.imageUrls == ImageFileSorter.sort(urls, criterion: .filename, order: .ascending))
        #expect(viewer.imageUrls[viewer.currentIndex] == urls[1])
    }

    @Test func doubleTapZoomCanBeDisabledLiveWithoutDisablingPinchOrPan() async throws {
        let page = try pageFixture()
        defer { try? FileManager.default.removeItem(at: page) }
        let viewer = ImageViewerViewController()
        viewer.imageUrls = Array(repeating: page, count: 5)
        viewer.applyPreferences(ReaderPreferences())
        viewer.loadViewIfNeeded()
        viewer.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        viewer.view.layoutIfNeeded()
        let scroll = try #require(viewer.view.subviews.compactMap { $0 as? UIScrollView }.first)
        let doubleTap = try #require(viewer.view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.first { $0.numberOfTapsRequired == 2 })
        #expect(doubleTap.isEnabled)
        var preferences = ReaderPreferences()
        preferences.enableDoubleTapZoom = false
        viewer.applyPreferences(preferences)
        #expect(!doubleTap.isEnabled)
        #expect(scroll.pinchGestureRecognizer?.isEnabled == true)
        #expect(scroll.panGestureRecognizer.isEnabled)
        let tap = PositionedReaderTap(point: CGPoint(x: 900, y: 300))
        for expected in 1...3 {
            viewer.perform(NSSelectorFromString("handleReaderTap:"), with: tap)
            #expect(viewer.currentIndex == expected)
        }
        for _ in 0..<100 where viewer.displayedIndex != 3 { try await Task.sleep(for: .milliseconds(10)) }
        scroll.setZoomScale(2, animated: false)
        viewer.perform(NSSelectorFromString("handleDoubleTapZoom:"), with: tap)
        #expect(scroll.zoomScale == 2, "Disabled double taps cannot zoom out")
        viewer.perform(NSSelectorFromString("handleReaderTap:"), with: tap)
        #expect(viewer.currentIndex == 3, "Zoomed taps keep the current page")
        preferences.enableDoubleTapZoom = true
        viewer.applyPreferences(preferences)
        #expect(doubleTap.isEnabled)
        #expect(scroll.zoomScale == 2, "Changing the setting preserves the pinch geometry")
        for _ in 0..<100 where viewer.displayedIndex != 3 { try await Task.sleep(for: .milliseconds(10)) }
        viewer.perform(NSSelectorFromString("handleDoubleTapZoom:"), with: tap)
        for _ in 0..<100 where scroll.zoomScale > 1.01 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(abs(scroll.zoomScale - 1) < 0.01)
        viewer.perform(NSSelectorFromString("handleDoubleTapZoom:"), with: tap)
        for _ in 0..<100 where scroll.zoomScale < 2.49 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(abs(scroll.zoomScale - 2.5) < 0.01)
        #expect(viewer.currentIndex == 3)
        #expect(scroll.pinchGestureRecognizer?.isEnabled == true)
        #expect(scroll.panGestureRecognizer.isEnabled)
    }

    @Test func zoomDisablesPageGesturesButAllowsLongPress() throws {
        let viewer = ImageViewerViewController()
        viewer.loadViewIfNeeded()
        let scroll = try #require(viewer.view.subviews.compactMap { $0 as? UIScrollView }.first)
        scroll.setZoomScale(2, animated: false)
        #expect(!viewer.gestureRecognizerShouldBegin(UITapGestureRecognizer()))
        #expect(!viewer.gestureRecognizerShouldBegin(UISwipeGestureRecognizer()))
        #expect(viewer.gestureRecognizerShouldBegin(UILongPressGestureRecognizer()))
    }

    @Test(arguments: [false, true])
    func centerTapOnlyTogglesChromeAcrossTapPresets(reversed: Bool) throws {
        let page = try pageFixture()
        defer { try? FileManager.default.removeItem(at: page) }
        for ratio in ReaderPreferences.tapAreaPresets {
            var preferences = ReaderPreferences()
            preferences.readingDirectionReversed = reversed
            preferences.previousPageTapWidthRatio = ratio
            let viewer = ImageViewerViewController()
            viewer.imageUrls = [page, page, page]
            viewer.currentIndex = 1
            viewer.applyPreferences(preferences)
            viewer.loadViewIfNeeded()
            viewer.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
            var pageChanges = 0
            viewer.onPositionChange = { _, _ in pageChanges += 1 }
            let tap = PositionedReaderTap(point: CGPoint(x: 500, y: 400))
            viewer.perform(NSSelectorFromString("handleReaderTap:"), with: tap)
            #expect(!viewer.chromeVisible)
            #expect(viewer.currentIndex == 1)
            viewer.perform(NSSelectorFromString("handleReaderTap:"), with: tap)
            #expect(viewer.chromeVisible)
            #expect(pageChanges == 0)
            // Above the small patch, the same x coordinate still turns pages.
            tap.point.y = 50
            viewer.perform(NSSelectorFromString("handleReaderTap:"), with: tap)
            let isLeft = 0.5 < ratio
            let forward = isLeft ? reversed : !reversed
            #expect(viewer.currentIndex == (forward ? 2 : 0))
            #expect(viewer.chromeVisible)
        }
    }

    @Test(arguments: [false, true])
    func disablingCenterTapRestoresNormalPageAction(reversed: Bool) throws {
        let page = try pageFixture()
        defer { try? FileManager.default.removeItem(at: page) }
        let viewer = ImageViewerViewController()
        viewer.imageUrls = [page, page, page]
        viewer.currentIndex = 1
        var preferences = ReaderPreferences()
        preferences.readingDirectionReversed = reversed
        viewer.applyPreferences(preferences)
        viewer.loadViewIfNeeded()
        viewer.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        preferences.centerTapTogglesControls = false
        viewer.applyPreferences(preferences)
        let tap = PositionedReaderTap(point: CGPoint(x: 500, y: 400))
        viewer.perform(NSSelectorFromString("handleReaderTap:"), with: tap)
        #expect(viewer.chromeVisible)
        #expect(viewer.currentIndex == (reversed ? 0 : 2))
    }

    @Test func centerTapCanRevealControlsWhileZoomedWithoutPaging() throws {
        let page = try pageFixture()
        defer { try? FileManager.default.removeItem(at: page) }
        let viewer = ImageViewerViewController()
        viewer.imageUrls = [page, page, page]
        viewer.currentIndex = 1
        viewer.applyPreferences(ReaderPreferences())
        viewer.loadViewIfNeeded()
        viewer.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        viewer.view.layoutIfNeeded()
        let scroll = try #require(viewer.view.subviews.compactMap { $0 as? UIScrollView }.first)
        scroll.setZoomScale(2, animated: false)
        viewer.setChromeVisible(false)
        let tap = PositionedReaderTap(point: CGPoint(x: 500, y: 400))
        #expect(viewer.gestureRecognizerShouldBegin(tap))
        viewer.perform(NSSelectorFromString("handleReaderTap:"), with: tap)
        #expect(viewer.chromeVisible)
        #expect(viewer.currentIndex == 1)
        #expect(scroll.zoomScale == 2)
        tap.point.x = 900
        #expect(!viewer.gestureRecognizerShouldBegin(tap))
        viewer.perform(NSSelectorFromString("handleReaderTap:"), with: tap)
        #expect(viewer.currentIndex == 1)
        #expect(!viewer.gestureRecognizerShouldBegin(UISwipeGestureRecognizer()))
        #expect(viewer.gestureRecognizerShouldBegin(UILongPressGestureRecognizer()))
    }

    @Test func centerTapPatchRemainsSmallAndRecentersAfterResize() {
        let viewer = ImageViewerViewController()
        viewer.loadViewIfNeeded()
        for size in [CGSize(width: 320, height: 568), CGSize(width: 1194, height: 834), CGSize(width: 834, height: 1194)] {
            viewer.view.frame = CGRect(origin: .zero, size: size)
            let patch = viewer.centerControlsTapRect
            #expect(patch.midX == size.width / 2)
            #expect(patch.midY == size.height / 2)
            #expect(patch.width >= 80 && patch.width <= 160)
            #expect(patch.height >= 80 && patch.height <= 160)
            #expect(!patch.contains(CGPoint(x: size.width / 2, y: 1)))
        }
    }

}


@MainActor
private final class PositionedReaderTap: UITapGestureRecognizer {
    var point: CGPoint
    init(point: CGPoint) { self.point = point; super.init(target: nil, action: nil) }
    override func location(in view: UIView?) -> CGPoint { point }
}
