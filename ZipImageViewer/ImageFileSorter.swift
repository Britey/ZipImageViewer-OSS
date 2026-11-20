import Foundation

enum SortCriterion: Int, CaseIterable {
    case filename
    case modifiedDate
    case createdDate

    var title: String {
        switch self {
        case .filename: return "Filename"
        case .modifiedDate: return "Modified"
        case .createdDate: return "Created"
        }
    }
}

enum SortOrder: Int, CaseIterable {
    case ascending
    case descending

    var title: String {
        switch self {
        case .ascending: return "Ascending"
        case .descending: return "Descending"
        }
    }
}

enum ImageFileSorter {
    static func sort(_ urls: [URL], criterion: SortCriterion, order: SortOrder,
                     metadata: [URL: ArchivePreparedPage] = [:]) -> [URL] {
        // Read each date once, outside the comparator. The comparison must stay
        // consistent even if filesystem metadata changes while sorting.
        let entries = urls.map { url -> (url: URL, identity: String, date: Date?) in
            let date: Date?
            switch criterion {
            case .filename:
                date = nil
            case .modifiedDate:
                if let page = metadata[url] { date = page.modificationDate }
                else { date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            case .createdDate:
                if let page = metadata[url] { date = page.creationDate }
                else { date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate }
            }
            return (url, metadata[url]?.originalRelativePath ?? url.path, date)
        }

        return entries.sorted { lhs, rhs in
            var result = ComparisonResult.orderedSame
            if criterion != .filename {
                switch (lhs.date, rhs.date) {
                case let (left?, right?):
                    if left < right { result = .orderedAscending }
                    if left > right { result = .orderedDescending }
                case (nil, nil): break
                case (nil, _): result = .orderedDescending
                case (_, nil): result = .orderedAscending
                }
            }
            if result == .orderedSame {
                result = (lhs.identity as NSString).lastPathComponent.localizedStandardCompare((rhs.identity as NSString).lastPathComponent)
            }
            if result == .orderedSame {
                // Duplicate filenames in different folders need a deterministic tie-break.
                result = lhs.identity.compare(rhs.identity)
            }
            return order == .ascending ? result == .orderedAscending : result == .orderedDescending
        }.map(\.url)
    }
}
