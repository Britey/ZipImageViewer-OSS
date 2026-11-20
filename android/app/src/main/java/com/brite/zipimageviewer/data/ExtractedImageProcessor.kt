package com.brite.zipimageviewer.data

import android.app.ActivityManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.os.Debug
import com.brite.zipimageviewer.nativebridge.NativeJpegXl
import com.brite.zipimageviewer.nativebridge.ImageOrientation
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.text.Normalizer
import java.util.Locale
import java.util.UUID
import java.nio.file.Files
import kotlin.math.roundToInt

/** Prepares only disposable extraction staging; it never mutates source documents or published pages. */
class ExtractedImageProcessor(
    private val context: Context,
    private val availableMemory: () -> Long = { availablePreparationMemory(context) },
    private val observe: (String, String, Long) -> Unit = { _, _, _ -> },
) {
    fun prepare(
        root: File,
        pages: List<PageRecord>,
        compress: Boolean,
        checkCancellation: () -> Unit = {},
        progress: (Float) -> Unit = {},
    ): List<PageRecord> {
        if (Files.isSymbolicLink(root.toPath()) || !root.isDirectory) throw ImportFailure("Image staging root is unsafe.")
        // Resolve OS-owned aliases above the extraction root (e.g. /data/user/0), not archive descendants.
        val trustedRoot = root.canonicalFile
        val aliases = mutableSetOf<String>()
        val originals = pages.map { page ->
            checkCancellation()
            val file = ArchiveOutputPolicy.containedFile(trustedRoot, page.storedPath)
            if (file.canonicalFile != file.absoluteFile) throw ImportFailure("Image path contains a symbolic link.")
            ArchiveDiskUsage.requireRegularFile(file)
            val key = Normalizer.normalize(page.storedPath, Normalizer.Form.NFC).lowercase(Locale.ROOT)
            if (!aliases.add(key)) throw ImportFailure("Image paths alias the same file.")
            page to file
        }
        if (originals.isEmpty()) { progress(1f); return emptyList() }
        val generatedName = ".ziv-prepared-${UUID.randomUUID()}"
        val generated = File(trustedRoot, generatedName)
        if (!generated.mkdir()) throw ImportFailure("Image preparation storage could not be created.")
        val result = originals.mapIndexed { index, (page, file) ->
            checkCancellation()
            val prepared = prepareOne(page, file, generated, generatedName, index, compress, checkCancellation)
            progress((index + 1f) / originals.size)
            prepared
        }
        checkCancellation()
        if (generated.list()?.isEmpty() == true && !generated.delete()) throw ImportFailure("Empty preparation directory could not be removed.")
        return result
    }

    private fun prepareOne(page: PageRecord, source: File, generated: File, generatedName: String, index: Int, compress: Boolean, check: () -> Unit): PageRecord {
        var result = page
        val size = source.length()
        if (size !in 1..ImagePreparationPolicy.MAX_INPUT) { observe(page.originalPath, "input-size", 0); return result }
        val info = NativeJpegXl.inspect(source.absolutePath) ?: run { observe(page.originalPath, "unreadable-image", 0); return result }
        if (!ImagePreparationPolicy.eligible(info.width, info.height, info.frameCount, size)) {
            observe(page.originalPath, "dimensions-or-frames", 0); return result
        }
        val pixels = info.width.toLong() * info.height
        val originalAllocated = ArchiveDiskUsage.allocatedBytes(source)
        val preview = File(generated, "$index.preview.jpg")
        check()
        if (ImagePreparationPolicy.previewEstimate(pixels, size) <= ImagePreparationPolicy.phaseAllowance(availableMemory())) {
            previewData(source, info)?.let { bytes ->
                check()
                writeSynced(preview, bytes)
                result = result.copy(previewPath = "$generatedName/${preview.name}")
            }
        }
        check()
        if (!compress || size < 16 * 1024 || info.bitDepth > 8 || info.format !in setOf("jpeg", "png")) {
            observe(page.originalPath, if (!compress) "compression-off" else "ineligible-conversion", 0); return result
        }
        val jpeg = info.format == "jpeg"
        if (!jpeg && ImagePreparationPolicy.pngPreparationEstimate(pixels, size) > minOf(512 * ImagePreparationPolicy.MIB, ImagePreparationPolicy.phaseAllowance(availableMemory()))) {
            observe(page.originalPath, "png-preparation-memory", 0); return result
        }
        val codecBudget = ImagePreparationPolicy.codecBudget(pixels, size, jpeg, availableMemory())
            ?: run { observe(page.originalPath, "codec-admission", 0); return result }
        val candidate = File(generated, "$index.jxl")
        check()
        val encoded = NativeJpegXl.encode(source.absolutePath, candidate.absolutePath, codecBudget)
        check()
        if (!encoded.succeeded) {
            deleteCandidate(candidate)
            observe(page.originalPath, encoded.failure ?: "codec-fallback", encoded.peakCodecBytes)
            return result
        }
        // The encoder and its bounded buffers have returned before the independent full decoder runs.
        val valid = ImagePreparationPolicy.validationEstimate(pixels, size) <= ImagePreparationPolicy.phaseAllowance(availableMemory()) &&
            NativeJpegXl.validate(candidate.absolutePath, info.width, info.height, info.orientation,
                minOf(384 * ImagePreparationPolicy.MIB, ImagePreparationPolicy.phaseAllowance(availableMemory())))
        check()
        if (!valid || !ImagePreparationPolicy.profitable(size, candidate.length(), if (result.previewPath == null) 0 else preview.length(),
                originalAllocated, ArchiveDiskUsage.allocatedBytes(candidate), if (result.previewPath == null) 0 else ArchiveDiskUsage.allocatedBytes(preview))) {
            deleteCandidate(candidate)
            observe(page.originalPath, if (!valid) "replacement-validation" else "not-profitable", encoded.peakCodecBytes)
            return result
        }
        FileOutputStream(candidate, true).use { it.fd.sync() }
        check()
        if (!source.delete()) throw ImportFailure("An original staging image could not be replaced.")
        observe(page.originalPath, "converted", encoded.peakCodecBytes)
        return result.copy(storedPath = "$generatedName/${candidate.name}", processingPolicy = if (jpeg) ImagePreparationPolicy.JPEG_POLICY else ImagePreparationPolicy.PNG_POLICY)
    }

    private fun deleteCandidate(candidate: File) {
        if (candidate.exists() && !candidate.delete()) throw ImportFailure("An unused encoded image could not be removed.")
    }

    private fun writeSynced(file: File, bytes: ByteArray) {
        FileOutputStream(file).use { it.write(bytes); it.fd.sync() }
    }

    /** PNG eXIf is not applied by Android ImageDecoder on all APIs; transform raw PNG pixels explicitly. */
    private fun previewData(source: File, sourceInfo: NativeJpegXl.ImageInfo): ByteArray? {
        var image: Bitmap? = null
        var flattened: Bitmap? = null
        return try {
            image = if (sourceInfo.format == "png") {
                val options = BitmapFactory.Options().apply {
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                    inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
                    inSampleSize = 1
                    while (maxOf(sourceInfo.width, sourceInfo.height) / (inSampleSize * 2) >= 384) inSampleSize *= 2
                }
                val raw = BitmapFactory.decodeFile(source.path, options) ?: return null
                val oriented = try { ImageOrientation.orientBitmap(raw, sourceInfo.orientation) }
                    catch (error: Throwable) { raw.recycle(); throw error }
                if (oriented !== raw) raw.recycle()
                oriented
            } else ImageDecoder.decodeBitmap(ImageDecoder.createSource(source)) { decoder, info, _ ->
                val scale = minOf(1.0, 384.0 / maxOf(info.size.width, info.size.height))
                decoder.setTargetSize((info.size.width * scale).roundToInt().coerceAtLeast(1), (info.size.height * scale).roundToInt().coerceAtLeast(1))
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
            }
            if (maxOf(image.width, image.height) > 384) {
                val scale = 384.0 / maxOf(image.width, image.height)
                val scaled = Bitmap.createScaledBitmap(image, (image.width * scale).roundToInt().coerceAtLeast(1),
                    (image.height * scale).roundToInt().coerceAtLeast(1), true)
                if (scaled !== image) image.recycle()
                image = scaled
            }
            flattened = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888, false, ColorSpace.get(ColorSpace.Named.SRGB))
            Canvas(flattened).apply { drawColor(Color.WHITE); drawBitmap(image, 0f, 0f, null) }
            ByteArrayOutputStream().use { bytes -> if (flattened.compress(Bitmap.CompressFormat.JPEG, 75, bytes)) bytes.toByteArray() else null }
        } catch (_: IOException) { null }
          catch (_: IllegalArgumentException) { null }
          catch (_: OutOfMemoryError) { null }
        finally { image?.recycle(); flattened?.recycle() }
    }

    companion object {
        /** Native phase admission uses system pressure and current process PSS, not the Java heap limit. */
        fun availablePreparationMemory(context: Context): Long {
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val memory = ActivityManager.MemoryInfo().also(manager::getMemoryInfo)
            if (memory.lowMemory) return 0
            val systemHeadroom = (memory.availMem - maxOf(256 * ImagePreparationPolicy.MIB, memory.totalMem / 10)).coerceAtLeast(0)
            val nativeEnvelope = minOf(2048 * ImagePreparationPolicy.MIB, maxOf(768 * ImagePreparationPolicy.MIB, memory.totalMem / 2))
            val processHeadroom = (nativeEnvelope - Debug.getPss() * 1024).coerceAtLeast(0)
            return minOf(systemHeadroom, processHeadroom)
        }
    }
}
