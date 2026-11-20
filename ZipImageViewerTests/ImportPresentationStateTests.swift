import XCTest
@testable import ZipImageViewer

final class ImportPresentationStateTests: XCTestCase {
    func testSevenZipMappingPreservesFractionsAndCancellationCapabilities() {
        let extracting = ImportPresentationState.from(coordinatorState: .extracting(0.4), filename: "Book.7z")
        XCTAssertEqual(extracting?.stage, .extracting)
        XCTAssertEqual(extracting?.progress, 0.4)
        XCTAssertEqual(extracting?.filename, "Book.7z")
        XCTAssertEqual(extracting?.canCancel, true)
        XCTAssertEqual(ImportPresentationState.from(coordinatorState: .compressing(0.6), filename: "Book.7z"),
                       ImportPresentationState(stage: .compressing, filename: "Book.7z", progress: 0.6, canCancel: true))
        XCTAssertEqual(ImportPresentationState.from(coordinatorState: .preparingPreviews(0.2), filename: "Book.7z")?.stage,
                       .preparingPreviews)
        XCTAssertEqual(ImportPresentationState.from(coordinatorState: .finalizing, filename: "Book.7z")?.stage,
                       .preparingPages)
        XCTAssertEqual(ImportPresentationState.from(coordinatorState: .awaitingPassword(.passwordRequired),
                                                  filename: "Book.7z")?.stage, .waitingForPassword)
        for state in [ArchiveImportCoordinator.State.cancelling, .completed([]), .failed(CocoaError(.fileReadCorruptFile))] {
            XCTAssertEqual(ImportPresentationState.from(coordinatorState: state, filename: "Book.7z")?.canCancel, false)
        }
        XCTAssertNil(ImportPresentationState.from(coordinatorState: .idle, filename: "Book.7z"))
    }

    func testUnknownAndInvalidProgressRemainIndeterminate() {
        for fraction in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(ImportPresentationState(stage: .extracting, filename: "Book.zip", progress: fraction).progress)
        }
        XCTAssertNil(ImportPresentationState(stage: .extracting, filename: "Book.zip").progress)
        XCTAssertEqual(ImportPresentationState(stage: .extracting, filename: "Book.zip", progress: -0.5).progress, 0)
        XCTAssertEqual(ImportPresentationState(stage: .extracting, filename: "Book.zip", progress: 1.5).progress, 1)
    }
}
