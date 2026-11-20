package com.brite.zipimageviewer.reader

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

@RunWith(AndroidJUnit4::class)
class ReaderPipelineTest {
    private fun page(number: Int) = ReaderPage("page$number.png", File("/unused/$number.png"))
    private fun image(size: Int = 32) = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    private suspend fun await(condition: () -> Boolean) = withTimeout(8_000) { while (!withContext(Dispatchers.Main) { condition() }) delay(10) }

    @Test fun twoHundredSelectionsReplacePendingRequestsAndReleaseEveryFileLease() = runBlocking {
        val hold = CompletableDeferred<Unit>()
        val leases = AtomicInteger()
        val calls = AtomicInteger()
        val bitmap = image()
        val pipeline = withContext(Dispatchers.Main) {
            ReaderImagePipeline(retainImageWork = { leases.incrementAndGet(); { leases.decrementAndGet(); Unit } }, decode = { source, _, _ ->
                calls.incrementAndGet()
                if (source.relativePath == "page0.png") hold.await()
                bitmap
            }).also { target ->
                repeat(200) { target.select(page(it), 720) }
                assertEquals(1, target.previews.pendingCount)
                assertEquals(1, target.fitted.pendingCount)
                assertEquals(4, leases.get())
            }
        }
        hold.complete(Unit)
        await { pipeline.frame?.page?.relativePath == "page199.png" && pipeline.frame?.kind == ReaderDecodeKind.FITTED }
        assertEquals(4, calls.get())
        withContext(Dispatchers.Main) { pipeline.close() }
        await { leases.get() == 0 }
    }

    @Test fun closeDropsQueuedWorkButHoldsActiveFileLeasesUntilDecodeActuallyReturns() = runBlocking {
        val hold = CompletableDeferred<Unit>()
        val leases = AtomicInteger()
        val bitmap = image()
        val pipeline = withContext(Dispatchers.Main) {
            ReaderImagePipeline(retainImageWork = { leases.incrementAndGet(); { leases.decrementAndGet(); Unit } }, decode = { _, _, _ -> hold.await(); bitmap }).also {
                it.select(page(0), 720); it.select(page(1), 720)
                assertEquals(4, leases.get())
                it.close()
                assertEquals(2, leases.get())
                assertNull(it.frame)
            }
        }
        hold.complete(Unit)
        await { leases.get() == 0 }
        withContext(Dispatchers.Main) { assertNull(pipeline.frame) }
    }

    @Test fun reverseScrubSuppressesAnObsoleteCompletedPreviewAndExactReleaseFitsTarget() = runBlocking {
        val firstStarted = CompletableDeferred<Unit>()
        val first = CompletableDeferred<Unit>()
        val newest = CompletableDeferred<Unit>()
        val clock = AtomicLong(0)
        val bitmap = image()
        val pipeline = withContext(Dispatchers.Main) {
            ReaderImagePipeline(now = { clock.get() }, decode = { source, kind, _ ->
                if (kind == ReaderDecodeKind.PREVIEW && source.relativePath == "page2.png") { firstStarted.complete(Unit); first.await() }
                if (kind == ReaderDecodeKind.PREVIEW && source.relativePath == "page1.png") newest.await()
                bitmap
            }).also { it.scrub(page(2), 2, 720) }
        }
        withTimeout(5_000) { firstStarted.await() }
        withContext(Dispatchers.Main) {
            clock.set(30); pipeline.scrub(page(3), 3, 720)
            clock.set(60); pipeline.scrub(page(1), 1, 720)
        }
        delay(50)
        first.complete(Unit)
        delay(40)
        withContext(Dispatchers.Main) { assertNull("Prior-direction preview must not publish", pipeline.frame) }
        newest.complete(Unit)
        await { pipeline.frame?.page?.relativePath == "page1.png" }
        withContext(Dispatchers.Main) { pipeline.select(page(4), 720) }
        await { pipeline.frame?.page?.relativePath == "page4.png" && pipeline.frame?.kind == ReaderDecodeKind.FITTED }
        withContext(Dispatchers.Main) { assertFalse(pipeline.scrubbing); pipeline.close() }
    }

    @Test fun pressurePreservesSelectedQueuedFittedWorkAndDoesNotDowngradeZoomDetail() = runBlocking {
        val holdOld = CompletableDeferred<Unit>()
        val oldStarted = CompletableDeferred<Unit>()
        val fittedImage = image(48)
        val detailImage = image(96)
        val pipeline = withContext(Dispatchers.Main) {
            ReaderImagePipeline(decode = { source, kind, _ ->
                if (source.relativePath == "page0.png" && kind == ReaderDecodeKind.FITTED) { oldStarted.complete(Unit); holdOld.await() }
                if (kind == ReaderDecodeKind.DETAIL) detailImage else fittedImage
            }).also { it.select(page(0), 720) }
        }
        oldStarted.await()
        withContext(Dispatchers.Main) {
            pipeline.select(page(1), 720)
            pipeline.memoryPressure()
            assertEquals(1, pipeline.fitted.pendingCount)
        }
        holdOld.complete(Unit)
        await { pipeline.frame?.page?.relativePath == "page1.png" && pipeline.frame?.kind == ReaderDecodeKind.FITTED }
        withContext(Dispatchers.Main) { pipeline.requestDetail() }
        await { pipeline.frame?.kind == ReaderDecodeKind.DETAIL }
        withContext(Dispatchers.Main) {
            pipeline.memoryPressure()
            assertSame(detailImage, pipeline.frame?.bitmap)
            assertEquals(ReaderDecodeKind.DETAIL, pipeline.frame?.kind)
            pipeline.close()
        }
    }

    @Test fun failedZoomDetailCanRetryAndLatePreviewCannotDowngradeItsResult() = runBlocking {
        val preview = CompletableDeferred<Unit>()
        val attempts = AtomicInteger()
        val fittedImage = image(48)
        val detailImage = image(96)
        val pipeline = withContext(Dispatchers.Main) {
            ReaderImagePipeline(decode = { _, kind, _ ->
                when (kind) {
                    ReaderDecodeKind.PREVIEW -> { preview.await(); image(16) }
                    ReaderDecodeKind.FITTED -> fittedImage
                    ReaderDecodeKind.DETAIL -> if (attempts.incrementAndGet() == 1) null else detailImage
                }
            }).also { it.select(page(0), 720) }
        }
        await { pipeline.frame?.kind == ReaderDecodeKind.FITTED }
        withContext(Dispatchers.Main) { pipeline.requestDetail() }
        await { pipeline.detailFailed }
        withContext(Dispatchers.Main) { assertSame(fittedImage, pipeline.frame?.bitmap); pipeline.requestDetail() }
        await { pipeline.frame?.kind == ReaderDecodeKind.DETAIL }
        preview.complete(Unit)
        delay(50)
        withContext(Dispatchers.Main) { assertSame(detailImage, pipeline.frame?.bitmap); assertFalse(pipeline.detailFailed); pipeline.close() }
    }

    @Test fun staleScrubPreviewIsRejectedAndPausedTargetGetsFittedDecode() = runBlocking {
        val previewStarted = CompletableDeferred<Unit>()
        val fitStarted = CompletableDeferred<Unit>()
        val preview = CompletableDeferred<Unit>()
        val fit = CompletableDeferred<Unit>()
        val clock = AtomicLong(0)
        val bitmap = image()
        val pipeline = withContext(Dispatchers.Main) {
            ReaderImagePipeline(now = { clock.get() }, decode = { _, kind, _ ->
                if (kind == ReaderDecodeKind.PREVIEW) { previewStarted.complete(Unit); preview.await() }
                else { fitStarted.complete(Unit); fit.await() }
                bitmap
            }).also { it.scrub(page(0), 0, 720) }
        }
        withTimeout(5_000) { previewStarted.await() }
        clock.set(200)
        preview.complete(Unit)
        withTimeout(5_000) { fitStarted.await() }
        withContext(Dispatchers.Main) { assertNull("A preview older than150ms must not publish", pipeline.frame) }
        fit.complete(Unit)
        await { pipeline.frame?.kind == ReaderDecodeKind.FITTED }
        withContext(Dispatchers.Main) { pipeline.close() }
    }

    @Test fun sourceAndOutputGuardsMatchTheSupportedImageEnvelope() {
        assertTrue(ReaderBitmapDecoder.supportedSource(8000, 4000))
        assertFalse(ReaderBitmapDecoder.supportedSource(8000, 4001))
        assertFalse(ReaderBitmapDecoder.supportedSource(100001, 1))
        assertFalse(ReaderBitmapDecoder.supportedSource(0, 100))
        val (width, height) = ReaderBitmapDecoder.outputSize(8000, 4000, 16384)
        assertTrue(width.toLong() * height * 4 <= 30L * 1024 * 1024)
        assertEquals(width / 2, height)
    }

    @Test fun viewportResizePreservesPendingZoomAndDoesNotRetryFittedOverExistingDetail() = runBlocking {
        val hold = CompletableDeferred<Unit>()
        val started = CompletableDeferred<Unit>()
        val calls = AtomicInteger()
        val fittedImage = image(48)
        val detailImage = image(96)
        val pipeline = withContext(Dispatchers.Main) {
            ReaderImagePipeline(decode = { _, kind, _ ->
                calls.incrementAndGet()
                if (kind == ReaderDecodeKind.DETAIL) { started.complete(Unit); hold.await(); detailImage } else fittedImage
            }).also { it.select(page(0), 720); it.requestDetail() }
        }
        started.await()
        withContext(Dispatchers.Main) { pipeline.select(page(0), 2048); assertTrue(pipeline.detailLoading) }
        hold.complete(Unit)
        await { pipeline.frame?.kind == ReaderDecodeKind.DETAIL }
        val previousCalls = calls.get()
        withContext(Dispatchers.Main) {
            pipeline.select(page(0), 3072)
            assertSame(detailImage, pipeline.frame?.bitmap)
            assertFalse(pipeline.failed)
            assertEquals(previousCalls, calls.get())
            pipeline.close()
        }
    }

    @Test fun expiredFileLeaseMarksUnavailableWithoutStartingDecode() = runBlocking {
        val calls = AtomicInteger()
        withContext(Dispatchers.Main) {
            val pipeline = ReaderImagePipeline(retainImageWork = { throw IllegalStateException("Session closed") }, decode = { _, _, _ -> calls.incrementAndGet(); image() })
            pipeline.select(page(0), 720)
            assertTrue(pipeline.failed)
            assertEquals(0, calls.get())
            pipeline.close()
        }
    }

    @Test fun rawPngExifOrientationsApplyOnceForAllReaderQualitiesEvenWithJpegFilename() = runBlocking {
        val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "reader-orientation-${UUID.randomUUID()}").apply { mkdirs() }
        val raw = Bitmap.createBitmap(4, 2, Bitmap.Config.ARGB_8888)
        for (y in 0 until 2) for (x in 0 until 4) raw.setPixel(x, y, android.graphics.Color.rgb(25 + x * 50, 30 + y * 150, 20 + (x + y) * 30))
        val png = java.io.ByteArrayOutputStream().also { raw.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        try {
            for (orientation in 1..8) {
                val exif = byteArrayOf(73,73,42,0,8,0,0,0,1,0,18,1,3,0,1,0,0,0,orientation.toByte(),0,0,0,0,0,0,0)
                val chunk = java.io.ByteArrayOutputStream()
                java.io.DataOutputStream(chunk).use { output ->
                    val type = "eXIf".toByteArray(Charsets.US_ASCII)
                    output.writeInt(exif.size); output.write(type); output.write(exif)
                    output.writeInt(java.util.zip.CRC32().apply { update(type); update(exif) }.value.toInt())
                }
                val file = File(directory, "$orientation.${if (orientation % 2 == 0) "jpg" else "png"}")
                file.writeBytes(png.copyOfRange(0, 33) + chunk.toByteArray() + png.copyOfRange(33, png.size))
                for (kind in ReaderDecodeKind.entries) {
                    val decoded = requireNotNull(ReaderBitmapDecoder.decode(file, kind, 720))
                    assertEquals(if (orientation >= 5) 2 else 4, decoded.width)
                    assertEquals(if (orientation >= 5) 4 else 2, decoded.height)
                    for (y in 0 until 2) for (x in 0 until 4) {
                        val destination = when (orientation) {
                            2 -> 3 - x to y; 3 -> 3 - x to 1 - y; 4 -> x to 1 - y
                            5 -> y to x; 6 -> 1 - y to x; 7 -> 1 - y to 3 - x; 8 -> y to 3 - x
                            else -> x to y
                        }
                        assertEquals("$kind orientation=$orientation point=$x,$y", raw.getPixel(x, y), decoded.getPixel(destination.first, destination.second))
                    }
                }
            }
        } finally { raw.recycle(); ReaderBitmapDecoder.clearCache(); directory.deleteRecursively() }
    }

    @Test fun oversizedOriginalPngOrientationUsesBoundedMetadataSeeking() {
        val file = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "large-metadata-${UUID.randomUUID()}.png")
        try {
            val exif = byteArrayOf(73,73,42,0,8,0,0,0,1,0,18,1,3,0,1,0,0,0,6,0,0,0,0,0,0,0)
            java.io.RandomAccessFile(file, "rw").use { output ->
                output.write(byteArrayOf(137.toByte(),80,78,71,13,10,26,10))
                val headerType = "IHDR".toByteArray(Charsets.US_ASCII)
                val header = byteArrayOf(0,0,0,4,0,0,0,2,8,6,0,0,0)
                output.writeInt(header.size); output.write(headerType); output.write(header)
                output.writeInt(java.util.zip.CRC32().apply { update(headerType); update(header) }.value.toInt())
                // A sparse ancillary payload tests bounded seeking, not pixel/CRC decoding.
                val payload = 129 * 1024 * 1024
                output.writeInt(payload); output.write("fILL".toByteArray(Charsets.US_ASCII))
                output.seek(output.filePointer + payload); output.writeInt(0)
                val type = "eXIf".toByteArray(Charsets.US_ASCII)
                output.writeInt(exif.size); output.write(type); output.write(exif)
                output.writeInt(java.util.zip.CRC32().apply { update(type); update(exif) }.value.toInt())
                output.writeInt(0); output.write("IEND".toByteArray(Charsets.US_ASCII)); output.writeInt(0)
            }
            assertTrue(file.length() > 128L * 1024 * 1024)
            assertEquals(6, com.brite.zipimageviewer.nativebridge.ImageOrientation.readPngOrientation(file))
        } finally { file.delete() }
    }

    @Test fun replacingSamePagePixelsPreservesZoomPanAndNeverAnimatesTheUpgrade() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val surface = ReaderImageSurface(InstrumentationRegistry.getInstrumentation().targetContext)
            surface.layout(0, 0, 600, 800)
            surface.preferences = ReaderPreferences(animate = true)
            surface.show("same-page", Bitmap.createBitmap(60, 80, Bitmap.Config.ARGB_8888))
            val start = android.os.SystemClock.uptimeMillis()
            fun event(action: Int, offset: Long, x: Float, y: Float) {
                val motion = android.view.MotionEvent.obtain(start, start + offset, action, x, y, 0)
                surface.onTouchEvent(motion); motion.recycle()
            }
            event(android.view.MotionEvent.ACTION_DOWN, 0, 300f, 400f)
            event(android.view.MotionEvent.ACTION_UP, 30, 300f, 400f)
            event(android.view.MotionEvent.ACTION_DOWN, 100, 300f, 400f)
            event(android.view.MotionEvent.ACTION_UP, 130, 300f, 400f)
            event(android.view.MotionEvent.ACTION_DOWN, 500, 300f, 400f)
            event(android.view.MotionEvent.ACTION_MOVE, 550, 360f, 440f)
            event(android.view.MotionEvent.ACTION_UP, 600, 360f, 440f)
            val before = surface.geometrySnapshot()
            assertEquals(2.5f, before.zoom, 0.01f)
            assertTrue(before.panX != 0f || before.panY != 0f)
            surface.show("same-page", Bitmap.createBitmap(600, 800, Bitmap.Config.ARGB_8888))
            val after = surface.geometrySnapshot()
            assertEquals(before.zoom, after.zoom, 0f)
            assertEquals(before.panX, after.panX, 0f)
            assertEquals(before.panY, after.panY, 0f)
            assertEquals(255, after.alpha)
            surface.release()
        }
    }

    @Test fun realTwelveMegapixelPageHasLargerDetailAndBoundedOutputAndPreviewFallback() = runBlocking {
        val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "reader-detail-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val source = File(directory, "large.png")
            val original = Bitmap.createBitmap(3000, 4000, Bitmap.Config.RGB_565)
            original.eraseColor(android.graphics.Color.CYAN)
            source.outputStream().use { original.compress(Bitmap.CompressFormat.PNG, 100, it) }; original.recycle()
            val page = ReaderPage("original.png", source, previewFile = File(directory, "missing.preview.jpg"))
            val preview = ReaderBitmapDecoder.decodePage(page, ReaderDecodeKind.PREVIEW, 720)!!
            val fitted = ReaderBitmapDecoder.decodePage(page, ReaderDecodeKind.FITTED, 720)!!
            val detail = ReaderBitmapDecoder.decodePage(page, ReaderDecodeKind.DETAIL, 720)!!
            assertEquals(384, maxOf(preview.width, preview.height))
            assertEquals(720, maxOf(fitted.width, fitted.height))
            assertTrue(detail.width > fitted.width * 3)
            assertTrue(detail.allocationByteCount <= 30 * 1024 * 1024)
            assertTrue(ReaderBitmapDecoder.cachedBytes() <= 48 * 1024 * 1024)
            assertEquals(0L, ReaderDecodeMemory.usedBytes())
        } finally { ReaderBitmapDecoder.clearCache(); directory.deleteRecursively() }
    }
}
