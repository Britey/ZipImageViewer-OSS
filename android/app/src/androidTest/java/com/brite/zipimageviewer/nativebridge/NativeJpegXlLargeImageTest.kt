package com.brite.zipimageviewer.nativebridge

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Debug
import com.brite.zipimageviewer.data.ExtractedImageProcessor
import com.brite.zipimageviewer.data.ImagePreparationPolicy
import com.brite.zipimageviewer.data.PageRecord
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import java.io.DataOutputStream
import java.io.File
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.CRC32
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Slow real-admission import and reader probes; run separately from interactive UI tests. */
@LargeTest
@RunWith(AndroidJUnit4::class)
class NativeJpegXlLargeImageTest {
    @Test fun originalResolution12Megapixels() = exercise(4000, 3000)
    @Test fun originalResolution24Megapixels() = exercise(6000, 4000)
    @Test fun originalResolution32Megapixels() = exercise(8000, 4000)

    private fun exercise(width: Int, height: Int) {
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "large-jxl-${UUID.randomUUID()}")
        check(root.mkdirs())
        try {
            for (format in listOf("png", "jpg")) {
                val source = File(root, "source.$format")
                if (format == "png") writePng(source, width, height) else writeJpeg(source, width, height)
                assertTrue(source.length() >= 16384)
                val info = requireNotNull(NativeJpegXl.inspect(source.path))
                assertEquals(width, info.width); assertEquals(height, info.height)
                val originalSize = source.length()
                val originalHash = if (format == "jpg") sha256(source) else null
                val context = InstrumentationRegistry.getInstrumentation().targetContext
                val headroom = ExtractedImageProcessor.availablePreparationMemory(context)
                val observations = mutableListOf<Pair<String, Long>>()
                val processor = ExtractedImageProcessor(context, observe = { _, reason, peak ->
                    observations += reason to peak
                    Log.i("JxlLargeTest", "${width}x$height $format reason=$reason peakCodec=$peak")
                })
                val start = System.nanoTime()
                // Use the real production admission, preview, validation and profitability path.
                // Do not inject artificial memory headroom: failure must reveal a practical limit.
                val page = processor.prepare(root, listOf(PageRecord(source.name, source.name)), compress = true).single()
                val expectedPolicy = if (format == "png") ImagePreparationPolicy.PNG_POLICY else ImagePreparationPolicy.JPEG_POLICY
                assertEquals("${width}x$height $format headroom=$headroom PSS=${Debug.getPss()*1024} decisions=$observations",
                    expectedPolicy, page.processingPolicy)
                assertFalse("The verified candidate must replace only the staging original", source.exists())
                assertEquals(source.name, page.originalPath)
                val candidate = File(root, page.storedPath)
                val persistedPreview = File(root, requireNotNull(page.previewPath))
                assertTrue(candidate.isFile); assertTrue(persistedPreview.isFile)
                assertTrue(candidate.length() + persistedPreview.length() < originalSize)
                val cachedPreview = requireNotNull(BitmapFactory.decodeFile(persistedPreview.path))
                try { assertEquals(384, maxOf(cachedPreview.width, cachedPreview.height)) }
                finally { cachedPreview.recycle() }
                Log.i("JxlLargeTest", "${width}x$height $format bytes=$originalSize encoded=${candidate.length()} preview=${persistedPreview.length()} availableBefore=$headroom PSS=${Debug.getPss()*1024} elapsedMs=${(System.nanoTime()-start)/1_000_000}")
                assertTrue(NativeJpegXl.validate(candidate.path, width, height, 1))
                val detailCap = 384L*1024*1024 - 30L*1024*1024 - candidate.length() - 4L*1024*1024
                val detail = requireNotNull(NativeJpegXl.decode(candidate.path, 16384, 30L*1024*1024/4, detailCap))
                assertTrue(detail.allocationByteCount <= 30L*1024*1024)
                detail.recycle()
                val preview = requireNotNull(NativeJpegXl.decode(candidate.path, 384, 384L*384, detailCap))
                assertEquals(384, maxOf(preview.width, preview.height)); preview.recycle()
                if (format == "jpg") {
                    val restored = File(root, "restored.jpg")
                    assertTrue(NativeJpegXl.reconstructJpeg(candidate.path, restored.path, originalSize))
                    assertArrayEquals(originalHash, sha256(restored)); restored.delete()
                }
                source.delete(); candidate.delete()
            }
        } finally { root.deleteRecursively() }
    }
    private fun rgb(x: Int, y: Int): Int {
        val noise = ((x * 17 xor y * 31) and 15)
        val r = ((x / 8 + noise) and 255)
        val g = ((y / 8 + noise) and 255)
        val b = ((((x / 96 + y / 96) and 1) * 160 + noise + 30) and 255)
        return (r shl 16) or (g shl 8) or b
    }
    private fun writeJpeg(file: File, width: Int, height: Int) {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            val row = IntArray(width)
            for (y in 0 until height) {
                for (x in 0 until width) row[x] = rgb(x,y) or (0xff shl 24)
                bitmap.setPixels(row, 0, width, 0, y, width, 1)
            }
            file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 93, it)) }
        } finally { bitmap.recycle() }
    }
    private fun writePng(file: File, width: Int, height: Int) {
        DataOutputStream(file.outputStream().buffered()).use { out ->
            out.write(byteArrayOf(137.toByte(),80,78,71,13,10,26,10))
            val header = java.io.ByteArrayOutputStream()
            DataOutputStream(header).use { it.writeInt(width); it.writeInt(height); it.write(byteArrayOf(8,2,0,0,0)) }
            writeChunk(out, "IHDR", header.toByteArray())
            val chunks = object : OutputStream() {
                private val buffer = ByteArray(65536)
                private var count = 0
                override fun write(value: Int) { buffer[count++] = value.toByte(); if (count == buffer.size) flush() }
                override fun write(bytes: ByteArray, offset: Int, length: Int) {
                    var position=offset; var remaining=length
                    while(remaining>0) {
                        val n=minOf(remaining,buffer.size-count); bytes.copyInto(buffer,count,position,position+n)
                        count+=n;position+=n;remaining-=n;if(count==buffer.size)flush()
                    }
                }
                override fun flush() { if(count>0)writeChunk(out,"IDAT",buffer.copyOf(count));count=0 }
                override fun close() { flush() }
            }
            val deflater = Deflater(Deflater.NO_COMPRESSION)
            try {
                DeflaterOutputStream(chunks, deflater, 65536).use { compressed ->
                    val row=ByteArray(width*3+1)
                    for(y in 0 until height) {
                        for(x in 0 until width) {val color=rgb(x,y); row[x*3+1]=(color shr 16).toByte();row[x*3+2]=(color shr 8).toByte();row[x*3+3]=color.toByte()}
                        compressed.write(row)
                    }
                }
            } finally { deflater.end() }
            writeChunk(out,"IEND",ByteArray(0))
        }
    }
    private fun writeChunk(out: DataOutputStream, type: String, bytes: ByteArray) {
        val kind=type.toByteArray(Charsets.US_ASCII);out.writeInt(bytes.size);out.write(kind);out.write(bytes)
        val crc=CRC32().apply{update(kind);update(bytes)};out.writeInt(crc.value.toInt())
    }
    private fun sha256(file: File): ByteArray {
        val hash=MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input -> val buffer=ByteArray(65536);while(true){val n=input.read(buffer);if(n<0)break;hash.update(buffer,0,n)} }
        return hash.digest()
    }
}
