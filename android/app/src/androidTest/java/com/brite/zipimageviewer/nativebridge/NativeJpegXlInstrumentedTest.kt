package com.brite.zipimageviewer.nativebridge

import android.graphics.ColorSpace
import android.graphics.Bitmap
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.ByteArrayInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.zip.CRC32
import java.util.zip.DeflaterOutputStream
import java.util.zip.InflaterInputStream
import kotlin.math.abs
import kotlin.math.pow
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeJpegXlInstrumentedTest {
    private lateinit var root: File
    private val budget = 384L * 1024 * 1024
    @Before fun setUp() {
        root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "jxl-${UUID.randomUUID()}")
        check(root.mkdirs())
    }
    @After fun tearDown() { root.deleteRecursively() }
    private fun fixture(name: String) = File(root, name).also { output ->
        InstrumentationRegistry.getInstrumentation().context.assets.open("codec-fixtures/$name").use { input ->
            output.outputStream().use { input.copyTo(it) }
        }
    }
    private fun encoded(source: File): File = File(root, "${UUID.randomUUID()}.jxl").also {
        val result = NativeJpegXl.encode(source.path, it.path, budget)
        assertTrue("${source.name}: $result", result.succeeded)
        assertTrue(result.peakCodecBytes in 1..budget)
        assertEquals(it.length(), result.bytesWritten)
        Log.i("JxlTest", "${source.name}: original=${source.length()}, encoded=${it.length()}, codecPeak=${result.peakCodecBytes}")
    }

    @Test fun jpegReconstructionIsByteExactAndCandidateFullyValidates() {
        val original = fixture("pattern-rgb.jpg").let { source ->
            File(root, "影像 😀.jpg").also { check(source.renameTo(it)) }
        }
        val jxl = encoded(original)
        assertTrue(jxl.length() < original.length())
        assertEquals(NativeJpegXl.ImageInfo("jxl", 1600, 1200, 1, 8, 1), NativeJpegXl.inspect(jxl.path))
        assertTrue(NativeJpegXl.validate(jxl.path, 1600, 1200, 1))
        assertFalse(NativeJpegXl.validate(jxl.path, 1599, 1200, 1))
        val restored = File(root, "还原 😀.jpg")
        assertTrue(NativeJpegXl.reconstructJpeg(jxl.path, restored.path, original.length()))
        assertArrayEquals(original.readBytes(), restored.readBytes())
        val preview = requireNotNull(NativeJpegXl.decode(jxl.path, 384, 384L * 384))
        try { assertEquals(384, preview.width); assertEquals(288, preview.height) } finally { preview.recycle() }
        val broken = File(root, "truncated.jxl").apply { writeBytes(jxl.readBytes().copyOf((jxl.length() / 2).toInt())) }
        assertFalse(NativeJpegXl.validate(broken.path, 1600, 1200, 1))
        val jpegBytes = original.readBytes()
        val exif = "Exif\u0000\u0000".toByteArray(Charsets.US_ASCII) + tiffOrientation(6)
        val segment = ByteArrayOutputStream()
        DataOutputStream(segment).use { it.writeShort(0xffe1); it.writeShort(exif.size + 2); it.write(exif) }
        val oriented = File(root, "oriented.jpg").apply {
            writeBytes(jpegBytes.copyOfRange(0,2) + segment.toByteArray() + jpegBytes.copyOfRange(2,jpegBytes.size))
        }
        val orientedJxl = encoded(oriented)
        assertTrue(NativeJpegXl.validate(orientedJxl.path, 1600, 1200, 6))
        val orientedRestored = File(root, "oriented-restored.jpg")
        assertTrue(NativeJpegXl.reconstructJpeg(orientedJxl.path, orientedRestored.path, oriented.length()))
        assertArrayEquals(oriented.readBytes(), orientedRestored.readBytes())
        val orientedPreview = requireNotNull(NativeJpegXl.decode(orientedJxl.path, 384, 384L * 384))
        try { assertEquals(288, orientedPreview.width); assertEquals(384, orientedPreview.height) }
        finally { orientedPreview.recycle() }
    }

    @Test fun p3ProfilePreservesNumericalColorsThroughCms() {
        val jxl = encoded(fixture("p3-swatches.png"))
        val bitmap = requireNotNull(NativeJpegXl.decode(jxl.path, 1000, 1_000_000))
        try {
            assertEquals(ColorSpace.get(ColorSpace.Named.DISPLAY_P3), bitmap.colorSpace)
            assertColor(bitmap.getColor(200, 150), intArrayOf(240,20,30))
            assertColor(bitmap.getColor(600, 150), intArrayOf(30,230,40))
            assertColor(bitmap.getColor(200, 450), intArrayOf(20,30,240))
            assertColor(bitmap.getColor(600, 450), intArrayOf(100,160,220))
        } finally { bitmap.recycle() }
    }

    @Test fun sharedRawBitmapOrientationKeepsColorsAndAllExifTransforms() {
        val raw = Bitmap.createBitmap(4, 2, Bitmap.Config.ARGB_8888, false,
            ColorSpace.get(ColorSpace.Named.DISPLAY_P3))
        raw.setPixels(intArrayOf(0xff112233.toInt(), 0xff334455.toInt(), 0xff556677.toInt(), 0xff778899.toInt(),
            0xffabcdef.toInt(), 0xfffedcba.toInt(), 0xff010203.toInt(), 0xff445566.toInt()),0,4,0,0,4,2)
        try {
            assertSame(raw, ImageOrientation.orientBitmap(raw, 1))
            for (orientation in 2..8) {
                val output = ImageOrientation.orientBitmap(raw, orientation)
                try {
                    assertEquals(raw.colorSpace, output.colorSpace)
                    assertEquals(if (orientation >= 5) 2 else 4, output.width)
                    assertEquals(if (orientation >= 5) 4 else 2, output.height)
                    for(y in 0..1) for(x in 0..3) {
                        val point = when(orientation) {
                            2 -> 3-x to y; 3 -> 3-x to 1-y; 4 -> x to 1-y; 5 -> y to x
                            6 -> 1-y to x; 7 -> 1-y to 3-x; else -> y to 3-x
                        }
                        assertEquals("orientation=$orientation source=$x,$y", raw.getPixel(x,y), output.getPixel(point.first,point.second))
                    }
                } finally { if(output !== raw) output.recycle() }
            }
        } finally { raw.recycle() }
    }

    @Test fun rotatedAndMirroredOrientationsAreAppliedOnceInFullAndSampledDecode() {
        val original = fixture("p3-swatches.png").readBytes()
        for (orientation in 5..8) {
            val source = File(root, "orientation-$orientation.png").apply { writeBytes(withOrientation(original, orientation)) }
            assertEquals(orientation, NativeJpegXl.inspect(source.path)?.orientation)
            val jxl = encoded(source)
            assertTrue(NativeJpegXl.validate(jxl.path, 800, 600, orientation))
            for (edge in listOf(1000, 400)) {
                val bitmap = requireNotNull(NativeJpegXl.decode(jxl.path, edge, 1_000_000))
                try {
                    val scale = if (edge == 1000) 1 else 2
                    assertEquals(600 / scale, bitmap.width); assertEquals(800 / scale, bitmap.height)
                    // Center of top-left source swatch after transpose/clockwise/transverse/counterclockwise.
                    val point = when (orientation) {
                        5 -> 150 to 200; 6 -> 449 to 200; 7 -> 449 to 599; else -> 150 to 599
                    }
                    assertColor(bitmap.getColor(point.first / scale, point.second / scale), intArrayOf(240,20,30))
                } finally { bitmap.recycle() }
            }
        }
    }

    @Test fun alphaIsWhiteAndPngOrientationSurvivesEncoding() {
        val source = fixture("pattern-rgba-p3.png")
        assertEquals(NativeJpegXl.ImageInfo("png", 800, 600, 6, 8, 1), NativeJpegXl.inspect(source.path))
        val jxl = encoded(source)
        assertTrue(NativeJpegXl.validate(jxl.path, 800, 600, 6))
        val bitmap = requireNotNull(NativeJpegXl.decode(jxl.path, 1000, 1_000_000))
        try {
            assertEquals(600, bitmap.width); assertEquals(800, bitmap.height)
            assertColor(bitmap.getColor(300, 100), intArrayOf(255,255,255))
            assertEquals(1f, bitmap.getColor(300, 700).alpha(), 0f)
            assertTrue(bitmap.getColor(300, 700).green() < 0.8f)
        } finally { bitmap.recycle() }
    }

    @Test fun grayscaleIccIsConvertedToRgbWithExpectedTransferFunction() {
        val fixtures = listOf(
            "pattern-gray.png" to null,
            "pattern-gray-icc.png" to (461.0 / 256), // ICC curveType stores gamma as u8Fixed8.
            "pattern-gray-gamma.png" to (100000.0 / 45455), // PNG gAMA stores inverse gamma.
        )
        for ((name, exponent) in fixtures) {
            val jxl = encoded(fixture(name))
            assertTrue(NativeJpegXl.validate(jxl.path, 800, 600, 1))
            val bitmap = requireNotNull(NativeJpegXl.decode(jxl.path, 1000, 1_000_000))
            try {
                for (x in listOf(100, 200, 400, 600)) {
                    val sample = (x * 255 / 799).toDouble() / 255
                    val expected = if (exponent == null) sample else {
                        val linear = sample.pow(exponent)
                        if (linear <= 0.0031308) linear * 12.92 else 1.055 * linear.pow(1.0 / 2.4) - 0.055
                    }
                    val color = bitmap.getColor(x, 300)
                    assertEquals("$name x=$x", expected, color.red().toDouble(), 0.012)
                    assertEquals(color.red(), color.green(), 0.015f)
                    assertEquals(color.green(), color.blue(), 0.015f)
                }
            } finally { bitmap.recycle() }
        }
    }

    @Test fun allocationUnsupportedInputAndIoFailuresLeaveNoCandidate() {
        val source = fixture("pattern-rgb.jpg")
        val candidate = File(root, "tiny-budget.jxl")
        val rejected = NativeJpegXl.encode(source.path, candidate.path, 1024)
        assertFalse(rejected.succeeded); assertFalse(candidate.exists())
        assertTrue(rejected.peakCodecBytes <= 1024)
        val depth = fixture("high-depth.png")
        assertEquals(16, NativeJpegXl.inspect(depth.path)?.bitDepth)
        assertEquals("unsupported_input", NativeJpegXl.encode(depth.path, candidate.path, budget).failure)
        assertFalse(candidate.exists())
        val malformed = File(root, "bad.png").apply { writeText("not an image") }
        assertNull(NativeJpegXl.inspect(malformed.path))
        assertFalse(NativeJpegXl.encode(malformed.path, candidate.path, budget).succeeded)
        val corruptPng = fixture("pattern-gray.png")
        val bytes = corruptPng.readBytes()
        var chunk = 8
        while (chunk + 12 <= bytes.size) {
            val length = java.nio.ByteBuffer.wrap(bytes, chunk, 4).int
            if (String(bytes, chunk + 4, 4, Charsets.US_ASCII) == "IDAT") {
                bytes[chunk + 8] = (bytes[chunk + 8].toInt() xor 255).toByte()
                break
            }
            chunk += length + 12
        }
        corruptPng.writeBytes(bytes)
        repeat(3) {
            assertFalse(NativeJpegXl.encode(corruptPng.path, candidate.path, budget).succeeded)
            assertFalse(candidate.exists())
        }
        val badProfile = fixture("p3-swatches.png")
        val profileBytes = badProfile.readBytes()
        chunk = 8
        var changedProfile = false
        while (chunk + 12 <= profileBytes.size) {
            val length = java.nio.ByteBuffer.wrap(profileBytes, chunk, 4).int
            if (String(profileBytes, chunk + 4, 4, Charsets.US_ASCII) == "iCCP") {
                var nameEnd = chunk + 8
                while (profileBytes[nameEnd] != 0.toByte()) nameEnd++
                val compressedStart = nameEnd + 2 // NUL-terminated profile name, then compression method.
                val profile = InflaterInputStream(ByteArrayInputStream(profileBytes, compressedStart,
                    chunk + 8 + length - compressedStart)).use { it.readBytes() }
                assertEquals("acsp", String(profile, 36, 4, Charsets.US_ASCII))
                profile[36] = 'X'.code.toByte() // Invalid ICC header, not just its transport checksum.
                val compressed = ByteArrayOutputStream()
                DeflaterOutputStream(compressed).use { it.write(profile) }
                val payload = profileBytes.copyOfRange(chunk + 8, compressedStart) + compressed.toByteArray()
                val replacement = ByteArrayOutputStream()
                DataOutputStream(replacement).use { out ->
                    val type = "iCCP".toByteArray(Charsets.US_ASCII)
                    out.writeInt(payload.size); out.write(type); out.write(payload)
                    val crc = CRC32().apply { update(type); update(payload) }
                    out.writeInt(crc.value.toInt())
                }
                badProfile.writeBytes(profileBytes.copyOfRange(0, chunk) + replacement.toByteArray() +
                    profileBytes.copyOfRange(chunk + length + 12, profileBytes.size))
                changedProfile = true
                break
            }
            chunk += length + 12
        }
        assertTrue("Fixture contains the ICC profile under test", changedProfile)
        assertEquals("unsupported_input", NativeJpegXl.encode(badProfile.path, candidate.path, budget).failure)
        assertFalse(candidate.exists())
        try {
            NativeJpegXl.encode(source.path, File(root, "missing/out.jxl").path, budget)
            fail("Storage errors must be visible to the repository")
        } catch (_: IOException) { }
        val valid = encoded(source)
        assertNull(NativeJpegXl.decode(valid.path, 384, 384L*384, 1024))
    }

    private fun assertColor(color: android.graphics.Color, expected: IntArray) {
        for ((actual, value) in listOf(color.red(), color.green(), color.blue()).zip(expected.toList()))
            assertTrue("Expected ${expected.toList()}, got $color", abs(actual * 255 - value) < 12)
    }
    private fun withOrientation(png: ByteArray, value: Int): ByteArray {
        val exif = tiffOrientation(value)
        val chunk = ByteArrayOutputStream()
        DataOutputStream(chunk).use { out ->
            val type = "eXIf".toByteArray(Charsets.US_ASCII)
            out.writeInt(exif.size); out.write(type); out.write(exif)
            val crc = CRC32().apply { update(type); update(exif) }
            out.writeInt(crc.value.toInt())
        }
        return png.copyOfRange(0,33) + chunk.toByteArray() + png.copyOfRange(33,png.size)
    }
    private fun tiffOrientation(value: Int) =
        byteArrayOf(73,73,42,0,8,0,0,0,1,0,18,1,3,0,1,0,0,0,value.toByte(),0,0,0,0,0,0,0)
}
