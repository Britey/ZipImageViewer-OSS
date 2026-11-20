import Foundation

/// Deterministic whole-archive LRU policy. Temporary sessions do not displace retained archives.
enum ArchiveCachePolicy {
    struct Entry {
        let id: UUID
        let bytes: Int64
        let accessSequence: UInt64
        let isLeased: Bool
    }

    static func evictionCandidates(entries: [Entry], preferences: ArchiveCachePreferences) -> [UUID] {
        var bytes = entries.reduce(Int64(0)) { $0 + $1.bytes }
        var count = entries.count
        var victims: [UUID] = []
        for entry in entries.sorted(by: {
            $0.accessSequence == $1.accessSequence
                ? $0.id.uuidString < $1.id.uuidString : $0.accessSequence < $1.accessSequence
        }) {
            let exceedsCount = preferences.maximumArchiveCount.map { count > $0 } ?? false
            guard bytes > preferences.maximumBytes || exceedsCount else { break }
            guard !entry.isLeased else { continue }
            victims.append(entry.id)
            bytes -= entry.bytes
            count -= 1
        }
        return victims
    }
}
