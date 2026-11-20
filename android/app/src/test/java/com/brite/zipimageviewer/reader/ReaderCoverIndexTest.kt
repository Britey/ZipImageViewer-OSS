package com.brite.zipimageviewer.reader

import com.brite.zipimageviewer.data.PageRecord
import org.junit.Assert.*
import org.junit.Test

class ReaderCoverIndexTest {
    @Test fun manyThumbnailRequestsDoNotRetraverseTheArchive() {
        val contents = (1..25_000).map { PageRecord("$it.png", "$it.png") }
        var reads = 0
        val pages = object : AbstractList<PageRecord>() {
            override val size get() = contents.size
            override fun get(index: Int): PageRecord { reads++; return contents[index] }
        }
        val index = ReaderCoverIndex()
        val prefs = ReaderPreferences()
        assertSame(contents[0], index.page("session", pages, prefs, 0))
        val firstLoadReads = reads
        for (n in 0 until 500) assertSame(contents[n], index.page("session", pages, prefs, n))
        assertEquals("Tile mounting must only perform indexed lookup", firstLoadReads, reads)
        assertSame(contents[1], index.page("session", pages, prefs.copy(thumbnailSize = .9f), 1))
        assertEquals("Presentation preferences must not trigger another archive ordering", firstLoadReads, reads)
    }

    @Test fun sortChangesAndNewSessionsUseTheCorrectOriginalPageIdentity() {
        val a = PageRecord("1.png", "1.jxl", modifiedAt = 20)
        val b = PageRecord("2.png", "2.jxl", modifiedAt = 10)
        val pages = listOf(a, b)
        val index = ReaderCoverIndex()
        assertSame(a, index.page("one", pages, ReaderPreferences(), 0))
        assertSame(b, index.page("one", pages, ReaderPreferences(descending = true), 0))
        assertSame(b, index.page("one", pages, ReaderPreferences(sortCriterion = SortCriterion.MODIFIED), 0))
        assertNull(index.page("one", pages, ReaderPreferences(), -1))
        assertNull(index.page("one", pages, ReaderPreferences(), 2))
        index.clear()
        val replacement = a.copy(storedPath = "replacement.jxl")
        assertSame(replacement, index.page("two", listOf(replacement, b), ReaderPreferences(), 0))
    }
    @Test fun libraryAndReaderAgreeForEverySortAndOriginalResumePath() {
        val pages = listOf(
            PageRecord("a/2.png", "a/2.jxl", modifiedAt = 20, createdAt = 5),
            PageRecord("b/2.png", "b/2.jxl", modifiedAt = 10),
            PageRecord("10.png", "10.jxl", createdAt = 8),
            PageRecord("1.png", "1.jxl", modifiedAt = 15, createdAt = 3),
        )
        val index = ReaderCoverIndex()
        for (criterion in SortCriterion.entries) for (descending in listOf(false, true)) {
            val preferences = ReaderPreferences(sortCriterion = criterion, descending = descending)
            val reader = sortedReaderPages(pages.map {
                ReaderPage(it.originalPath, java.io.File(it.storedPath), it.modifiedAt, it.createdAt)
            }, preferences)
            reader.forEachIndexed { position, page ->
                val summary = index.position("archive", pages, preferences, page.relativePath)
                assertEquals(position, summary)
                assertEquals((position + 1).toDouble() / pages.size, (summary + 1).toDouble() / pages.size, 0.0)
                assertEquals(page.relativePath, index.page("archive", pages, preferences, summary)!!.originalPath)
            }
            assertEquals(-1, index.position("archive", pages, preferences, "missing.png"))
        }
    }

}
