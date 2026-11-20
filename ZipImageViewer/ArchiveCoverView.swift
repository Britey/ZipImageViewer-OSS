import UIKit
import ImageIO

/// A decorative Fabric cover. No source grants, paths or image bytes enter JavaScript.
@objc(ArchiveCoverView)
final class ArchiveCoverView: UIImageView {
    private var generation = 0
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    private var operation: Operation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFit
        tintColor = .secondaryLabel
        isAccessibilityElement = false
        reset()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func setSource(_ archiveID: String, readerID: String, pageIndex: Int) {
        reset()
        let token = generation
        let store = NativeAppService.shared.cacheStore
        let readerSource = readerID.isEmpty ? nil : NativeAppService.shared.thumbnailSource(readerID: readerID, index: pageIndex)
        let id = UUID(uuidString: archiveID)
        guard readerSource != nil || id != nil else { return }
        let job = BlockOperation()
        job.addExecutionBlock { [weak self, weak job] in
            // The source token also releases on deinit if cancellation skips this block.
            defer { readerSource?.1() }
            guard let job, !job.isCancelled else { return }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 600, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true]
            var image: UIImage?
            if let readerSource {
                for url in readerSource.0 {
                    guard !job.isCancelled else { return }
                    if let decoded = ReaderImagePipeline.decode(url, maximumPixels: 600) { image = decoded; break }
                }
            } else if let id, let data = try? store.thumbnailData(id: id),
                      let source = CGImageSourceCreateWithData(data as CFData, nil) {
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
            }
            guard let image, !job.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == token, !job.isCancelled else { return }
                self.image = image
            }
        }
        operation = job
        Self.queue.addOperation(job)
    }

    @objc func reset() {
        generation += 1
        operation?.cancel(); operation = nil
        image = UIImage(systemName: "photo")
    }
    deinit { operation?.cancel() }
}
