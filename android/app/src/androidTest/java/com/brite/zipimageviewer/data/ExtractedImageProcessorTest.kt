package com.brite.zipimageviewer.data

import android.graphics.BitmapFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.brite.zipimageviewer.nativebridge.NativeJpegXl
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class ExtractedImageProcessorTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val assets get() = InstrumentationRegistry.getInstrumentation().context.assets
    private lateinit var root: File
    @Before fun createRoot() { root = File(context.filesDir, "preparation-test-${UUID.randomUUID()}").apply { mkdirs() } }
    @After fun removeRoot() { root.deleteRecursively() }

    @Test fun compressionOffKeepsOriginalBytesAndProducesOriented384PixelPreviews() {
        val jpeg = fixture("pattern-rgb.jpg")
        val png = fixture("pattern-rgba-p3.png")
        val hashes = listOf(jpeg, png).associate { it.name to hash(it) }
        val result = processor().prepare(root, listOf(page(jpeg), page(png)), false)
        result.forEach {
            assertEquals(it.originalPath, it.storedPath)
            assertEquals(hashes[it.originalPath], hash(File(root, it.storedPath)))
            assertNull(it.processingPolicy)
            assertNotNull(it.previewPath)
            val preview = BitmapFactory.decodeFile(File(root, it.previewPath!!).path)!!
            assertEquals(384, maxOf(preview.width, preview.height))
            if (it.originalPath.endsWith(".png")) assertTrue("EXIF 6 rotates landscape source to portrait preview", preview.height > preview.width)
            preview.recycle()
        }
    }

    @Test fun jpegReplacementReconstructsCompleteOriginalBitstreamAndKeepsPageIdentity() {
        val source = fixture("pattern-rgb.jpg")
        val originalHash = hash(source)
        val originalSize = source.length()
        val result = processor().prepare(root, listOf(page(source).copy(modifiedAt = 123, createdAt = 456)), true).single()
        assertEquals("pattern-rgb.jpg", result.originalPath)
        assertEquals(ImagePreparationPolicy.JPEG_POLICY, result.processingPolicy)
        assertTrue(result.storedPath.endsWith(".jxl"))
        assertFalse(source.exists())
        assertEquals(123L, result.modifiedAt)
        assertEquals(456L, result.createdAt)
        val reconstructed = File(root, "reconstructed.jpg")
        assertTrue(NativeJpegXl.reconstructJpeg(File(root, result.storedPath).path, reconstructed.path, originalSize))
        assertEquals(originalHash, hash(reconstructed))
    }

    @Test fun pngReplacementUsesOriginalDimensionsOrientationAndIndependentOriginalIdentity() {
        val source = fixture("pattern-rgba-p3.png")
        val originalInfo = NativeJpegXl.inspect(source.path)!!
        val originalLogical = source.length()
        val originalAllocated = ArchiveDiskUsage.allocatedBytes(source)
        val result = processor().prepare(root, listOf(page(source)), true).single()
        assertEquals(ImagePreparationPolicy.PNG_POLICY, result.processingPolicy)
        val detailed = File(root, result.storedPath)
        val preview = File(root, result.previewPath!!)
        assertTrue(NativeJpegXl.validate(detailed.path, originalInfo.width, originalInfo.height, originalInfo.orientation))
        assertTrue(ImagePreparationPolicy.profitable(originalLogical, detailed.length(), preview.length(), originalAllocated,
            ArchiveDiskUsage.allocatedBytes(detailed), ArchiveDiskUsage.allocatedBytes(preview)))
        assertFalse(source.exists())
        val display = NativeJpegXl.decode(detailed.path, 1600, 1_000_000)!!
        assertEquals(600, display.width)
        assertEquals(800, display.height)
        display.recycle()
    }

    @Test fun grayscaleConvertsAndHighBitDepthRetainsItsDetailedOriginal() {
        val gray = fixture("pattern-gray.png")
        val high = fixture("high-depth.png")
        val highHash = hash(high)
        val result = processor().prepare(root, listOf(page(gray), page(high)), true)
        assertEquals(ImagePreparationPolicy.PNG_POLICY, result[0].processingPolicy)
        assertEquals(high.name, result[1].storedPath)
        assertNull(result[1].processingPolicy)
        assertEquals(highHash, hash(high))
    }

    @Test fun previewAdmissionFailureDoesNotDisableOtherwiseViableConversion() {
        val source = fixture("pattern-rgb.jpg")
        var calls = 0
        val processor = ExtractedImageProcessor(context, availableMemory = { if (calls++ == 0) 0 else Long.MAX_VALUE })
        val result = processor.prepare(root, listOf(page(source)), true).single()
        assertEquals(ImagePreparationPolicy.JPEG_POLICY, result.processingPolicy)
        assertNull(result.previewPath)
    }

    @Test fun memoryPressureAfterPreviewRetainsOriginalAndKeepsCompletedPreview() {
        val source = fixture("pattern-rgb.jpg")
        val originalHash = hash(source)
        var calls = 0
        val result = ExtractedImageProcessor(context, availableMemory = { if (calls++ == 0) Long.MAX_VALUE else 0 })
            .prepare(root, listOf(page(source)), true).single()
        assertEquals(source.name, result.storedPath)
        assertNotNull(result.previewPath)
        assertNull(result.processingPolicy)
        assertEquals(originalHash, hash(source))
    }

    @Test fun pressureBeforeReplacementDecodeDeletesCandidateWithoutRemovingOriginal() {
        val source = fixture("pattern-rgb.jpg")
        val originalHash = hash(source)
        var calls = 0
        val result = ExtractedImageProcessor(context, availableMemory = { if (calls++ < 2) Long.MAX_VALUE else 0 })
            .prepare(root, listOf(page(source)), true).single()
        assertEquals(source.name, result.storedPath)
        assertEquals(originalHash, hash(source))
        assertFalse(root.walkTopDown().any { it.extension == "jxl" })
    }

    @Test fun entireInputListIsValidatedBeforeAnySourceCanBeRemoved() {
        val source = fixture("pattern-rgb.jpg").let { original -> File(root, "a.jpg").also { original.renameTo(it) } }
        val collision = File(root, "A.JPG").also { source.copyTo(it) }
        val expected = hash(source)
        try {
            processor().prepare(root, listOf(page(source), page(collision)), true)
            fail("Expected normalized case collision")
        } catch (_: ImportFailure) { }
        assertEquals(expected, hash(source))
        assertEquals(expected, hash(collision))
        assertFalse(root.listFiles()!!.any { it.name.startsWith(".ziv-prepared-") })
    }

    @Test fun zeroMemoryKeepsEveryOriginalAndCreatesNoAuxiliaryFiles() {
        val source = fixture("pattern-rgb.jpg")
        val expected = hash(source)
        val result = ExtractedImageProcessor(context, availableMemory = { 0 }).prepare(root, listOf(page(source)), true).single()
        assertEquals(source.name, result.storedPath)
        assertNull(result.previewPath)
        assertEquals(expected, hash(source))
        assertEquals(listOf(source.name), root.list()!!.toList())
    }

    private fun processor() = ExtractedImageProcessor(context, availableMemory = { Long.MAX_VALUE })
    private fun page(file: File) = PageRecord(file.name, file.name)
    private fun fixture(name: String): File = File(root, name).also { target ->
        assets.open("codec-fixtures/$name").use { input -> target.outputStream().use { input.copyTo(it) } }
    }
    private fun hash(file: File): String = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
}
