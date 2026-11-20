package com.brite.zipimageviewer.reader

import java.io.File
import java.text.Collator

enum class SortCriterion(val label: String) { FILENAME("Filename"), MODIFIED("Modified date"), CREATED("Created date") }

data class ReaderPreferences(
    val showSlider: Boolean = true,
    val showCount: Boolean = true,
    val centerTap: Boolean = true,
    val reversed: Boolean = false,
    val animate: Boolean = false,
    val tapRatio: Float = 0.3f,
    val sortCriterion: SortCriterion = SortCriterion.FILENAME,
    val descending: Boolean = false,
    val thumbnailSize: Float = 0.25f,
    val doubleTapZoom: Boolean = true,
    val showRotationButtons: Boolean = false,
) {
    companion object { val tapAreaPresets: List<Float> = listOf(0.1f, 0.3f, 0.5f, 0.7f, 0.9f) }

    fun validated() = copy(
        tapRatio = tapRatio.takeIf { it.isFinite() && it in 0.1f..0.9f } ?: 0.3f,
        thumbnailSize = thumbnailSize.takeIf { it.isFinite() && it in 0f..1f } ?: 0.25f,
    )
}

data class ReaderPage(
    val relativePath: String,
    val file: File,
    val modifiedAt: Long? = null,
    val createdAt: Long? = null,
    val previewFile: File? = null,
)

/** Dates come from archive metadata, not the cache file creation time. */
fun sortedReaderPages(pages: List<ReaderPage>, preferences: ReaderPreferences): List<ReaderPage> {
    val collator = Collator.getInstance().apply { strength = Collator.SECONDARY }
    val tokens = Regex("[0-9]+|[^0-9]+")
    fun natural(a: String, b: String): Int {
        val left = tokens.findAll(a).map { it.value }.toList()
        val right = tokens.findAll(b).map { it.value }.toList()
        for (i in 0 until minOf(left.size, right.size)) {
            val x = left[i]; val y = right[i]
            val comparison = if (x[0].isDigit() && y[0].isDigit()) {
                val nx = x.trimStart('0').ifEmpty { "0" }; val ny = y.trimStart('0').ifEmpty { "0" }
                nx.length.compareTo(ny.length).takeIf { it != 0 } ?: nx.compareTo(ny)
            } else collator.compare(x, y)
            if (comparison != 0) return comparison
        }
        return left.size.compareTo(right.size)
    }
    val comparator = Comparator<ReaderPage> { a, b ->
        val ad = when (preferences.sortCriterion) { SortCriterion.MODIFIED -> a.modifiedAt; SortCriterion.CREATED -> a.createdAt; else -> null }
        val bd = when (preferences.sortCriterion) { SortCriterion.MODIFIED -> b.modifiedAt; SortCriterion.CREATED -> b.createdAt; else -> null }
        val dateOrder = when { ad == null && bd == null -> 0; ad == null -> 1; bd == null -> -1; else -> ad.compareTo(bd) }
        val nameOrder = if (dateOrder == 0) natural(a.relativePath.substringAfterLast('/'), b.relativePath.substringAfterLast('/')) else dateOrder
        if (nameOrder == 0) a.relativePath.compareTo(b.relativePath) else nameOrder
    }
    return pages.sortedWith(if (preferences.descending) comparator.reversed() else comparator)
}
