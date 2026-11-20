package com.brite.zipimageviewer.reader

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.produceState
import com.brite.zipimageviewer.nativebridge.NativeJpegXl
import com.brite.zipimageviewer.nativebridge.ImageOrientation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.io.File
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.coroutines.coroutineContext
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sqrt

internal sealed interface BitmapState {
    data object Loading : BitmapState
    data object Failed : BitmapState
    data class Ready(val bitmap: Bitmap) : BitmapState
}

internal enum class ReaderDecodeKind { PREVIEW, FITTED, DETAIL }

/** Shared admission covers reader lanes, overview and library-cover decodes. */
internal object ReaderDecodeMemory {
    const val MAX_BYTES = 384L * 1024 * 1024
    private val lock = ReentrantLock()
    private val changed = lock.newCondition()
    private var used = 0L
    fun acquire(bytes: Long): Boolean {
        if (bytes <= 0 || bytes > MAX_BYTES) return false
        lock.withLock {
            while (used + bytes > MAX_BYTES) changed.await()
            used += bytes
        }
        return true
    }
    fun release(bytes: Long) = lock.withLock { used -= bytes; changed.signalAll() }
    internal fun usedBytes(): Long = lock.withLock { used }
}

/** Cache is 48 MiB; each output is <=30 MiB ARGB8888 with source guards before decode. */
internal object ReaderBitmapDecoder {
    const val MAX_OUTPUT_PIXELS = 30L * 1024 * 1024 / 4
    private const val CACHE_BYTES = 48 * 1024 * 1024
    private var generation = 0L
    private val previewSlots = Semaphore(2)
    private val imageSlots = Semaphore(1)
    private val cache = object : LruCache<String, Bitmap>(CACHE_BYTES) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
    }
    fun clearCache() = synchronized(cache) { generation++; cache.evictAll() }
    internal fun cachedBytes(): Int = synchronized(cache) { cache.size() }
    fun supportedSource(width: Int, height: Int): Boolean = width in 1..100_000 && height in 1..100_000 && width.toLong() * height <= 32_000_000L
    internal fun outputSize(width: Int, height: Int, edge: Int): Pair<Int, Int> {
        val scale = min(1.0, min(edge.toDouble() / maxOf(width, height), sqrt(MAX_OUTPUT_PIXELS.toDouble() / (width.toLong() * height))))
        return maxOf(1, floor(width * scale).toInt()) to maxOf(1, floor(height * scale).toInt())
    }
    suspend fun decode(file: File, target: Int, thumbnail: Boolean): Bitmap? =
        decode(file, if (thumbnail) ReaderDecodeKind.PREVIEW else ReaderDecodeKind.FITTED, target)

    suspend fun decode(file: File, kind: ReaderDecodeKind, viewport: Int): Bitmap? =
        (if (kind == ReaderDecodeKind.PREVIEW) previewSlots else imageSlots).withPermit { decodeAdmitted(file, kind, viewport) }

    private suspend fun decodeAdmitted(file: File, kind: ReaderDecodeKind, viewport: Int): Bitmap? = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        val edge = when (kind) { ReaderDecodeKind.PREVIEW -> 384; ReaderDecodeKind.FITTED -> viewport.coerceIn(384, 3072); ReaderDecodeKind.DETAIL -> 16384 }
        val key = "${file.absolutePath}:${file.lastModified()}:${file.length()}:$edge"
        val cacheGeneration = synchronized(cache) { cache.get(key)?.let { return@withContext it }; generation }
        var admitted = 0L
        try {
            val sourceBounds = if (!file.extension.equals("jxl", ignoreCase = true)) BitmapFactory.Options().apply {
                inJustDecodeBounds = true
                BitmapFactory.decodeFile(file.absolutePath, this)
            } else null
            val image = (if (file.extension.equals("jxl", ignoreCase = true)) {
                val inputBytes = file.length()
                if (inputBytes !in 1..128L * 1024 * 1024) return@withContext null
                val metadataBytes = inputBytes + 4 * 1024 * 1024
                if (!ReaderDecodeMemory.acquire(metadataBytes)) return@withContext null
                val info = try { NativeJpegXl.inspect(file.absolutePath) } finally { ReaderDecodeMemory.release(metadataBytes) }
                    ?: return@withContext null
                if (!supportedSource(info.width, info.height) || info.frameCount != 1) return@withContext null
                val (w, h) = outputSize(info.width, info.height, edge)
                val outputBytes = w.toLong() * h * 4
                // Native resampling's 16-byte accumulator is inside its custom codec cap.
                // The compressed input and Android Bitmap are outside that allocator.
                // Reserve the validated complete phase budget rather than guessing a smaller
                // codec working set from dimensions; JPEG XL content affects scratch needs.
                val codecBudget = ReaderDecodeMemory.MAX_BYTES - inputBytes - outputBytes - 4 * 1024 * 1024
                if (codecBudget <= 0) return@withContext null
                val estimate = codecBudget + inputBytes + outputBytes + 4 * 1024 * 1024
                if (!ReaderDecodeMemory.acquire(estimate)) return@withContext null
                admitted = estimate
                NativeJpegXl.decode(file.absolutePath, edge, MAX_OUTPUT_PIXELS, codecBudget)
            } else if (sourceBounds?.outMimeType == "image/png") {
                // BitmapFactory returns stored PNG pixels; unlike ImageDecoder, its lack of
                // EXIF auto-rotation is explicit. Apply every PNG eXIf orientation exactly once.
                val bounds = sourceBounds
                if (!supportedSource(bounds.outWidth, bounds.outHeight)) return@withContext null
                val (w, h) = outputSize(bounds.outWidth, bounds.outHeight, edge)
                val estimate = bounds.outWidth.toLong() * bounds.outHeight * 8 + w.toLong() * h * 12 + 4 * 1024 * 1024
                if (!ReaderDecodeMemory.acquire(estimate)) return@withContext null
                admitted = estimate
                val orientation = ImageOrientation.readPngOrientation(file)
                var sample = 1
                while (bounds.outWidth / (sample * 2) >= w && bounds.outHeight / (sample * 2) >= h) sample *= 2
                var prepared = BitmapFactory.decodeFile(file.absolutePath, BitmapFactory.Options().apply {
                    inSampleSize = sample
                    // Density resampling keeps detail close to its actual pixel budget rather
                    // than rounding every 12MP page down to a coarse 3MP power-of-two sample.
                    inScaled = true
                    inDensity = maxOf(bounds.outWidth, bounds.outHeight)
                    inTargetDensity = maxOf(w, h) * sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                }) ?: return@withContext null
                if (prepared.config == Bitmap.Config.RGBA_F16) {
                    val converted = prepared.copy(Bitmap.Config.ARGB_8888, false) ?: return@withContext null
                    prepared.recycle(); prepared = converted
                }
                if (prepared.width != w || prepared.height != h) {
                    val scaled = Bitmap.createScaledBitmap(prepared, w, h, true)
                    if (scaled !== prepared) prepared.recycle()
                    prepared = scaled
                }
                val oriented = ImageOrientation.orientBitmap(prepared, orientation)
                if (oriented !== prepared) prepared.recycle()
                oriented
            } else {
                ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                    if (!supportedSource(info.size.width, info.size.height)) throw IllegalArgumentException("Image exceeds reader source limits")
                    val (w, h) = outputSize(info.size.width, info.size.height, edge)
                    val estimate = info.size.width.toLong() * info.size.height * 8 + w.toLong() * h * 12 + 4 * 1024 * 1024
                    if (!ReaderDecodeMemory.acquire(estimate)) throw IllegalArgumentException("Image exceeds transient memory admission")
                    admitted = estimate
                    decoder.setTargetSize(w, h)
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                }
            }) ?: return@withContext null
            // F16 sources can require twice the display budget. Convert at the bounded size,
            // retaining the Bitmap color space, before entering the resident cache.
            val bitmap = if (image.config == Bitmap.Config.RGBA_F16) image.copy(Bitmap.Config.ARGB_8888, false).also { image.recycle() } else image
            if (bitmap == null || bitmap.allocationByteCount > 30 * 1024 * 1024) return@withContext null
            coroutineContext.ensureActive()
            synchronized(cache) { if (cacheGeneration == generation) cache.put(key, bitmap) }
            bitmap
        } catch (_: java.io.IOException) { null }
          catch (_: IllegalArgumentException) { null }
          catch (_: OutOfMemoryError) { clearCache(); null }
        finally { if (admitted > 0) ReaderDecodeMemory.release(admitted) }
    }

    suspend fun decodePage(page: ReaderPage, kind: ReaderDecodeKind, viewport: Int): Bitmap? {
        val preview = page.previewFile.takeIf { kind == ReaderDecodeKind.PREVIEW }
        return (preview?.let { decode(it, kind, viewport) }) ?: decode(page.file, kind, viewport)
    }
}

@Composable
internal fun rememberReaderBitmap(page: ReaderPage?, target: Int, thumbnail: Boolean = false, retainImageWork: (() -> (() -> Unit))? = null): State<BitmapState> =
    produceState<BitmapState>(BitmapState.Loading, page?.file?.absolutePath, page?.previewFile?.absolutePath, target, thumbnail) {
        value = BitmapState.Loading
        // Acquire before dispatch so deletion cannot race a queued thumbnail job.
        val release = try { retainImageWork?.invoke() } catch (_: Exception) {
            value = BitmapState.Failed
            return@produceState
        }
        try {
            val image = page?.let { ReaderBitmapDecoder.decodePage(it, if (thumbnail) ReaderDecodeKind.PREVIEW else ReaderDecodeKind.FITTED, target) }
            value = image?.let { BitmapState.Ready(it) } ?: BitmapState.Failed
        } finally { release?.invoke() }
    }
