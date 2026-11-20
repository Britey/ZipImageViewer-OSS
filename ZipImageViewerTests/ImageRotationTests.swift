import Testing
import UIKit
@testable import ZipImageViewer

@Suite(.serialized)
@MainActor
struct ImageRotationTests {
    @Test func quarterTurnsComposeWithAllExifOrientationsWithoutCopyingPixels() throws {
        let original = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            UIColor.blue.setFill(); context.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
        }
        for orientation in [UIImage.Orientation.up, .down, .left, .right, .upMirrored, .downMirrored, .leftMirrored, .rightMirrored] {
            let image = UIImage(cgImage: try #require(original.cgImage), scale: 1, orientation: orientation)
            #expect(image.rotatedQuarterTurns(1).rotatedQuarterTurns(-1).imageOrientation == orientation)
            var turned = image
            for _ in 0..<4 { turned = turned.rotatedQuarterTurns(1) }
            #expect(turned.imageOrientation == orientation)
            #expect(turned.cgImage === image.cgImage)
            // Compare metadata composition to a real clockwise drawing transform,
            // including mirrored EXIF inputs (whose rotation cycle is easy to reverse).
            let size = CGSize(width: image.size.height, height: image.size.width)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let expected = renderer.image { context in
                context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
                context.cgContext.rotate(by: .pi / 2)
                image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
            }
            let actual = renderer.image { _ in image.rotatedQuarterTurns(1).draw(in: CGRect(origin: .zero, size: size)) }
            let expectedCG = try #require(expected.cgImage)
            let actualCG = try #require(actual.cgImage)
            let expectedPixels = try #require(expectedCG.dataProvider?.data) as Data
            let actualPixels = try #require(actualCG.dataProvider?.data) as Data
            for y in [Int(size.height / 4), Int(size.height * 3 / 4)] {
                for x in [Int(size.width / 4), Int(size.width * 3 / 4)] {
                    let offset = y * expectedCG.bytesPerRow + x * 4
                    #expect(expectedPixels[offset..<(offset + 4)] == actualPixels[offset..<(offset + 4)])
                }
            }
        }
        #expect(original.rotatedQuarterTurns(1).imageOrientation == .right)
        #expect(original.rotatedQuarterTurns(-1).imageOrientation == .left)
    }

    @Test func liveRotationRefitsResetsZoomAndSurvivesDetailAndViewportChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 600)).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 300, width: 300, height: 300))
        }
        let urls = [directory.appendingPathComponent("1.png"), directory.appendingPathComponent("2.png")]
        for url in urls { try data.write(to: url) }
        let viewer = ImageViewerViewController()
        viewer.imageUrls = urls
        viewer.applyPreferences(ReaderPreferences())
        viewer.loadViewIfNeeded()
        viewer.view.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        viewer.view.layoutIfNeeded()
        for _ in 0..<200 where viewer.fittedIndex != 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(viewer.fittedIndex == 0)
        let scroll = try #require(viewer.view.subviews.compactMap { $0 as? UIScrollView }.first)
        let image = try #require(scroll.subviews.compactMap { $0 as? UIImageView }.first)
        viewer.performSharedAction("rotateClockwise", page: nil, scrubbing: false)
        #expect(viewer.imageQuarterTurns == 0) // Off by default, including native commands.
        var prefs = ReaderPreferences(); prefs.showRotationButtons = true
        viewer.applyPreferences(prefs)
        for _ in 0..<200 where viewer.fittedIndex != 0 { try await Task.sleep(for: .milliseconds(10)) }
        viewer.performSharedAction("rotateCounterclockwise", page: nil, scrubbing: false)
        #expect(viewer.imageQuarterTurns == 3)
        #expect(image.image?.imageOrientation == .left)
        // Rendering the native view must fit the turned wide image, with vertical letterboxing.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let rendered = UIGraphicsImageRenderer(size: viewer.view.bounds.size, format: format).image { context in
            viewer.view.layer.render(in: context.cgContext)
        }
        let pixels = try #require(rendered.cgImage?.dataProvider?.data) as Data
        let cg = try #require(rendered.cgImage)
        func channel(_ x: Int, _ y: Int, _ c: Int) -> UInt8 { pixels[y * cg.bytesPerRow + x * 4 + c] }
        #expect(channel(160, 180, 0) < 10 && channel(160, 180, 1) < 10 && channel(160, 180, 2) < 10)
        #expect(max(channel(80, 320, 0), channel(80, 320, 2)) > 240)
        scroll.setZoomScale(2.5, animated: false)
        scroll.contentOffset = CGPoint(x: 100, y: 100)
        viewer.performSharedAction("rotateClockwise", page: nil, scrubbing: false)
        #expect(viewer.imageQuarterTurns == 0)
        #expect(scroll.zoomScale == 1)
        #expect(scroll.contentOffset == .zero)
        for _ in 0..<4 { viewer.performSharedAction("rotateClockwise", page: nil, scrubbing: false) }
        #expect(image.image?.imageOrientation == .up)
        viewer.performSharedAction("rotateClockwise", page: nil, scrubbing: false)
        viewer.view.frame.size = CGSize(width: 640, height: 320)
        viewer.view.setNeedsLayout(); viewer.view.layoutIfNeeded()
        #expect(viewer.imageQuarterTurns == 1)
        #expect(image.image?.imageOrientation == .right)
        scroll.setZoomScale(2, animated: false)
        viewer.scrollViewWillBeginZooming(scroll, with: image)
        for _ in 0..<200 where viewer.zoomReadyIndex != 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(viewer.zoomReadyIndex == 0)
        #expect(image.image?.imageOrientation == .right)
        #expect(scroll.zoomScale == 2)
        prefs.showRotationButtons = false; viewer.applyPreferences(prefs)
        #expect(viewer.imageQuarterTurns == 1) // Hiding buttons preserves the current view.
        viewer.navigate(to: 1)
        #expect(viewer.imageQuarterTurns == 0)
        for _ in 0..<200 where viewer.fittedIndex != 1 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(image.image?.imageOrientation == .up)
        viewer.navigate(to: 0)
        #expect(viewer.imageQuarterTurns == 0)
        for _ in 0..<200 where viewer.fittedIndex != 0 { try await Task.sleep(for: .milliseconds(10)) }
        prefs.showRotationButtons = true; viewer.applyPreferences(prefs)
        viewer.performSharedAction("rotateClockwise", page: nil, scrubbing: false)
        #expect(viewer.imageQuarterTurns == 1)
        viewer.performSharedAction("seek", page: 2, scrubbing: true)
        viewer.performSharedAction("seek", page: 1, scrubbing: false)
        #expect(viewer.imageQuarterTurns == 0)
    }
}
