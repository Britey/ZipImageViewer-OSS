import Testing
import UIKit
@testable import ZipImageViewer

@Suite(.serialized)
@MainActor
struct ReaderToolsTests {
    @Test(arguments: ["", " ", "0", "-1", "11", "1.5", "999999999999999999999999999999", "a", "1 2"])
    func invalidPageInputIsRejected(_ input: String) { #expect(PageInput.index(for: input, pageCount: 10) == nil) }

    @Test func validPageInputUsesOneBasedNumbers() {
        #expect(PageInput.index(for: "1", pageCount: 10) == 0)
        #expect(PageInput.index(for: " 10\n", pageCount: 10) == 9)
        #expect(PageInput.index(for: "1", pageCount: 1) == 0)
        #expect(PageInput.index(for: "1", pageCount: 0) == nil)
    }

    @Test func overviewThumbnailsAreDownsampledAndKeepPageLabelsVisible() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 2400), format: format)
        try renderer.pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 2400))
        }.write(to: url)
        let image = try #require(PageThumbnailLoader.decode(url)?.cgImage)
        #expect(image.width <= 720)
        #expect(image.height <= 720)
        #expect(image.height > image.width)

        // A decoded 720px thumbnail has a larger intrinsic height than its card.
        // Its image must compress rather than erase the page number beneath it.
        let cell = PageThumbnailCell(frame: CGRect(x: 0, y: 0, width: 140, height: 220))
        cell.imageView.image = UIImage(cgImage: image)
        cell.label.text = "Page 600"
        cell.layoutIfNeeded()
        #expect(cell.label.bounds.height >= cell.label.font.lineHeight)
        #expect(cell.imageView.frame.maxY <= cell.label.frame.minY)
        let labelFrame = cell.label.convert(cell.label.bounds, to: cell.contentView)
        #expect(labelFrame.maxY <= cell.contentView.bounds.maxY)
        #expect(cell.imageView.clipsToBounds)

    }

    @Test(arguments: [CGFloat(320), 744, 1194])
    func compactChromeKeepsButtonsBesideSliderAndCanvasExposed(width: CGFloat) throws {
        let controls = ReaderControlsView(frame: CGRect(x: 0, y: 0, width: width, height: 600))
        controls.update(page: 599, count: 600)
        controls.layoutIfNeeded()
        let page = controls.pageButton.convert(controls.pageButton.bounds, to: controls)
        let slider = controls.slider.convert(controls.slider.bounds, to: controls)
        let pages = controls.pagesButton.convert(controls.pagesButton.bounds, to: controls)
        #expect(abs(page.midY - slider.midY) < 1)
        #expect(abs(pages.midY - slider.midY) < 1)
        #expect(page.maxX < slider.minX)
        #expect(slider.maxX < pages.minX)
        #expect(page.minX >= 0 && pages.maxX <= width)
        #expect(controls.bottomSurface.frame.height == 44)
        #expect(controls.bottomSurface.frame.maxY == 600)
        #expect(controls.hitTest(CGPoint(x: width / 2, y: 22), with: nil) == nil)
        controls.apply(showSlider: false, showCount: false)
        controls.layoutIfNeeded()
        #expect(controls.slider.isHidden)
        #expect(!controls.pageButton.isHidden)
        #expect(controls.pageButton.configuration?.title == nil)
        #expect(controls.pageButton.configuration?.image != nil)
    }

    @Test func sharedCanvasScrubCommitsExactReleaseAndRoutesTools() throws {
        let viewer = ImageViewerViewController()
        let overlay = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let button = UIButton(type: .system)
        overlay.addSubview(button)
        viewer.sharedChromeView = overlay
        viewer.imageUrls = (0..<10).map { URL(fileURLWithPath: "/missing/\($0).png") }
        var lastPage = 0
        viewer.onReaderUIChanged = { lastPage = ($0["page"] as? Int) ?? 0 }
        viewer.loadViewIfNeeded()
        let controls = try #require(viewer.view.subviews.compactMap { $0 as? ReaderControlsView }.first)
        #expect(controls.isHidden)
        viewer.performSharedAction("seek", page: 8, scrubbing: true)
        viewer.performSharedAction("seek", page: 9, scrubbing: false)
        #expect(viewer.currentIndex == 8)
        #expect(lastPage == 9)
        viewer.performSharedAction("toggleControls", page: nil, scrubbing: false)
        #expect(!viewer.chromeVisible)
        #expect(controls.isHidden)
        viewer.performSharedAction("showControls", page: nil, scrubbing: false)
        #expect(viewer.chromeVisible)
        #expect(controls.isHidden)
        var tool: String?
        viewer.onReaderToolRequested = { tool = $0 }
        controls.pagesButton.sendActions(for: .touchUpInside)
        #expect(tool == "pages")
        #expect(viewer.presentedViewController == nil)
    }

    @Test func sharedHostingContainerPassesEmptyTouchesAndKeepsButtons() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        let button = UIButton(frame: CGRect(x: 20, y: 20, width: 80, height: 44))
        root.addSubview(button)
        let container = ReaderChromeContainer(root: root)
        #expect(container.hitTest(CGPoint(x: 160, y: 300), with: nil) == nil)
        #expect(container.hitTest(CGPoint(x: 40, y: 40), with: nil) === button)
    }

    @Test func sharedHostCloseDismissesReaderAndPresentedToolOnce() async throws {
        let presenter = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 912))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let viewer = ImageViewerViewController()
        viewer.sharedChromeView = UIView()
        viewer.modalPresentationStyle = .fullScreen
        presenter.present(viewer, animated: false)
        viewer.present(UIViewController(), animated: false)
        var closes = 0
        viewer.onClose = { closes += 1 }
        viewer.closeFromHost()
        try await Task.sleep(for: .milliseconds(700))
        #expect(presenter.presentedViewController == nil)
        #expect(viewer.presentedViewController == nil)
        #expect(closes == 1)
    }

    @Test func pagesButtonOpensOverviewDirectly() throws {
        let viewer = ImageViewerViewController()
        viewer.imageUrls = [URL(fileURLWithPath: "/missing/page.png")]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        window.rootViewController = viewer
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let controls = try #require(viewer.view.subviews.compactMap { $0 as? ReaderControlsView }.first)
        #expect(controls.pagesButton.menu == nil)
        controls.pagesButton.sendActions(for: .touchUpInside)
        let navigation = try #require(viewer.presentedViewController as? UINavigationController)
        #expect(navigation.topViewController is PageOverviewViewController)
    }

    @Test func thumbnailPreferenceChangesGridDensityWithoutAddingOverviewControls() {
        let urls = (0..<30).map { URL(fileURLWithPath: "/missing/\($0).png") }
        func size(_ preference: Double) -> CGSize {
            let overview = PageOverviewViewController(urls: urls, currentIndex: 0, thumbnailSize: preference)
            overview.loadViewIfNeeded()
            overview.collectionView.frame = CGRect(x: 0, y: 0, width: 760, height: 600)
            #expect(overview.toolbarItems == nil)
            return overview.collectionView(overview.collectionView, layout: overview.collectionViewLayout, sizeForItemAt: IndexPath(item: 0, section: 0))
        }
        #expect(size(0).width < size(0.5).width)
        #expect(size(0.5).width < size(1).width)
        #expect(size(1).width <= 760 - 32)
    }

}
