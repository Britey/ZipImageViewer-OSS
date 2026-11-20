package com.brite.zipimageviewer.reader

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class ReaderModelsTest {
    private fun page(path: String, modified: Long? = null, created: Long? = null) =
        ReaderPage(path, File("/unused/$path"), modified, created)
    @Test fun imageRotationControlsDefaultOff() { assertFalse(ReaderPreferences().showRotationButtons) }

    private fun paths(pages: List<ReaderPage>, preferences: ReaderPreferences = ReaderPreferences()) =
        sortedReaderPages(pages, preferences).map { it.relativePath }

    @Test fun numericFilenamesFollowReadingOrderInsteadOfLexicalOrder() {
        val pages = listOf(page("page10.png"), page("page2.png"), page("page1.png"))
        assertEquals(listOf("page1.png", "page2.png", "page10.png"), paths(pages))
    }

    @Test fun nestedImagesSortByFilenameAndUseOriginalPathForDuplicates() {
        val pages = listOf(page("z/page2.png"), page("a/page10.png"), page("a/page2.png"))
        assertEquals(listOf("a/page2.png", "z/page2.png", "a/page10.png"), paths(pages))
    }

    @Test fun filenameNumbersCannotOverflowAJavaLong() {
        val pages = listOf(page("page99999999999999999999999999999.jpg"), page("page100000000000000000000000000000.jpg"))
        assertEquals(pages.map { it.relativePath }, paths(pages.reversed()))
    }

    @Test fun leadingZerosRemainDeterministicRegardlessOfImportOrder() {
        val a = page("page0002.jpg"); val b = page("page2.jpg")
        assertEquals(paths(listOf(a, b)), paths(listOf(b, a)))
        assertEquals(listOf(a.relativePath, b.relativePath), paths(listOf(b, a)))
    }

    @Test fun modifiedSortUsesArchiveDatesAndPlacesUnknownDatesLast() {
        val pages = listOf(page("page1.png"), page("page2.png", 20), page("page10.png", 10))
        assertEquals(listOf("page10.png", "page2.png", "page1.png"), paths(pages, ReaderPreferences(sortCriterion = SortCriterion.MODIFIED)))
    }

    @Test fun equalDatesFallBackToNaturalFilenameOrder() {
        val pages = listOf(page("page10.png", 10), page("page2.png", 10))
        assertEquals(listOf("page2.png", "page10.png"), paths(pages, ReaderPreferences(sortCriterion = SortCriterion.MODIFIED)))
    }

    @Test fun createdAndModifiedDatesAreIndependent() {
        val pages = listOf(page("page1.png", modified = 10, created = 20), page("page2.png", modified = 20, created = 10))
        assertEquals(listOf("page2.png", "page1.png"), paths(pages, ReaderPreferences(sortCriterion = SortCriterion.CREATED)))
        assertEquals(listOf("page1.png", "page2.png"), paths(pages, ReaderPreferences(sortCriterion = SortCriterion.MODIFIED)))
    }

    @Test fun descendingInvertsTheCompleteStableOrderingIncludingUnknownDates() {
        val pages = listOf(page("page1.png", 10), page("page2.png"), page("page10.png", 20))
        val ascending = ReaderPreferences(sortCriterion = SortCriterion.MODIFIED)
        assertEquals(paths(pages, ascending).reversed(), paths(pages, ascending.copy(descending = true)))
    }

    @Test fun sortingRetainsPageObjectsAndOriginalProgressIdentity() {
        val selected = page("chapter/page2.png", 1)
        val pages = listOf(page("page1.png", 10), selected)
        val sorted = sortedReaderPages(pages, ReaderPreferences(sortCriterion = SortCriterion.MODIFIED))
        assertSame(selected, sorted.single { it.relativePath == selected.relativePath })
        assertEquals(listOf("page1.png", "chapter/page2.png"), pages.map { it.relativePath })
    }

    @Test fun invalidPersistedFloatsResetToDefaultsWithoutChangingOtherPreferences() {
        for (bad in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY, -1f, 2f)) {
            val prefs = ReaderPreferences(tapRatio = bad, thumbnailSize = bad, reversed = true, descending = true).validated()
            assertEquals(0.3f, prefs.tapRatio, 0f)
            assertEquals(0.25f, prefs.thumbnailSize, 0f)
            assertTrue(prefs.reversed)
            assertTrue(prefs.descending)
        }
    }

    @Test fun tapAreaChoicesMatchTheFiveSupportedIosPresets() {
        assertEquals(listOf(0.1f, 0.3f, 0.5f, 0.7f, 0.9f), ReaderPreferences.tapAreaPresets)
        ReaderPreferences.tapAreaPresets.forEach { ratio ->
            assertEquals(ratio, ReaderPreferences(tapRatio = ratio).validated().tapRatio, 0f)
        }
    }

    @Test fun acceptedPreferenceBoundariesArePreserved() {
        assertEquals(0.1f, ReaderPreferences(tapRatio = 0.1f).validated().tapRatio, 0f)
        assertEquals(0.9f, ReaderPreferences(tapRatio = 0.9f).validated().tapRatio, 0f)
        assertEquals(0f, ReaderPreferences(thumbnailSize = 0f).validated().thumbnailSize, 0f)
        assertEquals(1f, ReaderPreferences(thumbnailSize = 1f).validated().thumbnailSize, 0f)
    }

    @Test fun emptyAndSinglePageArchivesHaveDeterministicOrdering() {
        assertTrue(paths(emptyList()).isEmpty())
        assertEquals(listOf("only.png"), paths(listOf(page("only.png")), ReaderPreferences(descending = true)))
    }
}
