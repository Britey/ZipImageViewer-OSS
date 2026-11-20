package com.brite.zipimageviewer.nativebridge

import android.graphics.Bitmap
import android.graphics.Matrix
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile

/** Apply EXIF orientation only to pixels a decoder returned in their raw stored orientation. */
object ImageOrientation {
    /** Read PNG eXIf without loading IDAT/ancillary data or imposing the conversion input limit. */
    fun readPngOrientation(file: File): Int = try {
        RandomAccessFile(file, "r").use { input ->
            val fileSize = input.length()
            if (fileSize < 8 || input.readInt() != 0x89504e47L.toInt() || input.readInt() != 0x0d0a1a0a) return@use 1
            var position = 8L
            repeat(100_000) {
                if (position > fileSize - 12) return@use 1
                input.seek(position)
                val length = input.readInt().toLong() and 0xffffffffL
                val type = input.readInt()
                if (length > fileSize - position - 12) return@use 1
                if (type == 0x65584966 && length >= 8) { // eXIf: inline TIFF, no JPEG Exif prefix
                    val start = position + 8
                    val order = input.readUnsignedShort()
                    if (order != 0x4949 && order != 0x4d4d) return@use 1
                    val little = order == 0x4949
                    fun short(): Int = input.readUnsignedShort().let { if (little) java.lang.Short.reverseBytes(it.toShort()).toInt() and 0xffff else it }
                    fun uint(): Long = input.readInt().let { if (little) Integer.reverseBytes(it) else it }.toLong() and 0xffffffffL
                    if (short() != 42) return@use 1
                    val offset = uint()
                    if (offset > length - 2) return@use 1
                    input.seek(start + offset)
                    val count = short()
                    for (index in 0 until count) {
                        val entry = offset + 2 + index.toLong() * 12
                        if (entry > length - 12) return@use 1
                        input.seek(start + entry)
                        val tag = short()
                        val kind = short()
                        val values = uint()
                        if (tag == 0x112 && kind == 3 && values == 1L) return@use short().takeIf { it in 1..8 } ?: 1
                    }
                    return@use 1
                }
                if (type == 0x49454e44) return@use 1 // IEND
                position += length + 12
            }
            1
        }
    } catch (_: IOException) { 1 }

    /** Identity returns [bitmap]; otherwise returns a new bitmap. Caller retains ownership of both. */
    fun orientBitmap(bitmap: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            2 -> matrix.setScale(-1f, 1f)
            3 -> matrix.setRotate(180f)
            4 -> matrix.setScale(1f, -1f)
            5 -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
            6 -> matrix.setRotate(90f)
            7 -> { matrix.setRotate(-90f); matrix.postScale(-1f, 1f) }
            8 -> matrix.setRotate(-90f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, false)
    }
}
