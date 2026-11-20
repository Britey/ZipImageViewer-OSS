import Testing
import UIKit
@testable import ZipImageViewer

@Suite(.serialized)
@MainActor
struct ReadingProgressTests {
    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
    @Test func restoredPageAndEveryNavigationReportTheSelectedPath() throws {
        // Missing images intentionally exercise the same placeholder path as
        // damaged pages; progress must not depend on successful image decoding.
        let pages = ["chapter-one/page.png", "chapter-two/page.png", "last.png"].map {
            URL(fileURLWithPath: "/missing/\($0)")
        }
        let viewer = ImageViewerViewController()
        viewer.imageUrls = pages
        viewer.currentIndex = 1
        viewer.enablePageTurnAnimation = false
        var positions: [(URL, Int)] = []
        viewer.onPositionChange = { positions.append(($0, $1)) }
        viewer.loadViewIfNeeded()
        #expect(positions.last?.0 == pages[1])
        #expect(positions.last?.1 == 1)

        viewer.perform(NSSelectorFromString("nextImage"))
        #expect(positions.last?.0 == pages[2])
        #expect(positions.last?.1 == 2)
        viewer.perform(NSSelectorFromString("nextImage"))
        #expect(positions.count == 2, "An out-of-bounds navigation does not change progress")

        let slider = try #require(descendants(of: viewer.view).compactMap { $0 as? UISlider }.first)
        slider.value = 0
        slider.sendActions(for: .valueChanged)
        #expect(positions.last?.0 == pages[0])
        #expect(positions.last?.1 == 0)
    }

    @Test func backgroundFlushDoesNotReleaseTheReader() {
        let viewer = ImageViewerViewController()
        viewer.imageUrls = [URL(fileURLWithPath: "/missing/page.png")]
        var flushes = 0
        var closes = 0
        viewer.onFlushProgress = { flushes += 1 }
        viewer.onClose = { closes += 1 }
        viewer.loadViewIfNeeded()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(flushes == 1)
        #expect(closes == 0)
    }

    @Test func readerToolDoesNotReleaseTheSession() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKeyWindow?.makeKey() }
        let viewer = ImageViewerViewController()
        viewer.imageUrls = [URL(fileURLWithPath: "/missing/page.png")]
        viewer.modalPresentationStyle = .fullScreen
        var closes = 0
        viewer.onClose = { closes += 1 }
        await withCheckedContinuation { continuation in host.present(viewer, animated: false) { continuation.resume() } }
        let tool = UINavigationController(rootViewController: PageOverviewViewController(urls: viewer.imageUrls, currentIndex: 0))
        tool.modalPresentationStyle = .formSheet
        await withCheckedContinuation { continuation in viewer.present(tool, animated: false) { continuation.resume() } }
        #expect(closes == 0)
        await withCheckedContinuation { continuation in viewer.dismiss(animated: false) { continuation.resume() } }
        #expect(closes == 0)
        await withCheckedContinuation { continuation in host.dismiss(animated: false) { continuation.resume() } }
        #expect(closes == 1)
    }

    @Test func externalDismissalReleasesReaderExactlyOnce() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        let viewer = ImageViewerViewController()
        viewer.imageUrls = [URL(fileURLWithPath: "/missing/page.png")]
        viewer.modalPresentationStyle = .fullScreen
        var closes = 0
        var flushes = 0
        viewer.onClose = { closes += 1 }
        viewer.onFlushProgress = { flushes += 1 }
        await withCheckedContinuation { continuation in
            host.present(viewer, animated: false) { continuation.resume() }
        }
        #expect(closes == 0)
        await withCheckedContinuation { continuation in
            host.dismiss(animated: false) { continuation.resume() }
        }
        #expect(closes == 1)
        #expect(flushes == 1)
        viewer.viewDidDisappear(false)
        #expect(closes == 1)
    }
}
