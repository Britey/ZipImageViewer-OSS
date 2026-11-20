package com.brite.zipimageviewer.nativebridge

import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.text.Normalizer
import java.util.Locale

/** The SDK cannot distinguish a wrong password from encrypted or damaged headers/data. */
class PasswordRequiredException(message: String) : IOException(message)

/** Synchronous native extraction. Run on an IO worker, with a fresh private destination per attempt. */
object NativeSevenZip {
    init { System.loadLibrary("zipimageviewer_native") }

    data class ExtractedEntry(val path: String, val modifiedAt: Long?, val createdAt: Long?)

    @Throws(IOException::class)
    fun extract(
        archivePath: String,
        destinationPath: String,
        password: String?,
        onProgress: (Float) -> Unit,
        isCancelled: () -> Boolean,
    ): List<String> = extractDetailed(archivePath, destinationPath, password, onProgress, isCancelled).map { it.path }

    @Throws(IOException::class)
    fun extractDetailed(
        archivePath: String,
        destinationPath: String,
        password: String?,
        onProgress: (Float) -> Unit,
        isCancelled: () -> Boolean,
    ): List<ExtractedEntry> {
        val callbacks = Callbacks(File(destinationPath), onProgress, isCancelled)
        return try {
            extractNative(archivePath, password, callbacks).map { callbacks.entry(it) }.also { callbacks.verify() }
        } catch (error: Throwable) {
            callbacks.rollback()
            throw error
        }
    }

    private external fun extractNative(archivePath: String, password: String?, callbacks: Callbacks): Array<String>

    // Referenced by JNI: retain these method names if release minification is enabled.
    internal class Callbacks(
        private val requestedRoot: File,
        private val progress: (Float) -> Unit,
        private val cancellation: () -> Boolean,
    ) {
        private val root = requestedRoot.canonicalFile
        private val outputs = linkedMapOf<String, Pair<File, Long>>()
        private val metadata = mutableMapOf<String, ExtractedEntry>()
        private val fileKeys = hashSetOf<String>()
        private val directoryKeys = hashSetOf<String>()
        private var totalBytes = 0L
        private var ownsDestination = false

        fun recordTimes(name: String, modifiedMillis: Long, createdMillis: Long) {
            if (name !in outputs) throw IOException("Unexpected archive metadata path.")
            metadata[name] = ExtractedEntry(name, modifiedMillis.takeUnless { it == 0L }, createdMillis.takeUnless { it == 0L })
        }
        fun entry(name: String): ExtractedEntry = metadata[name] ?: ExtractedEntry(name, null, null)

        fun isCancelled(): Boolean = cancellation()
        fun onProgress(fraction: Float) = progress(fraction.coerceIn(0f, 1f))

        /** Return only destinations for visible supported images; reject path aliases before any writes. */
        fun reserve(name: String, size: Long): String? {
            if (cancellation()) throw InterruptedIOException("Archive import cancelled.")
            val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
            if (extension !in setOf("jpg", "jpeg", "png")) return null
            val parts = name.split('/')
            if (parts.any { it.startsWith('.') && it != "." && it != ".." }) return null
            if (name.isEmpty() || name.startsWith('/') || '\\' in name || ':' in name ||
                name.any { Character.isISOControl(it) } || name.toByteArray(Charsets.UTF_8).size > 4096 ||
                parts.any { it.isEmpty() || it == "." || it == ".." || it.toByteArray(Charsets.UTF_8).size > 255 }) {
                throw IOException("Unsafe archive image path.")
            }
            val keys = parts.map { Normalizer.normalize(it, Normalizer.Form.NFC).lowercase(Locale.ROOT) }
            val key = keys.joinToString("/")
            val parents = (1 until keys.size).map { keys.take(it).joinToString("/") }
            if (key in fileKeys || key in directoryKeys || parents.any { it in fileKeys }) {
                throw IOException("Conflicting archive filenames.")
            }
            if (outputs.size >= 25_000 || size < 0 || size > 512L * 1024 * 1024 ||
                totalBytes > 10L * 1024 * 1024 * 1024 - size) {
                throw IOException("Archive exceeds image count or uncompressed size limits.")
            }
            val output = File(root, name).canonicalFile
            if (!output.path.startsWith(root.path + File.separator)) throw IOException("Unsafe archive image path.")
            outputs[name] = output to size
            fileKeys += key
            directoryKeys += parents
            totalBytes += size
            return output.path
        }

        fun prepare() {
            if (cancellation()) throw InterruptedIOException("Archive import cancelled.")
            if (Files.isSymbolicLink(requestedRoot.toPath())) throw IOException("Extraction directory is a symbolic link.")
            if (root.exists() && (!root.isDirectory || root.list()?.isNotEmpty() != false)) {
                throw IOException("Extraction directory must be empty.")
            }
            if (!root.exists() && !root.mkdirs()) throw IOException("Cannot create extraction directory.")
            ownsDestination = true
            if (root.usableSpace < totalBytes + 100L * 1024 * 1024) throw IOException("Not enough free storage.")
            outputs.values.forEach { (file, _) ->
                val parent = file.parentFile ?: throw IOException("Invalid output path.")
                if (!parent.isDirectory && !parent.mkdirs()) throw IOException("Cannot create image directory.")
            }
        }

        fun verify() {
            outputs.values.forEach { (file, size) ->
                if (cancellation()) throw InterruptedIOException("Archive import cancelled.")
                if (!Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS) ||
                    file.canonicalFile != file || file.length() != size) {
                    throw IOException("Extracted image is incomplete or unsafe.")
                }
            }
        }

        fun rollback() {
            if (ownsDestination) root.deleteRecursively()
        }
    }
}
