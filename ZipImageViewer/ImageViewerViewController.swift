import UIKit

final class ImageViewerViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var archiveTitle = "Archive"
    var onSettingsRequested: (() -> Void)?
    var sharedChromeView: UIView?
    var onReaderUIChanged: (([String: Any]) -> Void)?
    var onReaderToolRequested: ((String) -> Void)?
    var imageUrls: [URL] = []
    var pageMetadata: [URL: ArchivePreparedPage] = [:]
    var previewURLs: [URL: URL] = [:]
    var retainImageWork: (() -> (() -> Void))?
    var currentIndex: Int = 0
    var onPositionChange: ((URL, Int) -> Void)?
    var onFlushProgress: (() -> Void)?
    var onClose: (() -> Void)?
    private var didReportClose = false

    // Settings passed from main view
    var showScrollBar: Bool = true
    var showPageNumber: Bool = true
    var centerTapTogglesControls = true
    var readingDirectionReversed: Bool = false
    var previousPageTapWidthRatio: CGFloat = 0.3
    var enableDoubleTapZoom = true {
        didSet { doubleTapGesture?.isEnabled = enableDoubleTapZoom }
    }
    var enablePageTurnAnimation: Bool = false

    private(set) var imageQuarterTurns = 0
    private var sourceImage: UIImage?
    private var rotationPageURL: URL?
    private var doubleTapGesture: UITapGestureRecognizer?
    private var scrollView: UIScrollView!
    private var imageView: UIImageView!
    private var transitionImageView: UIImageView!
    private var slider: UISlider!
    private let controls = ReaderControlsView()
    private(set) var chromeVisible = true
    private var sortGeneration = 0
    private var appliedPreferences: ReaderPreferences?
    private var sortingPages = false
    private weak var overview: PageOverviewViewController?
    private let imagePipeline = ReaderImagePipeline()
    private var scrubbing = false
    private var scrubTimer: Timer?
    private var lastSampledIndex: Int?
    private var scrubDirection = 0
    private var lastScrubInputTime: CFTimeInterval = 0
    private var pausedDetailIndex: Int?
    private var selectionGeneration = 0
    private(set) var displayedIndex: Int?
    private(set) var fittedIndex: Int?
    private(set) var zoomReadyIndex: Int?
    private var detailFailed = false
    private(set) var detailedIndex: Int?
    private var fittedPixelLimit = 0
    private var suppressPrefetch = false
    private let previewPageLabel = UILabel()
    private let unavailableImageLabel = UILabel()
    private var viewportSize: CGSize = .zero

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        configureScrollView()
        configureImageViews()
        configureGestures()
        configureControls()
        configureUnavailableImageLabel()
        configurePreviewPageLabel()
        imagePipeline.retainImageWork = retainImageWork
        NotificationCenter.default.addObserver(self, selector: #selector(flushProgress),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)

        if let sharedChromeView {
            sharedChromeView.frame = view.bounds
            sharedChromeView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(sharedChromeView)
            controls.isHidden = true
        }
        if !imageUrls.isEmpty {
            currentIndex = min(max(currentIndex, 0), imageUrls.count - 1)
            displayImage(at: currentIndex, animated: false, navigationStep: 0)
        }
    }

    private func configureScrollView() {
        scrollView = UIScrollView(frame: view.bounds)
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.backgroundColor = .black
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 3.0
        view.addSubview(scrollView)
    }

    private func configureImageViews() {
        imageView = UIImageView(frame: scrollView.bounds)
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        transitionImageView = UIImageView(frame: scrollView.bounds)
        transitionImageView.contentMode = .scaleAspectFit
        transitionImageView.isHidden = true
        scrollView.addSubview(transitionImageView)
    }

    private func configureGestures() {
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(swipeNextImage))
        swipeLeft.direction = .left
        swipeLeft.delegate = self
        view.addGestureRecognizer(swipeLeft)

        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(swipePreviousImage))
        swipeRight.direction = .right
        swipeRight.delegate = self
        view.addGestureRecognizer(swipeRight)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleReaderTap(_:)))
        tapGesture.numberOfTapsRequired = 1
        tapGesture.delegate = self
        view.addGestureRecognizer(tapGesture)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTapZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        doubleTap.isEnabled = enableDoubleTapZoom
        view.addGestureRecognizer(doubleTap)
        doubleTapGesture = doubleTap
        // A disabled recognizer fails immediately, so rapid page taps do not wait
        // for the double-tap interval when this preference is off.
        tapGesture.require(toFail: doubleTap)

        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.5
        longPressGesture.delegate = self
        view.addGestureRecognizer(longPressGesture)
        tapGesture.require(toFail: longPressGesture)
    }

    private func configureControls() {
        controls.frame = view.bounds
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controls)
        controls.backButton.addTarget(self, action: #selector(dismissViewer), for: .touchUpInside)
        controls.rotateCounterclockwiseButton.addTarget(self, action: #selector(rotateCounterclockwise), for: .touchUpInside)
        controls.rotateClockwiseButton.addTarget(self, action: #selector(rotateClockwise), for: .touchUpInside)
        controls.settingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        controls.hideButton.addTarget(self, action: #selector(toggleChrome), for: .touchUpInside)
        controls.pageButton.addTarget(self, action: #selector(promptForPageNumber), for: .touchUpInside)
        controls.pagesButton.addTarget(self, action: #selector(showPages), for: .touchUpInside)
        slider = controls.slider
        slider.addTarget(self, action: #selector(sliderValueChanged(_:)), for: .valueChanged)
        slider.addTarget(self, action: #selector(beginScrubbing), for: .touchDown)
        slider.addTarget(self, action: #selector(endScrubbing), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        controls.apply(showSlider: showScrollBar, showCount: showPageNumber, showRotationButtons: appliedPreferences?.showRotationButtons ?? false)
        scrollView.isAccessibilityElement = true
        scrollView.accessibilityLabel = "Reading canvas, \(archiveTitle)"
        updateCanvasHint()
        updatePageNumber()
    }

    @objc private func openSettings() { onSettingsRequested?() }
    @objc private func toggleChrome() { setChromeVisible(!chromeVisible) }
    func setChromeVisible(_ visible: Bool) {
        chromeVisible = visible
        controls.isHidden = sharedChromeView != nil || !visible
        publishReaderUI()
    }

    func applyPreferences(_ preferences: ReaderPreferences) {
        let previous = appliedPreferences
        appliedPreferences = preferences
        showScrollBar = preferences.showPageSlider
        showPageNumber = preferences.showPageCount
        centerTapTogglesControls = preferences.centerTapTogglesControls
        enableDoubleTapZoom = preferences.enableDoubleTapZoom
        readingDirectionReversed = preferences.readingDirectionReversed
        enablePageTurnAnimation = preferences.enablePageTurnAnimation
        previousPageTapWidthRatio = CGFloat(preferences.previousPageTapWidthRatio)
        guard isViewLoaded else { return }
        controls.apply(showSlider: showScrollBar, showCount: showPageNumber, showRotationButtons: appliedPreferences?.showRotationButtons ?? false)
        updateCanvasHint()
        guard previous?.sortCriterion != preferences.sortCriterion || previous?.sortOrder != preferences.sortOrder else { return }
        sortGeneration += 1
        let generation = sortGeneration
        let urls = imageUrls
        let metadata = pageMetadata
        let releaseSort = retainImageWork?()
        sortingPages = true
        publishReaderUI()
        controls.bottomSurface.isUserInteractionEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sorted = ImageFileSorter.sort(urls, criterion: preferences.sortCriterion, order: preferences.sortOrder, metadata: metadata)
            releaseSort?()
            DispatchQueue.main.async {
                guard let self, !self.didReportClose, generation == self.sortGeneration else { return }
                // Read the currently displayed identity at commit, never the session's saved index.
                let currentURL = self.imageUrls.indices.contains(self.currentIndex) ? self.imageUrls[self.currentIndex] : nil
                self.imageUrls = sorted
                self.imagePipeline.clearCache()
                self.sortingPages = false
                self.controls.bottomSurface.isUserInteractionEnabled = true
                self.displayImage(at: currentURL.flatMap { sorted.firstIndex(of: $0) } ?? 0, animated: false, navigationStep: 0)
            }
        }
    }

    private func configureUnavailableImageLabel() {
        unavailableImageLabel.text = "This image could not be opened."
        unavailableImageLabel.textColor = .white
        unavailableImageLabel.font = .preferredFont(forTextStyle: .body)
        unavailableImageLabel.adjustsFontForContentSizeCategory = true
        unavailableImageLabel.textAlignment = .center
        unavailableImageLabel.numberOfLines = 0
        unavailableImageLabel.isHidden = true
        unavailableImageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(unavailableImageLabel)
        NSLayoutConstraint.activate([
            unavailableImageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            unavailableImageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            unavailableImageLabel.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -40)
        ])
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The parent view's page gestures must not consume Close, slider, or
        // page-number touches (including touches on a control's subviews).
        var touchedView = touch.view
        while let candidate = touchedView {
            if candidate === sharedChromeView || candidate is UIControl || candidate === controls.topSurface || candidate === controls.bottomSurface { return false }
            touchedView = candidate.superview
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UISwipeGestureRecognizer {
            return scrollView.zoomScale <= scrollView.minimumZoomScale
        }
        if let tap = gestureRecognizer as? UITapGestureRecognizer {
            if tap === doubleTapGesture { return enableDoubleTapZoom && imageView.image != nil && !scrubbing }
            return scrollView.zoomScale <= scrollView.minimumZoomScale ||
                (centerTapTogglesControls && centerControlsTapRect.contains(tap.location(in: view)))
        }
        return true
    }

    /// Explicit host close uses the same idempotent finalization as the native controls.
    func closeFromHost() { dismissViewer() }

    @objc private func dismissViewer() {
        flushProgress()
        // Dismiss the reader and any shared React modal as one hierarchy.
        if sharedChromeView != nil, let presenter = presentingViewController {
            presenter.dismiss(animated: true) { [weak self] in self?.reportClose() }
        } else {
            dismiss(animated: true) { [weak self] in self?.reportClose() }
        }
    }

    @objc private func flushProgress() {
        onFlushProgress?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Presenting another controller or backgrounding must not release the
        // reader's files. Also cover dismissal initiated by the presenting UI.
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            reportClose()
        }
    }

    private func reportClose() {
        guard !didReportClose else { return }
        didReportClose = true
        sortGeneration += 1
        scrubTimer?.invalidate()
        scrubTimer = nil
        imagePipeline.close()
        overview?.cancelThumbnailWork()
        flushProgress()
        onClose?()
        onClose = nil
        onPositionChange = nil
        onFlushProgress = nil
    }

    private var viewportPixels: Int {
        Int(max(scrollView.bounds.width, scrollView.bounds.height) * (view.window?.screen.scale ?? UIScreen.main.scale))
    }

    private func configurePreviewPageLabel() {
        previewPageLabel.textColor = .white
        previewPageLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        previewPageLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        previewPageLabel.textAlignment = .center
        previewPageLabel.numberOfLines = 2
        previewPageLabel.isHidden = true
        previewPageLabel.accessibilityIdentifier = "readerPreviewPage"
        previewPageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewPageLabel)
        NSLayoutConstraint.activate([
            previewPageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            previewPageLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -56),
            previewPageLabel.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -24)
        ])
    }

    private func updateDisplayedIdentity() {
        publishReaderUI()
        if let displayedIndex, displayedIndex != currentIndex || scrubbing {
            previewPageLabel.text = "  Preview: page \(displayedIndex + 1) • Target: \(currentIndex + 1)  "
            previewPageLabel.isHidden = sharedChromeView != nil
            scrollView.accessibilityValue = "Showing page \(displayedIndex + 1), target page \(currentIndex + 1) of \(imageUrls.count)"
        } else {
            previewPageLabel.isHidden = true
            scrollView.accessibilityValue = displayedIndex == nil
                ? "Page \(currentIndex + 1) of \(imageUrls.count), \(unavailableImageLabel.text == "This image could not be opened." ? "image unavailable" : "loading")"
                : "Page \(currentIndex + 1) of \(imageUrls.count)"
            updateRotationAccessibilityValue()
        }
    }

    private func preloadAdjacentImages(around index: Int, generation: Int) {
        guard !scrubbing, !didReportClose, !suppressPrefetch, generation == selectionGeneration else { return }
        let neighbors = [index + 1, index - 1].filter { imageUrls.indices.contains($0) }
        func next(_ offset: Int) {
            guard !scrubbing, !didReportClose, !suppressPrefetch, generation == selectionGeneration, offset < neighbors.count else { return }
            let page = neighbors[offset]
            imagePipeline.load(page: page, url: imageUrls[page], previewURL: nil, kind: .viewport,
                               viewportPixels: viewportPixels) { [weak self] _, _ in
                guard let self, !self.scrubbing, generation == self.selectionGeneration else { return }
                next(offset + 1)
            }
        }
        next(0)
    }

    private func resetImageGeometry() {
        // UIScrollView owns the zoom transform. Reset it before setting frames
        // or applying the independent page-turn translation.
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        imageView.transform = .identity
        transitionImageView.transform = .identity
        scrollView.contentOffset = .zero
        let frame = CGRect(origin: .zero, size: scrollView.bounds.size)
        imageView.frame = frame
        transitionImageView.frame = frame
        scrollView.contentSize = frame.size
    }

    private func applyCurrentImage(_ image: UIImage?, page: Int, preserveGeometry: Bool = false) {
        if imageUrls.indices.contains(page), rotationPageURL != imageUrls[page] {
            imageQuarterTurns = 0; rotationPageURL = imageUrls[page]
        }
        if !preserveGeometry { resetImageGeometry() }
        sourceImage = image
        imageView.image = image?.rotatedQuarterTurns(imageQuarterTurns)
        transitionImageView.image = nil
        transitionImageView.isHidden = true
        unavailableImageLabel.text = "This image could not be opened."
        unavailableImageLabel.isHidden = sharedChromeView != nil || image != nil
        displayedIndex = image == nil ? nil : page
        updateDisplayedIdentity()
    }

    private func displayImage(at index: Int, animated: Bool, navigationStep: Int) {
        guard !didReportClose, imageUrls.indices.contains(index) else { return }
        if rotationPageURL != imageUrls[index] { imageQuarterTurns = 0; rotationPageURL = imageUrls[index] }
        scrubbing = false
        scrubTimer?.invalidate(); scrubTimer = nil
        imagePipeline.invalidatePreviews()
        imagePipeline.invalidateDetails()
        selectionGeneration += 1
        let generation = selectionGeneration
        imageView.layer.removeAllAnimations()
        transitionImageView.layer.removeAllAnimations()
        transitionImageView.isHidden = true
        transitionImageView.image = nil
        resetImageGeometry()
        currentIndex = index
        detailedIndex = nil
        detailFailed = false
        fittedIndex = nil
        fittedPixelLimit = 0
        zoomReadyIndex = nil
        suppressPrefetch = false
        onPositionChange?(imageUrls[index], index)
        updatePageNumber()
        updateDisplayedIdentity()
        let previousImage = imageView.image
        let previousIndex = displayedIndex
        if previousImage == nil { unavailableImageLabel.text = "Loading image…"; unavailableImageLabel.isHidden = sharedChromeView != nil; publishReaderUI() }
        // Previews and detailed decode have independent lanes. A late preview must
        // never downgrade a viewport image that has already arrived.
        var viewportArrived = false
        let requestedPixels = viewportPixels
        imagePipeline.load(page: index, url: imageUrls[index], previewURL: previewURLs[imageUrls[index]],
                           kind: .preview, viewportPixels: viewportPixels) { [weak self] page, image in
            guard let self, generation == self.selectionGeneration, !viewportArrived,
                  self.fittedIndex != page, self.zoomReadyIndex != page, let image else { return }
            self.applyCurrentImage(image, page: page)
        }
        imagePipeline.load(page: index, url: imageUrls[index], previewURL: nil, kind: .viewport,
                           viewportPixels: requestedPixels) { [weak self] page, image in
            guard let self, generation == self.selectionGeneration else { return }
            viewportArrived = true
            self.fittedIndex = image == nil ? nil : page
            self.fittedPixelLimit = requestedPixels
            let shouldAnimate = image != nil && previousImage != nil && previousIndex != page && animated
                && self.enablePageTurnAnimation && self.imageQuarterTurns == 0 && !UIAccessibility.isReduceMotionEnabled && navigationStep != 0
            if shouldAnimate {
                self.animateImage(image!, from: previousImage!, previousPage: previousIndex, page: page, step: navigationStep, generation: generation)
            } else {
                self.applyCurrentImage(image, page: page, preserveGeometry: self.displayedIndex == page)
            }
            self.preloadAdjacentImages(around: page, generation: generation)
            self.upgradeViewportIfNeeded()
        }
    }

    private func animateImage(_ image: UIImage, from previous: UIImage, previousPage: Int?, page: Int, step: Int, generation: Int) {
        resetImageGeometry()
        imageView.image = previous
        displayedIndex = previousPage
        updateDisplayedIdentity()
        let incoming = step > 0 ? scrollView.bounds.width : -scrollView.bounds.width
        transitionImageView.image = image
        transitionImageView.transform = CGAffineTransform(translationX: incoming, y: 0)
        transitionImageView.isHidden = false
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState], animations: {
            self.imageView.transform = CGAffineTransform(translationX: -incoming, y: 0)
            self.transitionImageView.transform = .identity
        }, completion: { [weak self] finished in
            guard finished, let self, generation == self.selectionGeneration else { return }
            self.transitionImageView.isHidden = true
            self.applyCurrentImage(image, page: page)
        })
    }

    private func updatePageNumber() {
        controls.update(page: currentIndex, count: imageUrls.count)
        updateDisplayedIdentity()
    }

    @objc private func nextImage() {
        moveToAdjacentImage(indexForward: !readingDirectionReversed, animationStep: 1)
    }

    @objc private func previousImage() {
        moveToAdjacentImage(indexForward: readingDirectionReversed, animationStep: -1)
    }

    @objc private func swipeNextImage() {
        moveToAdjacentImage(indexForward: !readingDirectionReversed, animationStep: 1)
    }

    @objc private func swipePreviousImage() {
        moveToAdjacentImage(indexForward: readingDirectionReversed, animationStep: -1)
    }

    /// A small screen-centred patch, independent of image zoom and tap-area presets.
    var centerControlsTapRect: CGRect {
        let width = min(view.bounds.width, min(160, max(80, view.bounds.width * 0.2)))
        let height = min(view.bounds.height, min(160, max(80, view.bounds.height * 0.2)))
        return CGRect(x: view.bounds.midX - width / 2, y: view.bounds.midY - height / 2,
                      width: width, height: height)
    }

    private func updateCanvasHint() {
        scrollView.accessibilityHint = centerTapTogglesControls
            ? "Tap the center or long press to hide or show controls."
            : "Long press to hide or show controls."
    }

    @objc private func handleDoubleTapZoom(_ gesture: UITapGestureRecognizer) {
        guard enableDoubleTapZoom, imageView.image != nil, !scrubbing else { return }
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let scale = min(scrollView.maximumZoomScale, 2.5)
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                      width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func handleReaderTap(_ gesture: UITapGestureRecognizer) {
        if centerTapTogglesControls && centerControlsTapRect.contains(gesture.location(in: view)) {
            toggleChrome()
            return
        }
        // Zoomed images keep their pan interaction; only the centre can toggle chrome.
        guard scrollView.zoomScale <= scrollView.minimumZoomScale else { return }
        handleScreenTap(gesture)
    }

    @objc private func handleScreenTap(_ gesture: UITapGestureRecognizer) {
        let tapX = gesture.location(in: view).x
        let threshold = view.bounds.width * clampedPreviousRatio
        if tapX < threshold {
            previousImage()
        } else {
            nextImage()
        }
    }

    private var clampedPreviousRatio: CGFloat {
        min(max(previousPageTapWidthRatio, 0.0), 1.0)
    }

    private func moveToAdjacentImage(indexForward: Bool, animationStep: Int) {
        let proposedIndex = currentIndex + (indexForward ? 1 : -1)
        guard !sortingPages, imageUrls.indices.contains(proposedIndex) else { return }

        displayImage(at: proposedIndex, animated: true, navigationStep: animationStep)
    }

    @objc private func beginScrubbing() {
        guard !sortingPages, !didReportClose else { return }
        scrubbing = true
        selectionGeneration += 1
        imagePipeline.invalidateDetails()
        imagePipeline.invalidatePreviews()
        imageView.layer.removeAllAnimations()
        transitionImageView.layer.removeAllAnimations()
        transitionImageView.isHidden = true
        transitionImageView.image = nil
        resetImageGeometry()
        detailedIndex = nil
        detailFailed = false
        fittedIndex = nil
        fittedPixelLimit = 0
        zoomReadyIndex = nil
        lastSampledIndex = nil
        scrubDirection = 0
        pausedDetailIndex = nil
        lastScrubInputTime = CACurrentMediaTime()
        scrubTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.sampleScrubPreview() }
        RunLoop.main.add(timer, forMode: .common)
        scrubTimer = timer
        updateDisplayedIdentity()
    }

    @objc private func endScrubbing() {
        guard scrubbing else { return }
        displayImage(at: currentIndex, animated: false, navigationStep: 0)
    }

    private func sampleScrubPreview() {
        guard scrubbing, !didReportClose else { return }
        let index = currentIndex
        if lastSampledIndex == index {
            if CACurrentMediaTime() - lastScrubInputTime >= 0.15, pausedDetailIndex != index {
                pausedDetailIndex = index
                let generation = selectionGeneration
                imagePipeline.invalidateDetails()
                imagePipeline.load(page: index, url: imageUrls[index], previewURL: nil, kind: .viewport,
                                   viewportPixels: viewportPixels) { [weak self] page, image in
                    guard let self, self.scrubbing, self.currentIndex == page,
                          generation == self.selectionGeneration, let image else { return }
                    self.fittedIndex = page
                    self.fittedPixelLimit = self.viewportPixels
                    self.applyCurrentImage(image, page: page, preserveGeometry: self.displayedIndex == page)
                }
            }
            return
        }
        let sampledAt = CACurrentMediaTime()
        lastSampledIndex = index
        imagePipeline.load(page: index, url: imageUrls[index], previewURL: previewURLs[imageUrls[index]],
                           kind: .preview, viewportPixels: viewportPixels) { [weak self] page, image in
            guard let self, self.scrubbing, self.fittedIndex != self.currentIndex,
                  CACurrentMediaTime() - sampledAt <= 0.15 else { return }
            // Publish completed samples even while the target advances. The explicit
            // preview label tells the truth without starving a continuous drag.
            self.applyCurrentImage(image, page: page)
        }
    }

    @objc private func sliderValueChanged(_ sender: UISlider) {
        let newIndex = Int(sender.value.rounded())
        guard !sortingPages, imageUrls.indices.contains(newIndex), newIndex != currentIndex else { return }
        guard scrubbing else {
            // Programmatic jumps have no touch lifecycle.
            displayImage(at: newIndex, animated: false, navigationStep: 0)
            return
        }
        let direction = newIndex > currentIndex ? 1 : -1
        if scrubDirection != 0 && direction != scrubDirection {
            imagePipeline.invalidatePreviews()
            lastSampledIndex = nil
        }
        scrubDirection = direction
        lastScrubInputTime = CACurrentMediaTime()
        pausedDetailIndex = nil
        currentIndex = newIndex
        imageQuarterTurns = 0; rotationPageURL = imageUrls[newIndex]
        fittedIndex = nil
        fittedPixelLimit = 0
        zoomReadyIndex = nil
        onPositionChange?(imageUrls[newIndex], newIndex)
        updatePageNumber()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        toggleChrome()
    }

    private func publishReaderUI() {
        guard sharedChromeView != nil else { return }
        onReaderUIChanged?(["page": imageUrls.isEmpty ? 0 : currentIndex + 1, "count": imageUrls.count,
            "displayedPage": displayedIndex.map { $0 + 1 } as Any? ?? NSNull(), "controls": chromeVisible,
            "sorting": sortingPages, "failed": displayedIndex == nil && unavailableImageLabel.text == "This image could not be opened.",
            "detailFailed": detailFailed])
    }

    func performSharedAction(_ action: String, page: Int?, scrubbing requestedScrub: Bool) {
        guard isViewLoaded, !didReportClose else { return }
        switch action {
        case "seek":
            guard let page, imageUrls.indices.contains(page - 1), !sortingPages else { return }
            if requestedScrub {
                if !scrubbing { beginScrubbing() }
                slider.value = Float(page - 1)
                sliderValueChanged(slider)
            } else {
                if scrubbing { slider.value = Float(page - 1); sliderValueChanged(slider); endScrubbing() }
                else { navigate(to: page - 1) }
            }
        case "showControls": setChromeVisible(true)
        case "toggleControls": toggleChrome()
        case "retry": displayImage(at: currentIndex, animated: false, navigationStep: 0)
        case "rotateCounterclockwise": rotateCounterclockwise()
        case "rotateClockwise": rotateClockwise()
        case "retryDetail": scrollViewWillBeginZooming(scrollView, with: imageView)
        default: break
        }
    }

    @objc private func rotateCounterclockwise() { rotateImage(by: -1) }
    @objc private func rotateClockwise() { rotateImage(by: 1) }

    private func rotateImage(by step: Int) {
        guard appliedPreferences?.showRotationButtons == true, !sortingPages, !scrubbing,
              displayedIndex == currentIndex, transitionImageView.isHidden, let sourceImage else { return }
        imageQuarterTurns = (imageQuarterTurns + step + 4) % 4
        resetImageGeometry()
        imageView.image = sourceImage.rotatedQuarterTurns(imageQuarterTurns)
        updateDisplayedIdentity()
    }

    func navigate(to index: Int) {
        guard !sortingPages, index != currentIndex, imageUrls.indices.contains(index) else { return }
        displayImage(at: index, animated: false, navigationStep: index > currentIndex ? 1 : -1)
    }

    @objc private func promptForPageNumber() {
        if sharedChromeView != nil { onReaderToolRequested?("jump"); return }
        guard !imageUrls.isEmpty, !sortingPages, presentedViewController == nil else { return }
        let form = PageJumpViewController(pageCount: imageUrls.count, currentIndex: currentIndex)
        form.onSelect = { [weak self] index in self?.navigate(to: index) }
        presentTool(form)
    }

    @objc private func showPages() {
        if sharedChromeView != nil { onReaderToolRequested?("pages"); return }
        guard !imageUrls.isEmpty, !sortingPages, presentedViewController == nil else { return }
        let pages = PageOverviewViewController(urls: imageUrls, currentIndex: currentIndex, thumbnailSize: appliedPreferences?.thumbnailSize ?? 0.25)
        pages.previewURLs = previewURLs
        pages.retainImageWork = retainImageWork
        pages.onSelect = { [weak self] index in self?.navigate(to: index) }
        overview = pages
        presentTool(pages)
    }

    private func presentTool(_ controller: UIViewController) {
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        navigation.preferredContentSize = controller.preferredContentSize
        present(navigation, animated: true)
    }

    private func updateRotationAccessibilityValue() {
        guard imageQuarterTurns != 0, displayedIndex == currentIndex, !scrubbing else { return }
        scrollView.accessibilityValue = "Page \(currentIndex + 1) of \(imageUrls.count), image rotated \(imageQuarterTurns * 90) degrees clockwise, zoom \(Int((scrollView.zoomScale * 100).rounded())) percent"
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { updateRotationAccessibilityValue() }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Handles rotation and iPad window resizing after the final bounds exist.
        if viewportSize != scrollView.bounds.size {
            viewportSize = scrollView.bounds.size
            let incomingImage = transitionImageView.isHidden ? nil : transitionImageView.image
            imageView.layer.removeAllAnimations()
            transitionImageView.layer.removeAllAnimations()
            transitionImageView.isHidden = true
            transitionImageView.image = nil
            resetImageGeometry()
            if let incomingImage { applyCurrentImage(incomingImage, page: currentIndex) }
            upgradeViewportIfNeeded()
        }
    }

    private func upgradeViewportIfNeeded() {
        guard !didReportClose, !scrubbing, fittedIndex == currentIndex,
              zoomReadyIndex != currentIndex, detailedIndex != currentIndex,
              viewportPixels > fittedPixelLimit else { return }
        let index = currentIndex
        let generation = selectionGeneration
        let requestedPixels = viewportPixels
        imagePipeline.invalidateDetails()
        imagePipeline.load(page: index, url: imageUrls[index], previewURL: nil, kind: .viewport,
                           viewportPixels: requestedPixels) { [weak self] page, image in
            guard let self, generation == self.selectionGeneration, let image else { return }
            self.fittedIndex = page
            self.fittedPixelLimit = requestedPixels
            self.applyCurrentImage(image, page: page, preserveGeometry: true)
            self.preloadAdjacentImages(around: page, generation: generation)
        }
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        guard !scrubbing, displayedIndex == currentIndex, detailedIndex != currentIndex else { return }
        let index = currentIndex
        let generation = selectionGeneration
        detailedIndex = index
        detailFailed = false
        publishReaderUI()
        imagePipeline.invalidateDetails()
        imagePipeline.load(page: index, url: imageUrls[index], previewURL: nil, kind: .detail,
                           viewportPixels: viewportPixels) { [weak self] page, image in
            guard let self, generation == self.selectionGeneration else { return }
            guard let image else { self.detailedIndex = nil; self.detailFailed = true; self.publishReaderUI(); return }
            self.zoomReadyIndex = page
            self.applyCurrentImage(image, page: page, preserveGeometry: true)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        suppressPrefetch = true
        imagePipeline.clearCache()
        // Keep the selected page's queued viewport/zoom request. Dropping it
        // would leave only the preview visible until another navigation event.
        imagePipeline.details.dropPending(exceptPage: currentIndex)
    }

    deinit { scrubTimer?.invalidate() }

}


extension UIImage {
    /// Compose with EXIF orientation without allocating another full-size bitmap.
    func rotatedQuarterTurns(_ turns: Int) -> UIImage {
        guard let cgImage else { return self }
        let cycles: [[UIImage.Orientation]] = [
            [.up, .right, .down, .left],
            [.upMirrored, .rightMirrored, .downMirrored, .leftMirrored]
        ]
        guard let cycle = cycles.first(where: { $0.contains(imageOrientation) }),
              let index = cycle.firstIndex(of: imageOrientation) else { return self }
        return UIImage(cgImage: cgImage, scale: scale, orientation: cycle[(index + (turns % 4) + 4) % 4])
    }
}
