import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import JPEGXLBridge
import Darwin
@testable import ZipImageViewer

final class ExtractedImageProcessorTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func fixture(type: UTType, orientation: Int = 1, width: Int = 1024, height: Int = 768, fullNoise: Bool = false) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bytes = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        var random: UInt32 = 42
        for y in 0..<height {
            for x in 0..<width {
                random = random &* 1664525 &+ 1013904223
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(clamping: (x % 1024) / 5 + Int(random >> 28))
                bytes[offset + 1] = UInt8(clamping: (y % 768) / 4 + Int(random >> 28))
                bytes[offset + 2] = UInt8(clamping: ((x % 1024) + (y % 768)) / 9 + Int(random >> 28))
                if fullNoise {
                    bytes[offset] = UInt8(truncatingIfNeeded: random >> 24)
                    bytes[offset + 1] = UInt8(truncatingIfNeeded: random >> 16)
                    bytes[offset + 2] = UInt8(truncatingIfNeeded: random >> 8)
                }
                bytes[offset + 3] = 255
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: orientation
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testJPEGRepackingReconstructsExactOriginalBytes() throws {
        let original = try fixture(type: .jpeg)
        let encoded = try XCTUnwrap(ExtractedImageProcessor.repackJPEG(original, capacity: original.count))
        XCTAssertLessThan(encoded.count, original.count)
        var reconstructed = Data(count: original.count)
        let count = reconstructed.withUnsafeMutableBytes { output in
            encoded.withUnsafeBytes { input in
                ziv_jxl_reconstruct_jpeg(input.bindMemory(to: UInt8.self).baseAddress, encoded.count,
                                         output.bindMemory(to: UInt8.self).baseAddress, original.count)
            }
        }
        XCTAssertEqual(count, original.count)
        XCTAssertEqual(reconstructed, original)
    }

    func testCompressionOffRetainsBytesAndBuildsSmallPreview() throws {
        let root = try directory()
        let file = root.appendingPathComponent("page.png")
        let original = try fixture(type: .png)
        try original.write(to: file)
        let pages = try ExtractedImageProcessor().prepare(images: [file], imageRoot: root, compress: false)
        XCTAssertEqual(pages[0].originalRelativePath, "page.png")
        XCTAssertEqual(pages[0].storedRelativePath, "page.png")
        XCTAssertEqual(try Data(contentsOf: file), original)
        let preview = root.appendingPathComponent(try XCTUnwrap(pages[0].previewRelativePath))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(preview as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(image.width, image.height), 384)
    }

    func testLargeJPEGsActuallyRepackAndReconstructExactly() throws {
        for (width, height) in [(4000, 3000), (6000, 4000), (8000, 4000)] {
            try autoreleasepool { try verifyLargeImage(type: .jpeg, width: width, height: height) }
        }
    }

    func testLargePNGsActuallyEncodeAtOriginalDimensions() throws {
        for (width, height) in [(4000, 3000), (6000, 4000), (8000, 4000)] {
            try autoreleasepool { try verifyLargeImage(type: .png, width: width, height: height) }
        }
    }

    func test24MegapixelPNGAboveOldFileSizeLimitActuallyEncodes() throws {
        try autoreleasepool { try verifyLargeImage(type: .png, width: 6000, height: 4000, fullNoise: true) }
    }

    private func verifyLargeImage(type: UTType, width: Int, height: Int, fullNoise: Bool = false) throws {
        let root = try directory()
        let file = root.appendingPathComponent("large." + (type == .jpeg ? "jpg" : "png"))
        let original = try autoreleasepool { try fixture(type: type, width: width, height: height, fullNoise: fullNoise) }
        if fullNoise { XCTAssertGreaterThan(original.count, 64 * 1024 * 1024) }
        try original.write(to: file)
        var peak = 0
        var processor = ExtractedImageProcessor()
        processor.observeCodecMemory = { peak = $0 }
        let started = Date()
        let page = try XCTUnwrap(processor.prepare(images: [file], imageRoot: root, compress: true).first)
        guard page.storedRelativePath.hasSuffix(".jxl") else {
            return XCTFail("\(type) \(width)x\(height) must actually compress; codec peak \(peak)")
        }
        let stored = root.appendingPathComponent(page.storedRelativePath)
        let encoded = try Data(contentsOf: stored)
        let preview = root.appendingPathComponent(try XCTUnwrap(page.previewRelativePath))
        XCTAssertLessThan(encoded.count + (try Data(contentsOf: preview).count), original.count)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(stored as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, width)
        XCTAssertEqual((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, height)
        XCTAssertNotNil(ReaderImagePipeline.decode(stored, maximumPixels: 3072), "The reader must reopen the converted page")
        if type == .jpeg {
            var restored = Data(count: original.count)
            let count = restored.withUnsafeMutableBytes { output in
                encoded.withUnsafeBytes { input in
                    ziv_jxl_reconstruct_jpeg(input.bindMemory(to: UInt8.self).baseAddress, encoded.count,
                                            output.bindMemory(to: UInt8.self).baseAddress, original.count)
                }
            }
            XCTAssertEqual(count, original.count)
            XCTAssertEqual(restored, original)
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("LARGE_IMAGE fullNoise=\(fullNoise) processHighWaterBytes=\(usage.ru_maxrss) type=\(type.identifier) pixels=\(width * height) originalBytes=\(original.count) storedBytes=\(encoded.count) codecPeakBytes=\(peak) elapsedSeconds=\(Date().timeIntervalSince(started))")
    }

    func testLowMemoryRetainsOriginalAndDoesNotEnterEncoder() throws {
        let root = try directory()
        let file = root.appendingPathComponent("page.jpg")
        let original = try fixture(type: .jpeg)
        try original.write(to: file)
        var processor = ExtractedImageProcessor(availableMemory: { 64 * 1024 * 1024 })
        processor.observeCodecMemory = { _ in XCTFail("Low-memory imports must not enter encoder") }
        let page = try XCTUnwrap(processor.prepare(images: [file], imageRoot: root, compress: true).first)
        XCTAssertEqual(page.storedRelativePath, "page.jpg")
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testMemoryPressureBetweenPreviewAndEncodingKeepsOriginalAndPreview() throws {
        let root = try directory()
        let file = root.appendingPathComponent("page.jpg")
        let original = try fixture(type: .jpeg)
        try original.write(to: file)
        var checks = 0
        var processor = ExtractedImageProcessor(availableMemory: {
            checks += 1
            return checks == 1 ? Int.max : 0
        })
        processor.observeCodecMemory = { _ in XCTFail("Must recheck pressure before encoding") }
        let page = try XCTUnwrap(processor.prepare(images: [file], imageRoot: root, compress: true).first)
        XCTAssertEqual(page.storedRelativePath, "page.jpg")
        XCTAssertNotNil(page.previewRelativePath)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testChunkedPNGOutputNeverWritesPastCapacity() {
        let input = [UInt8](repeating: 127, count: 64 * 64 * 3)
        var output = [UInt8](repeating: 0xA5, count: 33)
        let count = input.withUnsafeBufferPointer { rgb in
            output.withUnsafeMutableBufferPointer { bytes in
                ziv_jxl_encode_rgb(rgb.baseAddress, 64, 64, 1, nil, 0,
                                   bytes.baseAddress, 1, ExtractedImageProcessor.pixelCodecBudget, nil)
            }
        }
        XCTAssertEqual(count, 0)
        XCTAssertTrue(output.dropFirst().allSatisfy { $0 == 0xA5 })
    }

    func testCodecAllocationFailureReturnsWithoutChangingInput() throws {
        let original = try fixture(type: .jpeg)
        let copy = original
        XCTAssertNil(ExtractedImageProcessor.repackJPEG(original, capacity: original.count, memoryLimit: 1024))
        XCTAssertEqual(original, copy)
    }

    func testJPEGCompressionRetainsOrientationAndReconstructsOriginalFromStoredPage() throws {
        let root = try directory()
        let file = root.appendingPathComponent("page.jpg")
        let original = try fixture(type: .jpeg, orientation: 8)
        try original.write(to: file)
        let pages = try ExtractedImageProcessor().prepare(images: [file], imageRoot: root, compress: true)
        XCTAssertTrue(pages[0].storedRelativePath.hasSuffix(".jxl"))
        XCTAssertEqual(pages[0].processingPolicy, "libjxl-0.13.0-jpeg-repack-v1")
        let stored = root.appendingPathComponent(pages[0].storedRelativePath)
        let encoded = try Data(contentsOf: stored)
        var reconstructed = Data(count: original.count)
        let count = reconstructed.withUnsafeMutableBytes { output in
            encoded.withUnsafeBytes { input in
                ziv_jxl_reconstruct_jpeg(input.bindMemory(to: UInt8.self).baseAddress, encoded.count,
                                         output.bindMemory(to: UInt8.self).baseAddress, original.count)
            }
        }
        XCTAssertEqual(count, original.count)
        XCTAssertEqual(reconstructed, original)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(stored as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 8)
    }

    func testPNGCompressionPreservesPageIdentityDimensionsOrientationAndProfile() throws {
        let root = try directory()
        let file = root.appendingPathComponent("page.png")
        let original = try fixture(type: .png, orientation: 6)
        try original.write(to: file)
        let pages = try ExtractedImageProcessor().prepare(images: [file], imageRoot: root, compress: true)
        XCTAssertEqual(pages[0].originalRelativePath, "page.png")
        XCTAssertTrue(pages[0].storedRelativePath.hasSuffix(".jxl"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let stored = root.appendingPathComponent(pages[0].storedRelativePath)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(stored as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width * image.height, 1024 * 768)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.displayP3)
        let storedBytes = try Data(contentsOf: stored).count
        let previewBytes = try Data(contentsOf: root.appendingPathComponent(try XCTUnwrap(pages[0].previewRelativePath))).count
        XCTAssertLessThanOrEqual(storedBytes + previewBytes, original.count - max(16384, Int(ceil(Double(original.count) * 0.05))))
    }

    func testMalformedInputFallsBackWithoutChangingBytes() throws {
        let root = try directory()
        let file = root.appendingPathComponent("broken.jpg")
        let original = Data([0xff, 0xd8, 0, 1, 2, 3])
        try original.write(to: file)
        let pages = try ExtractedImageProcessor().prepare(images: [file], imageRoot: root, compress: true)
        XCTAssertEqual(pages[0].storedRelativePath, "broken.jpg")
        XCTAssertNil(pages[0].previewRelativePath)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["broken.jpg"])
    }

    func testUnsafeInputFailsBeforeProcessingAnyPage() throws {
        let root = try directory()
        let file = root.appendingPathComponent("page.png")
        let original = try fixture(type: .png)
        try original.write(to: file)
        let outside = try directory().appendingPathComponent("outside.png")
        try original.write(to: outside)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try ExtractedImageProcessor().prepare(images: [file, link], imageRoot: root, compress: true))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    func testCancellationIsPropagated() throws {
        let root = try directory()
        let file = root.appendingPathComponent("page.png")
        try fixture(type: .png).write(to: file)
        XCTAssertThrowsError(try ExtractedImageProcessor().prepare(images: [file], imageRoot: root, compress: true,
            cancellation: { throw CancellationError() })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["page.png"])
    }

    func testResolvedExtractorPathsInsideAliasedWorkspaceAreAccepted() throws {
        let base = try directory()
        let actual = base.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let requestedRoot = alias.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: false)
        let resolvedImage = requestedRoot.resolvingSymlinksInPath().appendingPathComponent("page.png")
        try fixture(type: .png).write(to: resolvedImage)
        let pages = try ExtractedImageProcessor().prepare(images: [resolvedImage], imageRoot: requestedRoot, compress: false)
        XCTAssertEqual(pages[0].storedRelativePath, "page.png")
        XCTAssertNotNil(pages[0].previewRelativePath)
    }
}
