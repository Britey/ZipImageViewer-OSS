import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import JPEGXLBridge
import os

/// Processes only disposable extraction staging. Originals are removed only after
/// their replacement has been finalized, natively decoded and measured on disk.
struct ExtractedImageProcessor: ExtractedImagePreparing {
    private let manager = FileManager.default
    private static let maximumPixels = 32_000_000
    // Admission is per phase, with room left for UIKit and other app work. This is
    // an estimate, not a process RSS guarantee; ImageIO owns its decoder scratch.
    static let maximumWorkingBytes = 1536 * 1024 * 1024
    static let jpegCodecBudget = 1280 * 1024 * 1024
    static let pixelCodecBudget = 384 * 1024 * 1024
    static let pixelWorkingBudget = 512 * 1024 * 1024
    private let availableMemory: () -> Int
    /// Optional instrumentation for codec-managed peak allocations, excluding caller buffers.
    var observeCodecMemory: ((Int) -> Void)?

    init(availableMemory: @escaping () -> Int = { availableProcessMemory() }) {
        self.availableMemory = availableMemory
    }

    static func availableProcessMemory() -> Int {
        #if targetEnvironment(simulator)
        // Simulator does not supply the device jetsam allowance. Exercise the
        // same fixed ceiling here; pressure behavior is tested via injection.
        return Int.max
        #else
        return Int(clamping: os_proc_available_memory())
        #endif
    }

    private var phaseBudget: Int {
        min(Self.maximumWorkingBytes, max(0, availableMemory() - 64 * 1024 * 1024))
    }

    private func permitsPhase(bytes: Int) -> Bool { bytes <= phaseBudget }

    private func codecBudget(pixels: Int, inputBytes: Int, jpeg: Bool) -> Int? {
        // JPEG uses compressed input/output plus coefficient vectors (libjxl uses
        // standard allocations for those, outside our custom allocator). Allow
        // 8 bytes/pixel for 4:4:4 coefficients/padding, not PNG's decoded buffers.
        // PNG's CGImage/context are already released; only packed RGB survives.
        let callerBytes = (jpeg ? pixels * 8 + inputBytes * 2 : pixels * 3 + inputBytes) + 16 * 1024 * 1024
        let workingBudget = jpeg ? phaseBudget : min(Self.pixelWorkingBudget, phaseBudget)
        let budget = min(jpeg ? Self.jpegCodecBudget : Self.pixelCodecBudget, workingBudget - callerBytes)
        return budget >= 128 * 1024 * 1024 ? budget : nil
    }
    private static let maximumInputBytes = 128 * 1024 * 1024

    func prepare(images: [URL], imageRoot: URL, compress: Bool,
                 cancellation: (() throws -> Void)? = nil,
                 progress: ((Double) -> Void)? = nil) throws -> [ArchivePreparedPage] {
        let requestedRoot = imageRoot.standardizedFileURL
        let root = requestedRoot.resolvingSymlinksInPath()
        let rootValues = try requestedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else {
            throw ArchiveImportError.unsafeOutput(imageRoot.path)
        }
        // Validate the entire input list before creating anything or deleting a source.
        var paths = Set<String>()
        let originals = try images.map { image -> (URL, String, URLResourceValues) in
            try cancellation?()
            let requestedFile = image.standardizedFileURL
            let pathRoot: URL
            if requestedFile.path.hasPrefix(requestedRoot.path + "/") {
                pathRoot = requestedRoot
            } else if requestedFile.path.hasPrefix(root.path + "/") {
                pathRoot = root
            } else {
                throw ArchiveImportError.unsafeOutput(image.path)
            }
            let path = String(requestedFile.path.dropFirst(pathRoot.path.count + 1))
            let file = root.appendingPathComponent(path)
            guard requestedFile.resolvingSymlinksInPath() == file else {
                throw ArchiveImportError.unsafeOutput(image.path)
            }
            guard paths.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ArchiveImportError.unsafeOutput(path)
            }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .creationDateKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? -1) >= 0 else {
                throw ArchiveImportError.unsafeOutput(path)
            }
            return (file, path, values)
        }
        guard !originals.isEmpty else { progress?(1); return [] }
        let generatedName = ".ziv-prepared-" + UUID().uuidString
        let generated = root.appendingPathComponent(generatedName, isDirectory: true)
        // withIntermediateDirectories:false also rejects an existing collision.
        try manager.createDirectory(at: generated, withIntermediateDirectories: false)
        var pages: [ArchivePreparedPage] = []
        for (index, original) in originals.enumerated() {
            try cancellation?()
            let page = try autoreleasepool {
                try prepareOne(original.0, relativePath: original.1, values: original.2,
                               generated: generated, generatedName: generatedName,
                               index: index, compress: compress, cancellation: cancellation)
            }
            pages.append(page)
            progress?(Double(index + 1) / Double(originals.count))
        }
        try cancellation?()
        if try manager.contentsOfDirectory(atPath: generated.path).isEmpty { try manager.removeItem(at: generated) }
        return pages
    }

    private func prepareOne(_ file: URL, relativePath: String, values: URLResourceValues,
                            generated: URL, generatedName: String, index: Int, compress: Bool,
                            cancellation: (() throws -> Void)?) throws -> ArchivePreparedPage {
        var result = ArchivePreparedPage(originalRelativePath: relativePath, storedRelativePath: relativePath,
                                         previewRelativePath: nil, creationDate: values.creationDate,
                                         modificationDate: values.contentModificationDate)
        let size = values.fileSize ?? 0
        guard size > 0, size <= Self.maximumInputBytes,
              let info = Self.imageInformation(file) else { return result }
        let width = info.width, height = info.height
        let pixels = width * height
        let preview = generated.appendingPathComponent("\(index).preview.jpg")
        try cancellation?()
        if permitsPhase(bytes: pixels * 8 + size + 4 * 1024 * 1024),
           let bytes = autoreleasepool(invoking: { Self.previewData(file) }) {
            try bytes.write(to: preview, options: .atomic)
            result.previewRelativePath = generatedName + "/" + preview.lastPathComponent
        }
        try cancellation?()
        guard compress, size >= 16 * 1024, info.depth <= 8,
              info.type == UTType.jpeg.identifier || info.type == UTType.png.identifier,
              (CGImageSourceCopyTypeIdentifiers() as! [String]).contains("public.jpeg-xl") else { return result }
        let candidate = generated.appendingPathComponent("\(index).jxl")
        // Each stage has its own autorelease scope. Encoded buffers and encoder
        // allocations are gone before native candidate validation starts.
        let wroteCandidate = try autoreleasepool {
            let encoded: Data?
            if info.type == UTType.jpeg.identifier {
                encoded = try repackJPEGFile(file, size: size, pixels: pixels)
            } else {
                encoded = encodePNGFile(file, width: width, height: height,
                                        orientation: info.orientation, capacity: size)
            }
            try cancellation?()
            guard let encoded else { return false }
            try encoded.write(to: candidate, options: .atomic)
            return true
        }
        guard wroteCandidate else { return result }
        guard permitsPhase(bytes: pixels * 8 + size + 16 * 1024 * 1024),
              autoreleasepool(invoking: { Self.validReplacement(candidate, width: width, height: height,
                                                               orientation: Int(info.orientation)) }) else {
            try manager.removeItem(at: candidate)
            return result
        }
        try cancellation?()
        let candidateValues = try candidate.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        let previewValues = result.previewRelativePath == nil ? nil : try preview.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        let retainedBytes = (candidateValues.fileSize ?? Int.max / 2) + (previewValues?.fileSize ?? 0)
        let originalAllocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize
        let candidateAllocated = candidateValues.totalFileAllocatedSize ?? candidateValues.fileAllocatedSize
        let previewAllocated = previewValues?.totalFileAllocatedSize ?? previewValues?.fileAllocatedSize ?? 0
        guard size - retainedBytes >= max(16 * 1024, Int(ceil(Double(size) * 0.05))),
              let originalAllocated, let candidateAllocated,
              candidateAllocated + previewAllocated <= originalAllocated else {
            try manager.removeItem(at: candidate)
            return result
        }
        // Preserve dates independently of the physical cache filename.
        try manager.removeItem(at: file)
        result = ArchivePreparedPage(originalRelativePath: relativePath,
                                     storedRelativePath: generatedName + "/" + candidate.lastPathComponent,
                                     previewRelativePath: result.previewRelativePath,
                                     creationDate: values.creationDate, modificationDate: values.contentModificationDate,
                                     processingPolicy: info.type == UTType.jpeg.identifier
                                        ? "libjxl-0.13.0-jpeg-repack-v1" : "libjxl-0.13.0-png-d0.5-e3-stream-v2")
        return result
    }

    private struct ImageInformation {
        let width: Int, height: Int, depth: Int
        let orientation: UInt32
        let type: String
    }

    private static func imageInformation(_ file: URL) -> ImageInformation? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let type = CGImageSourceGetType(source) as String?,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0, width <= maximumPixels / height else { return nil }
            return ImageInformation(width: width, height: height,
                                    depth: (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8,
                                    orientation: (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1,
                                    type: type)
        }
    }

    private static func previewData(_ file: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 384,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return jpegPreview(thumbnail)
    }

    private func repackJPEGFile(_ file: URL, size: Int, pixels: Int) throws -> Data? {
        guard let budget = codecBudget(pixels: pixels, inputBytes: size, jpeg: true) else { return nil }
        return Self.repackJPEG(try Data(contentsOf: file, options: .mappedIfSafe), capacity: size,
                               memoryLimit: budget, observeMemory: observeCodecMemory)
    }

    private static func jpegPreview(_ image: CGImage) -> Data? {
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: color,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flattened = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func repackJPEG(_ source: Data, capacity: Int, memoryLimit: Int = jpegCodecBudget,
                           observeMemory: ((Int) -> Void)? = nil) -> Data? {
        guard !source.isEmpty, capacity > 0, capacity <= maximumInputBytes else { return nil }
        var output = Data(count: capacity)
        var peak = 0
        defer { observeMemory?(peak) }
        let count = output.withUnsafeMutableBytes { outputBytes in
            source.withUnsafeBytes { inputBytes in
                ziv_jxl_repack_jpeg(inputBytes.bindMemory(to: UInt8.self).baseAddress, source.count,
                                   outputBytes.bindMemory(to: UInt8.self).baseAddress, capacity, memoryLimit, &peak)
            }
        }
        guard count > 0 else { return nil }
        output.count = count
        return output
    }

    private func encodePNGFile(_ file: URL, width: Int, height: Int,
                               orientation: UInt32, capacity: Int) -> Data? {
        let pixels = width * height
        // Source bitmap, flattened context, packed RGB and row alignment headroom.
        guard pixels * 12 + capacity + 16 * 1024 * 1024 <= min(Self.pixelWorkingBudget, phaseBudget),
              let packed = autoreleasepool(invoking: { Self.pngPixels(file, width: width, height: height) }),
              let budget = codecBudget(pixels: pixels, inputBytes: capacity, jpeg: false) else { return nil }
        return Self.encodePixels(packed.rgb, icc: packed.icc, width: width, height: height,
                                 orientation: orientation, capacity: capacity, memoryLimit: budget, observeMemory: observeCodecMemory)
    }

    private static func pngPixels(_ file: URL, width: Int, height: Int) -> (rgb: Data, icc: Data)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.bitsPerComponent <= 8, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        // Keep an RGB source's profile (including Display P3); grayscale is rendered
        // into sRGB. Alpha is composited onto white in the chosen color space.
        guard let color = image.colorSpace?.model == .rgb ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: color,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let bitmap = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgb = Data(count: width * height * 3)
        rgb.withUnsafeMutableBytes { bytes in
            let target = bytes.bindMemory(to: UInt8.self)
            for pixel in 0..<(width * height) {
                target[pixel * 3] = bitmap[pixel * 4]
                target[pixel * 3 + 1] = bitmap[pixel * 4 + 1]
                target[pixel * 3 + 2] = bitmap[pixel * 4 + 2]
            }
        }
        let icc = color.copyICCData() as Data? ?? Data()
        return (rgb, icc)
    }

    private static func encodePixels(_ rgb: Data, icc: Data, width: Int, height: Int,
                                     orientation: UInt32, capacity: Int, memoryLimit: Int,
                                     observeMemory: ((Int) -> Void)?) -> Data? {
        var output = Data(count: capacity)
        var peak = 0
        defer { observeMemory?(peak) }
        let count = output.withUnsafeMutableBytes { out in
            rgb.withUnsafeBytes { input in
                icc.withUnsafeBytes { profile in
                    ziv_jxl_encode_rgb(input.bindMemory(to: UInt8.self).baseAddress, UInt32(width), UInt32(height),
                                       orientation, profile.bindMemory(to: UInt8.self).baseAddress, icc.count,
                                       out.bindMemory(to: UInt8.self).baseAddress, capacity, memoryLimit, &peak)
                }
            }
        }
        guard count > 0 else { return nil }
        output.count = count
        return output
    }

    private static func validReplacement(_ url: URL, width: Int, height: Int, orientation: Int) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return false }
        let storedOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return image.width == width && image.height == height && storedOrientation == orientation
    }
}
