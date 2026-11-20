package com.brite.zipimageviewer.data

import java.io.File
import java.text.Normalizer
import java.util.Locale

data class ExtractionLimits(
    val maximumEntryCount: Int = 100_000,
    val maximumZipMetadataBytes: Long = 16L * 1024 * 1024,
    val maximumImageCount: Int = 25_000,
    val maximumFileBytes: Long = 512L * 1024 * 1024,
    val maximumTotalBytes: Long = 10L * 1024 * 1024 * 1024,
    val minimumFreeDiskBytes: Long = 100L * 1024 * 1024,
)

/** Archive names never become paths until this policy approves them. */
class ArchiveOutputPolicy(private val root: File, val limits: ExtractionLimits = ExtractionLimits()) {
    private val files = mutableSetOf<String>()
    private val directories = mutableSetOf<String>()
    var totalBytes: Long = 0
        private set

    fun reserve(name: String, size: Long): File {
        validateRelativePath(name)
        val parts = name.split('/')
        val keys = parts.map { Normalizer.normalize(it, Normalizer.Form.NFC).lowercase(Locale.ROOT) }
        val key = keys.joinToString("/")
        if (key in files || key in directories) throw ImportFailure("Conflicting image paths: $name")
        val parents = (1 until keys.size).map { keys.take(it).joinToString("/") }
        if (parents.any { it in files }) throw ImportFailure("A file is also used as a folder: $name")
        if (files.size >= limits.maximumImageCount) throw ImportFailure("The archive contains too many images.")
        if (size < 0 || size > limits.maximumFileBytes || size > limits.maximumTotalBytes - totalBytes) {
            throw ImportFailure("The archive exceeds the safe extraction size limit.")
        }
        val file = containedFile(root, name)
        files.add(key)
        directories.addAll(parents)
        totalBytes += size
        return file
    }

    companion object {
        fun isSupportedImage(name: String): Boolean = name.substringAfterLast('.', "").lowercase(Locale.ROOT) in setOf("jpg", "jpeg", "png") &&
            name.split('/').none { it.startsWith('.') && it != "." && it != ".." }

        fun validateRelativePath(name: String) {
            if (name.isEmpty() || name.startsWith('/') || '\\' in name || ':' in name || name.any { it.isISOControl() } ||
                name.toByteArray(Charsets.UTF_8).size > 4096 ||
                name.split('/').any { it.isEmpty() || it == "." || it == ".." || it.toByteArray(Charsets.UTF_8).size > 255 }) {
                throw ImportFailure("Unsafe archive image path: $name")
            }
        }

        fun containedFile(root: File, path: String): File {
            validateRelativePath(path)
            val file = File(root, path)
            if (!file.canonicalPath.startsWith(root.canonicalPath + File.separator)) throw ImportFailure("Unsafe image path: $path")
            return file
        }
    }
}

object CachePolicy {
    const val DEFAULT_BUDGET = 2_000_000_000L

    fun evictionCandidates(records: List<ArchiveRecord>, maximumBytes: Long, leased: Set<String> = emptySet(), maximumArchiveCount: Int? = null): List<String> =
        evictionCandidates(records, CacheLimits(maximumBytes, maximumArchiveCount), leased)

    fun evictionCandidates(records: List<ArchiveRecord>, limits: CacheLimits, leased: Set<String> = emptySet()): List<String> {
        val retained = records.filter { !it.isTemporary && it.available }
        var total = retained.sumOf { it.bytes }
        var count = retained.size
        return retained.sortedWith(compareBy<ArchiveRecord> { if (it.accessSequence > 0) it.accessSequence else it.lastOpened }.thenBy { it.id }).mapNotNull {
            val exceedsCount = limits.maximumArchiveCount?.let { maximum -> count > maximum } ?: false
            if ((total <= limits.maximumBytes && !exceedsCount) || it.id in leased) null
            else { total -= it.bytes; count--; it.id }
        }
    }
}
