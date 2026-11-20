import Testing
import UIKit
@testable import ZipImageViewer

@Suite(.serialized)
@MainActor
struct ReaderImagePipelineTests {
    @Test func continuousSweepPublishesSamplesAndKeepsOnlyLatestPending() {
        let scheduler = LatestImageRequestScheduler()
        var completions: [(UIImage?) -> Void] = []
        var started: [Int] = []
        var shown: [Int] = []
        for page in 0..<200 {
            scheduler.submit(page: page, work: { finish in started.append(page); completions.append(finish) },
                             completion: { page, _ in shown.append(page) })
            #expect(scheduler.pendingCount <= 1)
            if page == 99 { completions.removeFirst()(nil) }
        }
        #expect(started == [0, 99])
        #expect(shown == [0]) // Do not starve an in-flight sample when the target moves.
        completions.removeFirst()(nil)
        #expect(started == [0, 99, 199])
        completions.removeFirst()(nil)
        #expect(shown == [0, 99, 199])
    }

    @Test func reentrantCompletionReplacesOlderPendingRequest() {
        let scheduler = LatestImageRequestScheduler()
        var finish: ((UIImage?) -> Void)?
        var started: [Int] = []
        var shown: [Int] = []
        scheduler.submit(page: 0, work: { finish = $0 }, completion: { page, _ in
            shown.append(page)
            // A synchronous cache hit submitted from completion wins over pending1.
            scheduler.submit(page: 2, work: { started.append(2); $0(nil) }, completion: { page, _ in shown.append(page) })
        })
        scheduler.submit(page: 1, work: { started.append(1); $0(nil) }, completion: { page, _ in shown.append(page) })
        finish?(nil)
        #expect(started == [2])
        #expect(shown == [0, 2])
    }

    @Test func reversalAndReleaseRejectOlderEpochsAndPrioritizeExactFinalPage() {
        let scheduler = LatestImageRequestScheduler()
        var finish: [(UIImage?) -> Void] = []
        var shown: [Int] = []
        func submit(_ page: Int) {
            scheduler.submit(page: page, work: { finish.append($0) }, completion: { page, _ in shown.append(page) })
        }
        submit(120); submit(180)
        scheduler.invalidate() // direction reversal discards pending 180
        submit(50)
        finish.removeFirst()(nil)
        #expect(shown.isEmpty)
        scheduler.invalidate() // release prioritizes the exact target
        submit(42)
        finish.removeFirst()(nil)
        #expect(shown.isEmpty)
        finish.removeFirst()(nil)
        #expect(shown == [42])
    }

    @Test func closeDropsPendingAndSuppressesLateCompletion() {
        let scheduler = LatestImageRequestScheduler()
        var finish: ((UIImage?) -> Void)?
        var started = 0
        var shown = 0
        for page in 0..<200 {
            scheduler.submit(page: page, work: { started += 1; finish = $0 }, completion: { _, _ in shown += 1 })
        }
        scheduler.close()
        #expect(scheduler.pendingCount == 0)
        finish?(nil)
        #expect(started == 1)
        #expect(shown == 0)
    }

    @Test func memoryWarningPreservesSelectedPageWaitingBehindObsoleteDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1200), format: format)
            .jpegData(withCompressionQuality: 0.85) { context in
                UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
            }
        let urls = [root.appendingPathComponent("0.jpg"), root.appendingPathComponent("1.jpg")]
        for url in urls { try data.write(to: url) }
        let viewer = ImageViewerViewController()
        viewer.imageUrls = urls
        viewer.loadViewIfNeeded()
        // No main-actor suspension: page 0's decode cannot have completed its
        // callback, so navigation queues page 1 behind that obsolete request.
        viewer.perform(NSSelectorFromString("nextImage"))
        #expect(viewer.currentIndex == 1 && viewer.fittedIndex == nil)
        viewer.didReceiveMemoryWarning()
        for _ in 0..<200 where viewer.fittedIndex != 1 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(viewer.fittedIndex == 1)
        #expect(viewer.displayedIndex == 1)
    }

    @Test func memoryPressureDropsQueuedNeighborWork() {
        let scheduler = LatestImageRequestScheduler()
        var finish: ((UIImage?) -> Void)?
        var neighborStarted = false
        scheduler.submit(page: 0, work: { finish = $0 }, completion: { _, _ in })
        scheduler.submit(page: 1, work: { neighborStarted = true; $0(nil) }, completion: { _, _ in })
        scheduler.dropPending(exceptPage: 0)
        finish?(nil)
        #expect(!neighborStarted)
        #expect(scheduler.pendingCount == 0)
    }

    @Test(arguments: [false, true])
    func actualReaderHandlesTwoHundredPageSweepAndReverse(compressed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let detail = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 1440), format: format).jpegData(withCompressionQuality: 0.85) { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 960, height: 1440))
            ("Detailed page" as NSString).draw(at: CGPoint(x: 100, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 64), .foregroundColor: UIColor.black])
        }
        let storedDetail = compressed
            ? try #require(ExtractedImageProcessor.repackJPEG(detail, capacity: detail.count * 2)) : detail
        var pages: [URL] = []
        var previews: [URL: URL] = [:]
        for index in 0..<200 {
            let page = root.appendingPathComponent("page-\(index).\(compressed ? "jxl" : "jpg")")
            let preview = root.appendingPathComponent("preview-\(index).jpg")
            try storedDetail.write(to: page)
            try UIGraphicsImageRenderer(size: CGSize(width: 256, height: 384), format: format).jpegData(withCompressionQuality: 0.8) { context in
                UIColor(hue: CGFloat(index) / 200, saturation: 0.3, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 256, height: 384))
                ("Page \(index + 1)" as NSString).draw(at: CGPoint(x: 12, y: 100), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 32), .foregroundColor: UIColor.black])
            }.write(to: preview)
            pages.append(page); previews[page] = preview
        }
        let viewer = ImageViewerViewController()
        viewer.imageUrls = pages; viewer.previewURLs = previews
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); window.rootViewController = viewer; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        viewer.view.layoutIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let slider = try #require(descendants(viewer.view).compactMap { $0 as? UISlider }.first)
        var callbackTimes: [Double] = []
        var shown: Set<Int> = []
        let start = CACurrentMediaTime()
        slider.sendActions(for: .touchDown)
        for page in 0..<200 {
            let began = CACurrentMediaTime()
            slider.value = Float(page); slider.sendActions(for: .valueChanged)
            callbackTimes.append((CACurrentMediaTime() - began) * 1000)
            #expect(viewer.currentIndex == page)
            #expect(slider.accessibilityValue == "Page \(page + 1) of 200")
            try await Task.sleep(for: .milliseconds(5))
            if let displayed = viewer.displayedIndex { shown.insert(displayed) }
        }
        let release = CACurrentMediaTime()
        slider.sendActions(for: .touchUpInside)
        for _ in 0..<200 where viewer.displayedIndex != 199 { try await Task.sleep(for: .milliseconds(5)) }
        let finalMilliseconds = (CACurrentMediaTime() - release) * 1000
        #expect(viewer.displayedIndex == 199)
        #expect(shown.count >= 2)
        for _ in 0..<200 where viewer.fittedIndex != 199 { try await Task.sleep(for: .milliseconds(5)) }
        let fittedMilliseconds = (CACurrentMediaTime() - release) * 1000
        #expect(viewer.fittedIndex == 199)
        // Reverse within a gesture; stale forward samples must not replace the final page.
        slider.sendActions(for: .touchDown)
        for page in [180, 120, 60, 20, 40, 80, 42] {
            slider.value = Float(page); slider.sendActions(for: .valueChanged)
            try await Task.sleep(for: .milliseconds(10))
        }
        slider.sendActions(for: .touchCancel)
        for _ in 0..<200 where viewer.displayedIndex != 42 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(viewer.currentIndex == 42 && viewer.displayedIndex == 42)
        try await Task.sleep(for: .milliseconds(100))
        #expect(viewer.displayedIndex == 42)
        let sorted = callbackTimes.sorted()
        print("READER_SWEEP codec=\(compressed ? "jxl" : "jpeg") distinctPages=200 durationMs=\((release-start)*1000) observedSamples=\(shown.count) callbackP95Ms=\(sorted[Int(Double(sorted.count-1)*0.95)]) exactFinalPreviewMs=\(finalMilliseconds) exactFinalFittedMs=\(fittedMilliseconds)")
    }

    @Test func oversizedSourceGuardRejectsUnsafeDimensionsBeforePixelAllocation() {
        #expect(ReaderImagePipeline.isSupportedSource(width: 8000, height: 4000))
        #expect(!ReaderImagePipeline.isSupportedSource(width: 8000, height: 4001))
        #expect(!ReaderImagePipeline.isSupportedSource(width: 4800, height: 7200))
        #expect(!ReaderImagePipeline.isSupportedSource(width: .infinity, height: 100))
        #expect(!ReaderImagePipeline.isSupportedSource(width: .nan, height: 100))
        #expect(!ReaderImagePipeline.isSupportedSource(width: 0, height: 100))
        #expect(!ReaderImagePipeline.isSupportedSource(width: 100001, height: 1))
    }

    @Test func asynchronousZoomUpgradePreservesScaleAndContentOffset() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        try UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 3000), format: format).jpegData(withCompressionQuality: 0.85) { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2000, height: 3000))
        }.write(to: url)
        let viewer = ImageViewerViewController()
        viewer.imageUrls = [url]
        viewer.loadViewIfNeeded()
        viewer.view.frame = CGRect(x: 0, y: 0, width: 300, height: 500)
        viewer.view.layoutIfNeeded()
        for _ in 0..<200 where viewer.fittedIndex != 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(viewer.fittedIndex == 0)
        let scroll = try #require(viewer.view.subviews.compactMap { $0 as? UIScrollView }.first)
        let imageView = try #require(scroll.subviews.compactMap { $0 as? UIImageView }.first)
        let originalBytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        // A failed detailed decode must allow the next pinch to retry.
        viewer.scrollViewWillBeginZooming(scroll, with: imageView)
        for _ in 0..<200 where viewer.detailedIndex != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(viewer.detailedIndex == nil)
        #expect(viewer.zoomReadyIndex == nil)
        try originalBytes.write(to: url)
        scroll.setZoomScale(2, animated: false)
        scroll.contentOffset = CGPoint(x: 24, y: 36)
        let expectedOffset = scroll.contentOffset
        viewer.scrollViewWillBeginZooming(scroll, with: imageView)
        for _ in 0..<200 where viewer.zoomReadyIndex != 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(viewer.zoomReadyIndex == 0)
        #expect(scroll.zoomScale == 2)
        #expect(scroll.contentOffset == expectedOffset)
        #expect(imageView.image?.cgImage?.height == 3000)
    }

    @Test func viewportResizeUpgradesFittedImageWithoutLosingSelection() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        try UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 3000), format: format).jpegData(withCompressionQuality: 0.85) { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2000, height: 3000))
        }.write(to: url)
        let viewer = ImageViewerViewController()
        viewer.imageUrls = [url]
        viewer.loadViewIfNeeded()
        viewer.view.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        viewer.view.layoutIfNeeded()
        let scroll = try #require(viewer.view.subviews.compactMap { $0 as? UIScrollView }.first)
        let imageView = try #require(scroll.subviews.compactMap { $0 as? UIImageView }.first)
        for _ in 0..<200 where viewer.fittedIndex != 0 { try await Task.sleep(for: .milliseconds(5)) }
        // Force a fitted request at the narrow viewport, then increase the window.
        viewer.perform(NSSelectorFromString("beginScrubbing"))
        viewer.perform(NSSelectorFromString("endScrubbing"))
        for _ in 0..<200 where viewer.fittedIndex != 0 { try await Task.sleep(for: .milliseconds(5)) }
        let before = try #require(imageView.image?.cgImage?.height)
        viewer.view.frame = CGRect(x: 0, y: 0, width: 600, height: 900)
        viewer.view.layoutIfNeeded()
        for _ in 0..<200 where (imageView.image?.cgImage?.height ?? 0) <= before { try await Task.sleep(for: .milliseconds(5)) }
        #expect(viewer.currentIndex == 0 && viewer.displayedIndex == 0)
        #expect((imageView.image?.cgImage?.height ?? 0) > before)
    }

    @Test func decoderRejectsMissingImageAndCloseReleasesOutstandingLease() async throws {
        let pipeline = ReaderImagePipeline()
        let leases = LeaseCounter()
        pipeline.retainImageWork = { leases.acquire() }
        var published = false
        pipeline.load(page: 0, url: URL(fileURLWithPath: "/missing/page.jxl"), previewURL: nil,
                      kind: .detail, viewportPixels: 1000) { _, _ in published = true }
        #expect(leases.acquired == 1)
        pipeline.close()
        for _ in 0..<100 where leases.outstanding != 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(leases.outstanding == 0)
        #expect(!published)
        #expect(pipeline.cachedBytes == 0)
    }

    @Test func previewDecodeUsesSidecarAndMemoryWarningClearsBudget() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 384, height: 256))
        try renderer.pngData { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 384, height: 256)) }.write(to: url)
        let pipeline = ReaderImagePipeline()
        var finished = false
        pipeline.load(page: 7, url: URL(fileURLWithPath: "/missing/detail.jxl"), previewURL: url,
                      kind: .preview, viewportPixels: 1000) { page, image in
            #expect(page == 7)
            #expect(image != nil)
            #expect(max(image?.size.width ?? 0, image?.size.height ?? 0) <= 384)
            finished = true
        }
        for _ in 0..<100 where !finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished)
        #expect(pipeline.cachedBytes > 0 && pipeline.cachedBytes <= pipeline.cacheBudget)
        pipeline.clearCache()
        #expect(pipeline.cachedBytes == 0)
        pipeline.close()
    }
}

private final class LeaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var total = 0
    var outstanding: Int { lock.lock(); defer { lock.unlock() }; return count }
    var acquired: Int { lock.lock(); defer { lock.unlock() }; return total }
    func acquire() -> () -> Void {
        lock.lock(); count += 1; total += 1; lock.unlock()
        return { self.lock.lock(); self.count -= 1; self.lock.unlock() }
    }
}
