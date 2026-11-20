package com.brite.zipimageviewer.reader

import com.brite.zipimageviewer.data.PageRecord
import java.io.File

/** One ordering per session/sort change, with O(1) lookup for every overview tile. */
internal class ReaderCoverIndex {
    private var session: String? = null
    private var source: List<PageRecord>? = null
    private var criterion: SortCriterion? = null
    private var descending = false
    private var ordered: List<PageRecord> = emptyList()

    private var positions: Map<String, Int> = emptyMap()

    fun position(id: String, pages: List<PageRecord>, preferences: ReaderPreferences, path: String?): Int {
        page(id, pages, preferences, -1)
        return positions[path] ?: -1
    }

    fun page(id: String, pages: List<PageRecord>, preferences: ReaderPreferences, index: Int): PageRecord? {
        if (session != id || source !== pages || criterion != preferences.sortCriterion || descending != preferences.descending) {
            val byPath = pages.associateBy { it.originalPath }
            ordered = sortedReaderPages(pages.map {
                ReaderPage(it.originalPath, File(it.storedPath), it.modifiedAt, it.createdAt)
            }, preferences).map { byPath.getValue(it.relativePath) }
            positions = ordered.mapIndexed { index, page -> page.originalPath to index }.toMap()
            session = id; source = pages; criterion = preferences.sortCriterion; descending = preferences.descending
        }
        return ordered.getOrNull(index)
    }

    fun clear() {
        session = null; source = null; criterion = null; ordered = emptyList(); positions = emptyMap()
    }
}
