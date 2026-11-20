package com.brite.zipimageviewer.data

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files

class ArchivePolicyTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun acceptsOnlyVisibleSupportedImages() {
        assertTrue(ArchiveOutputPolicy.isSupportedImage("Chapter/001.JPG"))
        assertTrue(ArchiveOutputPolicy.isSupportedImage("scan.jpeg"))
        assertTrue(ArchiveOutputPolicy.isSupportedImage("page.png"))
        listOf("page.webp", "__MACOSX/._page.jpg", ".hidden/page.jpg", "doc.txt").forEach {
            assertFalse(it, ArchiveOutputPolicy.isSupportedImage(it))
        }
    }

    @Test fun rejectsTraversalAndAmbiguousPaths() {
        listOf("../page.jpg", "a/../page.jpg", "/page.jpg", "a//page.jpg", "./page.jpg", "C:page.jpg", "a\\page.jpg", "a\u0000.jpg", "a/", "").forEach {
            assertThrows(ImportFailure::class.java) { ArchiveOutputPolicy.validateRelativePath(it) }
        }
    }

    @Test fun rejectsOversizeUtf8ComponentsAndPaths() {
        assertThrows(ImportFailure::class.java) { ArchiveOutputPolicy.validateRelativePath("界".repeat(100) + ".jpg") }
        assertThrows(ImportFailure::class.java) { ArchiveOutputPolicy.validateRelativePath(("a/".repeat(2100)) + "x.jpg") }
    }

    @Test fun rejectsCaseAndUnicodeAliases() {
        val policy = ArchiveOutputPolicy(temporary.root)
        policy.reserve("folder/É.jpg", 1)
        assertThrows(ImportFailure::class.java) { policy.reserve("FOLDER/e\u0301.JPG", 1) }
    }

    @Test fun rejectsFilesUsedAsFoldersInBothOrders() {
        val policy = ArchiveOutputPolicy(temporary.root)
        policy.reserve("a.jpg/b.jpg", 1)
        assertThrows(ImportFailure::class.java) { policy.reserve("a.jpg", 1) }
        val reversed = ArchiveOutputPolicy(temporary.root)
        reversed.reserve("a.jpg", 1)
        assertThrows(ImportFailure::class.java) { reversed.reserve("a.jpg/b.jpg", 1) }
    }

    @Test fun refusesSymlinkEscape() {
        val root = temporary.newFolder("root")
        val outside = temporary.newFolder("outside")
        Files.createSymbolicLink(File(root, "link").toPath(), outside.toPath())
        assertThrows(ImportFailure::class.java) { ArchiveOutputPolicy(root).reserve("link/page.jpg", 1) }
    }

    @Test fun enforcesImageCountPerFileAndTotalLimits() {
        val policy = ArchiveOutputPolicy(temporary.root, ExtractionLimits(maximumImageCount = 2, maximumFileBytes = 8, maximumTotalBytes = 10))
        assertThrows(ImportFailure::class.java) { policy.reserve("oversized.jpg", 9) }
        assertThrows(ImportFailure::class.java) { policy.reserve("negative.jpg", -1) }
        policy.reserve("1.jpg", 6)
        assertThrows(ImportFailure::class.java) { policy.reserve("2.jpg", 5) }
        policy.reserve("2.jpg", 4)
        assertEquals(10L, policy.totalBytes)
        assertThrows(ImportFailure::class.java) { policy.reserve("3.jpg", 0) }
    }

    @Test fun totalAccountingDoesNotOverflow() {
        val policy = ArchiveOutputPolicy(temporary.root, ExtractionLimits(maximumFileBytes = Long.MAX_VALUE, maximumTotalBytes = Long.MAX_VALUE))
        policy.reserve("1.jpg", Long.MAX_VALUE - 1)
        assertThrows(ImportFailure::class.java) { policy.reserve("2.jpg", 5) }
    }

    @Test fun naturalSortingHandlesHugeNumbersAndNestedDuplicateNames() {
        val names = listOf("b/2.jpg", "a/10.jpg", "a/2.jpg", "a/999999999999999999999.jpg", "a/1000000000000000000000.jpg", "a/1.jpg")
        val pages = names.map { PageRecord(it, it) }
        assertEquals(listOf("a/1.jpg", "a/2.jpg", "b/2.jpg", "a/10.jpg", "a/999999999999999999999.jpg", "a/1000000000000000000000.jpg"),
            sortedPages(pages).map { it.originalPath })
        assertEquals(sortedPages(pages).reversed(), sortedPages(pages, descending = true))
    }

    @Test fun dateSortUsesOriginalMetadataAndStableFilenameFallback() {
        val pages = listOf(PageRecord("10.jpg", "rewritten-1.jxl", 10), PageRecord("2.jpg", "rewritten-2.jxl", 10),
            PageRecord("1.jpg", "rewritten-3.jxl", null), PageRecord("3.jpg", "rewritten-4.jxl", 9))
        assertEquals(listOf("3.jpg", "2.jpg", "10.jpg", "1.jpg"), sortedPages(pages, PageSort.MODIFIED).map { it.originalPath })
        assertEquals(listOf("1.jpg", "10.jpg", "2.jpg", "3.jpg"), sortedPages(pages, PageSort.MODIFIED, true).map { it.originalPath })
    }

    @Test fun cacheEvictsWholeLeastRecentlyOpenedArchives() {
        val entries = listOf(record("c", 30, 3), record("a", 50, 1), record("b", 50, 2))
        assertEquals(listOf("a"), CachePolicy.evictionCandidates(entries, 100))
        assertEquals(listOf("a", "b"), CachePolicy.evictionCandidates(entries, 40))
        assertEquals(emptyList<String>(), CachePolicy.evictionCandidates(entries, 130))
    }

    @Test fun leasesProtectActiveReaderAndTemporaryImportsNeverEvictRetainedBooks() {
        val entries = listOf(record("a", 50, 1), record("b", 50, 2), record("temporary", 10_000, 3).copy(isTemporary = true))
        assertEquals(emptyList<String>(), CachePolicy.evictionCandidates(entries, 100))
        assertEquals(listOf("b"), CachePolicy.evictionCandidates(entries, 50, setOf("a")))
        assertEquals(emptyList<String>(), CachePolicy.evictionCandidates(entries, 1, setOf("a", "b")))
    }

    @Test fun unavailableCopiesDoNotConsumeBudgetAndTiesAreDeterministic() {
        val entries = listOf(record("z", 90, 1).copy(available = false), record("b", 10, 1), record("a", 10, 1))
        assertEquals(listOf("a"), CachePolicy.evictionCandidates(entries, 10))
        assertThrows(IllegalArgumentException::class.java) { CachePolicy.evictionCandidates(entries, 0) }
    }

    @Test fun countOnlyLimitEvictsOldestWholeArchivesAndUnlimitedPreservesThem() {
        val entries = listOf(record("c", 5, 3), record("a", 5, 1), record("b", 5, 2))
        assertEquals(listOf("a", "b"), CachePolicy.evictionCandidates(entries, CacheLimits(100, 1)))
        assertEquals(listOf("a"), CachePolicy.evictionCandidates(entries, CacheLimits(100, 2)))
        assertEquals(emptyList<String>(), CachePolicy.evictionCandidates(entries, CacheLimits(100)))
    }

    @Test fun combinedLimitsContinueUntilBothByteAndCountRequirementsAreMet() {
        val entries = listOf(record("a", 10, 1), record("b", 60, 2), record("c", 20, 3), record("d", 10, 4))
        assertEquals(listOf("a", "b"), CachePolicy.evictionCandidates(entries, CacheLimits(40, 3)))
        assertEquals(listOf("a", "b", "c"), CachePolicy.evictionCandidates(entries, CacheLimits(100, 1)))
        assertEquals(listOf("a", "b"), CachePolicy.evictionCandidates(entries, CacheLimits(30, 2)))
    }

    @Test fun countLimitProtectsLeasesAndExcludesTemporaryAndUnavailableRecords() {
        val entries = listOf(record("a", 10, 1), record("b", 10, 2), record("c", 10, 3),
            record("temporary", 10_000, 0).copy(isTemporary = true), record("missing", 10_000, 0).copy(available = false))
        assertEquals(listOf("b", "c"), CachePolicy.evictionCandidates(entries, CacheLimits(100, 1), setOf("a")))
        assertEquals(listOf("c"), CachePolicy.evictionCandidates(entries, CacheLimits(1, 1), setOf("a", "b")))
        assertEquals(emptyList<String>(), CachePolicy.evictionCandidates(entries, CacheLimits(100, 3)))
    }

    @Test fun cacheLimitModelRejectsZeroAndNegativeCountAndBytes() {
        assertThrows(IllegalArgumentException::class.java) { CacheLimits(0) }
        assertThrows(IllegalArgumentException::class.java) { CacheLimits(-1) }
        assertThrows(IllegalArgumentException::class.java) { CacheLimits(100, 0) }
        assertThrows(IllegalArgumentException::class.java) { CacheLimits(100, -1) }
        assertNull(CacheLimits().maximumArchiveCount)
        assertEquals(2_000_000_000L, CacheLimits().maximumBytes)
    }

    private fun record(id: String, bytes: Long, opened: Long) = ArchiveRecord(id, id, "zip", emptyList(), opened, null, bytes)
}
