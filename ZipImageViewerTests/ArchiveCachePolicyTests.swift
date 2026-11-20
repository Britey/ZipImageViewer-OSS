import XCTest
@testable import ZipImageViewer

final class ArchiveCachePolicyTests: XCTestCase {
    func testBothLimitsAndExactBoundary() {
        let a = UUID(), b = UUID(), c = UUID()
        let entries = [entry(a, bytes: 30, sequence: 1), entry(b, bytes: 40, sequence: 2), entry(c, bytes: 50, sequence: 3)]
        XCTAssertEqual(ArchiveCachePolicy.evictionCandidates(entries: entries,
            preferences: ArchiveCachePreferences(maximumBytes: 90, maximumArchiveCount: 2)), [a])
        XCTAssertEqual(ArchiveCachePolicy.evictionCandidates(entries: entries,
            preferences: ArchiveCachePreferences(maximumBytes: 120)), [])
        XCTAssertEqual(ArchiveCachePolicy.evictionCandidates(entries: entries,
            preferences: ArchiveCachePreferences(maximumBytes: Int64.max, maximumArchiveCount: 1)), [a, b])
    }

    func testLeaseDefersEvictionAndReopeningChangesVictim() {
        let a = UUID(), b = UUID(), c = UUID()
        let entries = [entry(a, bytes: 40, sequence: 4), entry(b, bytes: 40, sequence: 2, leased: true),
                       entry(c, bytes: 40, sequence: 3)]
        XCTAssertEqual(ArchiveCachePolicy.evictionCandidates(entries: entries,
            preferences: ArchiveCachePreferences(maximumBytes: 80)), [c])
    }

    private func entry(_ id: UUID, bytes: Int64, sequence: UInt64, leased: Bool = false) -> ArchiveCachePolicy.Entry {
        ArchiveCachePolicy.Entry(id: id, bytes: bytes, accessSequence: sequence, isLeased: leased)
    }
}
