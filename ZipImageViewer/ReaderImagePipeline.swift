import UIKit
import ImageIO

/// Main-thread scheduler: one active decode and one replaceable pending request.
/// Obsolete work may finish but can never publish into a newer interaction epoch.
final class LatestImageRequestScheduler {
    struct Request {
        let page: Int
        let epoch: Int
        let work: (@escaping (UIImage?) -> Void) -> Void
        let completion: (Int, UIImage?) -> Void
    }
    private var active = false
    private var pending: Request?
    private(set) var epoch = 0
    private(set) var closed = false
    var pendingCount: Int { pending == nil ? 0 : 1 }
    func invalidate() { epoch += 1; pending = nil }
    func dropPending(exceptPage page: Int? = nil) {
        if page == nil || pending?.page != page { pending = nil }
    }
    func close() { closed = true; invalidate() }
    func submit(page: Int, work: @escaping (@escaping (UIImage?) -> Void) -> Void,
                completion: @escaping (Int, UIImage?) -> Void) {
        guard !closed else { return }
        let request = Request(page: page, epoch: epoch, work: work, completion: completion)
        if active { pending = request } else { start(request) }
    }
    private func start(_ request: Request) {
        active = true
        request.work { [weak self] image in
            guard let self else { return }
            // Stay active while publishing: reentrant requests replace the old
            // pending target instead of starting ahead of it and resurrecting it.
            if !self.closed && request.epoch == self.epoch { request.completion(request.page, image) }
            self.active = false
            if let next = self.pending { self.pending = nil; self.start(next) }
        }
    }
}

/// Decoding and bitmap preparation stay off the main thread. Separate serial lanes
/// keep a slow detailed image from blocking slider previews. Resident cache budgets
/// are explicit; each detailed decode is capped to a 32 MiB output bitmap.
final class ReaderImagePipeline {
    enum Kind { case preview, viewport, detail }
    let previews = LatestImageRequestScheduler()
    let details = LatestImageRequestScheduler()
    private let previewQueue = DispatchQueue(label: "reader.preview", qos: .userInitiated)
    private let detailQueue = DispatchQueue(label: "reader.detail", qos: .userInitiated)
    private struct Entry { let image: UIImage; let cost: Int }
    private var cache: [String: Entry] = [:]
    private var recency: [String] = []
    private(set) var cachedBytes = 0
    let cacheBudget = 48 * 1024 * 1024
    private var cacheGeneration = 0
    private var closed = false
    var retainImageWork: (() -> (() -> Void))?

    func invalidatePreviews() { previews.invalidate() }
    func invalidateDetails() { details.invalidate() }
    func close() { closed = true; previews.close(); details.close(); clearCache() }
    func clearCache() { cacheGeneration += 1; cache.removeAll(); recency.removeAll(); cachedBytes = 0 }

    func load(page: Int, url: URL, previewURL: URL?, kind: Kind, viewportPixels: Int,
              completion: @escaping (Int, UIImage?) -> Void) {
        guard !closed else { return }
        let maxPixels: Int
        switch kind { case .preview: maxPixels = 384; case .viewport: maxPixels = min(3072, max(384, viewportPixels)); case .detail: maxPixels = 16384 }
        let source = kind == .preview ? previewURL ?? url : url
        let key = "\(source.path)|\(maxPixels)"
        let scheduler = kind == .preview ? previews : details
        let queue = kind == .preview ? previewQueue : detailQueue
        scheduler.submit(page: page, work: { [weak self] done in
            guard let self, !self.closed else { done(nil); return }
            if let entry = self.cache[key] {
                self.recency.removeAll { $0 == key }; self.recency.append(key)
                done(entry.image)
                return
            }
            let release = self.retainImageWork?()
            let generation = self.cacheGeneration
            queue.async {
                let image = autoreleasepool {
                    Self.decode(source, maximumPixels: maxPixels)
                        ?? (source != url ? Self.decode(url, maximumPixels: maxPixels) : nil)
                }
                release?()
                DispatchQueue.main.async { [weak self] in
                    if let self, !self.closed, generation == self.cacheGeneration, let image { self.insert(image, key: key) }
                    done(image)
                }
            }
        }, completion: completion)
    }
    private func insert(_ image: UIImage, key: String) {
        guard let cg = image.cgImage else { return }
        let cost = cg.bytesPerRow * cg.height
        guard cost <= cacheBudget else { return }
        if let previous = cache.removeValue(forKey: key) { cachedBytes -= previous.cost }
        recency.removeAll { $0 == key }
        while cachedBytes + cost > cacheBudget, let first = recency.first {
            recency.removeFirst()
            if let removed = cache.removeValue(forKey: first) { cachedBytes -= removed.cost }
        }
        cache[key] = Entry(image: image, cost: cost); recency.append(key); cachedBytes += cost
    }
    static func decode(_ url: URL, maximumPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let w = width.doubleValue, h = height.doubleValue
        guard Self.isSupportedSource(width: w, height: h) else { return nil }
        // Leave headroom for row alignment. Codec-internal scratch allocations are
        // implementation dependent; never decode several detailed pages at once.
        let pixelBudget = Double(30 * 1024 * 1024 / 4)
        let scale = min(1, sqrt(pixelBudget / (w * h)))
        let bound = max(1, min(maximumPixels, Int(ceil(max(w, h) * scale))))
        let outputScale = min(1, Double(bound) / max(w, h))
        // Include an eight-byte source bitmap (16-bit RGBA) and two RGBA8
        // destination buffers. ImageIO codec scratch remains OS-dependent.
        let estimate = Int(ceil(w * h * 8 + w * h * outputScale * outputScale * 8))
        guard ReaderDecodeMemory.shared.acquire(bytes: estimate) else { return nil }
        defer { ReaderDecodeMemory.shared.release(bytes: estimate) }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: bound,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { return nil }
        // Force pixels before handing an image to UIKit; preserve the source color
        // space where possible (including wide gamut pages).
        let space = cg.colorSpace?.model == .rgb ? cg.colorSpace! : CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let prepared = prepare(cg, context: context) else {
            return UIImage(cgImage: cg)
        }
        return UIImage(cgImage: prepared)
    }
    static func isSupportedSource(width: Double, height: Double) -> Bool {
        width > 0 && height > 0 && width.isFinite && height.isFinite
            && width <= 100_000 && height <= 100_000 && width * height <= 32_000_000
    }
    private static func prepare(_ image: CGImage, context: CGContext) -> CGImage? {
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

/// Shared by reader lanes and overview loaders. Admission waits only on workers;
/// callers never synchronously drain them when navigating or closing the reader.
private final class ReaderDecodeMemory {
    static let shared = ReaderDecodeMemory()
    private let condition = NSCondition()
    private var usedBytes = 0
    private let maximumBytes = 384 * 1024 * 1024
    func acquire(bytes: Int) -> Bool {
        guard bytes > 0, bytes <= maximumBytes else { return false }
        condition.lock()
        while usedBytes + bytes > maximumBytes { condition.wait() }
        usedBytes += bytes
        condition.unlock()
        return true
    }
    func release(bytes: Int) {
        condition.lock(); usedBytes -= bytes; condition.broadcast(); condition.unlock()
    }
}
