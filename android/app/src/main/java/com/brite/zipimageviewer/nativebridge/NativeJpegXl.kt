package com.brite.zipimageviewer.nativebridge

import android.graphics.Bitmap
import android.graphics.ColorSpace
import java.io.IOException
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sqrt

/** Synchronous single-image codec calls. Call from an admitted IO worker, never the UI thread. */
object NativeJpegXl {
    init { System.loadLibrary("zipimageviewer_jxl") }

    data class ImageInfo(val format: String, val width: Int, val height: Int, val orientation: Int,
                         val bitDepth: Int, val frameCount: Int)
    data class EncodeResult(val bytesWritten: Long, val peakCodecBytes: Long, val failure: String?) {
        val succeeded: Boolean get() = bytesWritten > 0 && failure == null
    }

    @Throws(IOException::class)
    fun inspect(path: String): ImageInfo? {
        val info = inspectNative(path) ?: return null
        return ImageInfo(arrayOf("unknown", "jpeg", "png", "jxl")[info[0].toInt()],
            info[1].toInt(), info[2].toInt(), info[3].toInt(), info[4].toInt(), info[5].toInt())
    }

    @Throws(IOException::class)
    fun encode(sourcePath: String, destinationPath: String, memoryLimit: Long): EncodeResult {
        require(memoryLimit in 1..1280L * 1024 * 1024)
        val result = encodeNative(sourcePath, destinationPath, memoryLimit)
        val failure = when (result[2].toInt()) {
            0 -> null
            1 -> "unsupported_input"
            2 -> "codec_or_output_capacity_failure"
            3 -> "allocation_failure"
            else -> "codec_failure"
        }
        return EncodeResult(result[0], result[1], failure)
    }

    fun validate(path: String, width: Int, height: Int, orientation: Int,
                 memoryLimit: Long = 384L * 1024 * 1024): Boolean =
        validateNative(path, width, height, orientation, memoryLimit)

    /** Scanline accumulation resamples into a bounded output, with no full-resolution output Bitmap. */
    @Throws(IOException::class)
    fun decode(path: String, maxDimension: Int, maxPixels: Long,
               memoryLimit: Long = 384L * 1024 * 1024): Bitmap? {
        require(maxDimension > 0 && maxPixels > 0 && memoryLimit > 0)
        val info = inspect(path) ?: return null
        if (info.format != "jxl" || info.frameCount != 1 || info.width <= 0 || info.height <= 0 ||
            info.width.toLong() * info.height > 32_000_000 || maxOf(info.width, info.height) > 100_000) return null
        val width = if (info.orientation in 5..8) info.height else info.width
        val height = if (info.orientation in 5..8) info.width else info.height
        val scale = min(1.0, min(maxDimension.coerceAtMost(16384).toDouble() / maxOf(width, height),
            sqrt(maxPixels.toDouble() / (width.toLong() * height))))
        var targetWidth = floor(width * scale).toInt().coerceAtLeast(1)
        var targetHeight = floor(height * scale).toInt().coerceAtLeast(1)
        // Very thin images can round their short axis up to one pixel. Keep
        // the caller's area bound exact even when that changes the aspect ratio.
        if (targetWidth.toLong() * targetHeight > maxPixels) {
            if (targetWidth >= targetHeight) targetWidth = (maxPixels / targetHeight).toInt().coerceAtLeast(1)
            else targetHeight = (maxPixels / targetWidth).toInt().coerceAtLeast(1)
        }
        val bitmap = try {
            Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888, false,
                ColorSpace.get(ColorSpace.Named.DISPLAY_P3))
        } catch (_: OutOfMemoryError) { return null }
        return try {
            if (decodeNative(path, bitmap, memoryLimit)) bitmap else { bitmap.recycle(); null }
        } catch (error: Throwable) { bitmap.recycle(); throw error }
    }

    @Throws(IOException::class)
    fun reconstructJpeg(path: String, destinationPath: String, capacity: Long): Boolean =
        reconstructNative(path, destinationPath, capacity)

    private external fun inspectNative(path: String): LongArray?
    private external fun encodeNative(source: String, destination: String, memoryLimit: Long): LongArray
    private external fun validateNative(path: String, width: Int, height: Int, orientation: Int, memoryLimit: Long): Boolean
    private external fun decodeNative(path: String, bitmap: Bitmap, memoryLimit: Long): Boolean
    private external fun reconstructNative(path: String, destination: String, capacity: Long): Boolean
}
