package com.brite.zipimageviewer.data

import java.io.IOException

data class PageRecord(
    val originalPath: String,
    val storedPath: String,
    val modifiedAt: Long? = null,
    val createdAt: Long? = null,
    val previewPath: String? = null,
    val processingPolicy: String? = null,
)

data class ArchiveRecord(
    val id: String,
    val title: String,
    val format: String,
    val pages: List<PageRecord>,
    val lastOpened: Long,
    val currentPagePath: String?,
    val bytes: Long,
    val available: Boolean = true,
    val isTemporary: Boolean = false,
    val accessSequence: Long = 0,
    val storageDirectory: String = id,
    val sourceIdentity: String? = null,
    val sourceDigest: String? = null,
    val visible: Boolean = true,
)

data class CacheLimits(
    val maximumBytes: Long = CachePolicy.DEFAULT_BUDGET,
    val maximumArchiveCount: Int? = null,
) {
    init {
        require(maximumBytes > 0) { "Cache size must be positive." }
        require(maximumArchiveCount == null || maximumArchiveCount > 0) { "Archive count must be positive or unlimited." }
    }
}

/** A read-only snapshot; applying it revalidates the repository and reader leases. */
class CacheLimitPreview internal constructor(
    val limits: CacheLimits,
    val candidates: List<ArchiveRecord>,
    internal val repositoryToken: String,
    internal val stateRevision: Long,
) {
    val reclaimedBytes: Long get() = candidates.sumOf { it.bytes }
}

sealed interface CacheLimitApplyResult {
    data class Applied(val limits: CacheLimits, val removedIds: List<String>) : CacheLimitApplyResult
    data class NeedsConfirmation(val preview: CacheLimitPreview) : CacheLimitApplyResult
}

class PasswordRequiredException(
    message: String = "Enter the archive password. If you already tried one, it may be incorrect or the archive may be damaged.",
    cause: Throwable? = null,
) : IOException(message, cause)

class ImportFailure(message: String, cause: Throwable? = null) : IOException(message, cause)

enum class PageSort { NAME, MODIFIED, CREATED }

fun sortedPages(pages: List<PageRecord>, sort: PageSort = PageSort.NAME, descending: Boolean = false): List<PageRecord> {
    val comparator = Comparator<PageRecord> { a, b ->
        val dateA = when (sort) { PageSort.NAME -> null; PageSort.MODIFIED -> a.modifiedAt; PageSort.CREATED -> a.createdAt }
        val dateB = when (sort) { PageSort.NAME -> null; PageSort.MODIFIED -> b.modifiedAt; PageSort.CREATED -> b.createdAt }
        val dates = when {
            dateA == dateB -> 0
            dateA == null -> 1
            dateB == null -> -1
            else -> dateA.compareTo(dateB)
        }
        dates.takeIf { it != 0 }
            ?: NaturalOrder.compare(a.originalPath.substringAfterLast('/'), b.originalPath.substringAfterLast('/')).takeIf { it != 0 }
            ?: a.originalPath.compareTo(b.originalPath)
    }
    return pages.sortedWith(if (descending) comparator.reversed() else comparator)
}

/** Numeric runs compare without converting to fixed-width integers. */
object NaturalOrder : Comparator<String> {
    override fun compare(a: String, b: String): Int {
        var i = 0
        var j = 0
        while (i < a.length && j < b.length) {
            if (a[i] in '0'..'9' && b[j] in '0'..'9') {
                val startI = i
                val startJ = j
                while (i < a.length && a[i] in '0'..'9') i++
                while (j < b.length && b[j] in '0'..'9') j++
                val left = a.substring(startI, i).trimStart('0').ifEmpty { "0" }
                val right = b.substring(startJ, j).trimStart('0').ifEmpty { "0" }
                val numberOrder = left.length.compareTo(right.length).takeIf { it != 0 } ?: left.compareTo(right)
                if (numberOrder != 0) return numberOrder
            } else {
                val order = a[i].lowercaseChar().compareTo(b[j].lowercaseChar())
                if (order != 0) return order
                i++
                j++
            }
        }
        return (a.length - i).compareTo(b.length - j)
    }
}
