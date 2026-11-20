import UIKit
import XCTest
@testable import ZipImageViewer

@MainActor
final class ArchiveLibraryLayoutTests: XCTestCase {
    func testLandscapeMiniGridKeepsFourColumnsWithinViewport() throws {
        let library = ArchiveLibraryViewController()
        library.loadViewIfNeeded()
        library.view.frame = CGRect(x: 0, y: 0, width: 1133, height: 744)
        library.traitOverrides.verticalSizeClass = .regular
        library.traitOverrides.preferredContentSizeCategory = .large
        library.view.updateTraitsIfNeeded()
        library.update(archives: (0..<8).map { _ in archive() }, ready: true, busy: false)
        library.view.setNeedsLayout()
        library.view.layoutIfNeeded()
        library.collectionView.layoutIfNeeded()
        let frames = try (0..<8).map { item in
            try XCTUnwrap(library.collectionView.layoutAttributesForItem(at: IndexPath(item: item, section: 0))).frame
        }
        XCTAssertEqual(library.collectionView.bounds.width, 1133, accuracy: 1)
        for frame in frames {
            XCTAssertGreaterThan(frame.width, 200)
            XCTAssertLessThan(frame.width, 300)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, library.collectionView.bounds.width)
        }
        for column in 1..<4 {
            XCTAssertEqual(frames[column].minY, frames[0].minY, accuracy: 1)
            XCTAssertGreaterThanOrEqual(frames[column].minX - frames[column - 1].maxX, 19)
        }
        XCTAssertGreaterThan(frames[4].minY, frames[0].minY)
        XCTAssertEqual(frames[4].minX, frames[0].minX, accuracy: 1)
    }

    func testLargeTextCellKeepsTitleAndActionsInsideNarrowColumn() throws {
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        let cell = ArchiveLibraryCell(frame: CGRect(x: 0, y: 0, width: 288, height: 110))
        host.view.addSubview(cell)
        // Resolve the trait on the measured view immediately. Controller trait
        // propagation through a test window otherwise waits for a UIKit cycle.
        cell.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        cell.updateTraitsIfNeeded()
        XCTAssertEqual(cell.traitCollection.preferredContentSizeCategory, .accessibilityExtraExtraExtraLarge)
        cell.configure(archive(), grid: false, isBusy: false, details: {}, remove: {})
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.size = CGSize(width: 288, height: 110)
        let fitted = cell.preferredLayoutAttributesFitting(attributes)
        XCTAssertEqual(fitted.size.width, 288)
        XCTAssertGreaterThan(fitted.size.height, 110)
        cell.frame.size = fitted.size
        cell.layoutIfNeeded()
        let labels = descendants(of: cell).compactMap { $0 as? UILabel }
        let title = try XCTUnwrap(labels.first { $0.accessibilityIdentifier == "archiveTitle" })
        let progress = try XCTUnwrap(labels.first { $0.accessibilityIdentifier == "archiveReadingProgress" })
        let action = try XCTUnwrap(descendants(of: cell).first { $0.accessibilityIdentifier == "archiveActions" })
        let titleFrame = title.convert(title.bounds, to: cell.contentView)
        let progressFrame = progress.convert(progress.bounds, to: cell.contentView)
        let actionFrame = action.convert(action.bounds, to: cell.contentView)
        XCTAssertTrue(cell.contentView.bounds.contains(titleFrame))
        XCTAssertTrue(cell.contentView.bounds.contains(progressFrame))
        XCTAssertTrue(cell.contentView.bounds.contains(actionFrame))
        XCTAssertLessThanOrEqual(titleFrame.maxY, progressFrame.minY)
        XCTAssertLessThanOrEqual(titleFrame.maxX, actionFrame.minX)
        XCTAssertEqual(title.numberOfLines, 0)
        XCTAssertGreaterThanOrEqual(actionFrame.width, 44)
        XCTAssertGreaterThanOrEqual(actionFrame.height, 44)
        cell.traitOverrides.preferredContentSizeCategory = .large
        cell.updateTraitsIfNeeded()
        XCTAssertEqual(title.numberOfLines, 2, "A live text-size change should update existing cells")
        XCTAssertLessThan(cell.preferredLayoutAttributesFitting(attributes).size.height, fitted.size.height)
    }

    func testBusyCellDoesNotExposeStorageAccessibilityActions() {
        let cell = ArchiveLibraryCell(frame: CGRect(x: 0, y: 0, width: 320, height: 110))
        cell.configure(archive(), grid: false, isBusy: true, details: {}, remove: {})
        XCTAssertTrue(cell.accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(cell.accessibilityCustomActions?.isEmpty == true)
        cell.configure(archive(), grid: false, isBusy: false, details: {}, remove: {})
        XCTAssertFalse(cell.accessibilityTraits.contains(.notEnabled))
        XCTAssertEqual(cell.accessibilityCustomActions?.count, 2)
    }

    func testEmptyStateScrollsVerticallyAtLargestTextSizeWithoutHorizontalOverflow() throws {
        let library = ArchiveLibraryViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        window.rootViewController = library
        window.isHidden = false
        defer { window.isHidden = true }
        library.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        library.update(archives: [], ready: true, busy: false)
        library.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(library.view.subviews.compactMap { $0 as? UIScrollView }.first { !($0 is UICollectionView) })
        scroll.layoutIfNeeded()
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        XCTAssertEqual(scroll.contentSize.width, scroll.bounds.width, accuracy: 1)
        let button = try XCTUnwrap(descendants(of: scroll).first { $0.accessibilityIdentifier == "libraryEmptyAction" })
        let frame = button.convert(button.bounds, to: scroll)
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertLessThanOrEqual(frame.maxX, scroll.contentSize.width)
        XCTAssertLessThanOrEqual(frame.maxY, scroll.contentSize.height)
    }

    private func archive() -> CachedArchiveSummary {
        CachedArchiveSummary(id: UUID(), displayName: "A long archive title with many words and 日本語.cbz", format: "cbz",
                             imageCount: 120, lastOpenedAt: Date(), position: ArchiveReadingPosition(index: 79),
                             isAvailable: true, thumbnailURL: nil, retainedBytes: 1024)
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
