package com.brite.zipimageviewer

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Retained native UI regression harness. RN library coverage lives in the shared/device tests. */
class AppSmokeTest {
    @get:Rule val ui = createEmptyComposeRule()
    private var activity: ActivityScenario<LegacyLibraryActivity>? = null
    @Before fun setUp() {
        kotlinx.coroutines.runBlocking { AppRepository.resetForTests() }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        File(context.filesDir, "archive-library").deleteRecursively()
        context.getSharedPreferences("reader", 0).edit().clear().commit()
        context.getSharedPreferences("archive-repository", 0).edit().clear().commit()
        activity = ActivityScenario.launch(LegacyLibraryActivity::class.java)
    }
    @After fun tearDown() {
        activity?.close()
        kotlinx.coroutines.runBlocking { AppRepository.resetForTests() }
        File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "Field Notes.cbz").delete()
    }
    private fun awaitTag(tag: String) = ui.waitUntil(30_000) { ui.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty() }

    private fun importFixture() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val source = File(instrumentation.targetContext.cacheDir, "Field Notes.cbz")
        instrumentation.context.assets.open("archive-fixtures/field-notes.cbz").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        activity!!.onActivity { AppCoordinator.get(it.application).import(android.net.Uri.fromFile(source)) }
    }

    @Test fun fixtureImportNavigateCloseAndRecreateRetainsReadingPosition() {
        awaitTag("open_empty_archive")
        importFixture()
        awaitTag("reader")
        ui.onNodeWithTag("page_jump").assertTextContains("1 / 12")
        ui.onNodeWithTag("reader_page").performTouchInput { swipeLeft() }
        ui.onNodeWithTag("page_jump").assertTextContains("2 / 12")
        ui.onNodeWithTag("reader_close").performClick()
        awaitTag("library")
        ui.waitUntil(10_000) { ui.onAllNodesWithText("Page 2 of 12").fetchSemanticsNodes().isNotEmpty() }
        activity?.recreate()
        awaitTag("library")
        ui.onNodeWithText("Page 2 of 12").assertIsDisplayed()
        ui.onNodeWithText("Field Notes.cbz").performClick()
        awaitTag("reader")
        ui.onNodeWithTag("page_jump").assertTextContains("2 / 12")
        ui.onNodeWithTag("page_overview").performClick()
        awaitTag("thumbnail_grid")
        ui.onNodeWithTag("thumbnail_3").performScrollTo().performClick()
        ui.onNodeWithTag("page_jump").assertTextContains("4 / 12")
        ui.onNodeWithTag("reader_close").performClick()
        awaitTag("library")
        ui.onNodeWithTag("archive_search").performTextInput("does-not-exist")
        ui.onNodeWithText("No matching archives").assertIsDisplayed()
    }
    @Test fun libraryReaderPreferencesPersistAndAreSharedWithTheReader() {
        awaitTag("open_archive")
        ui.onNodeWithTag("open_archive").assertTextContains("Open archive").assertIsDisplayed()
        ui.onNodeWithTag("app_settings").performClick()
        ui.onNodeWithContentDescription("Page slider").assertIsOn().performClick().assertIsOff()
        ui.onNodeWithTag("app_settings_done").performClick()
        activity?.close()
        activity = ActivityScenario.launch(LegacyLibraryActivity::class.java)
        awaitTag("open_empty_archive")
        ui.onNodeWithTag("app_settings").performClick()
        ui.onNodeWithContentDescription("Page slider").assertIsOff()
        ui.onNodeWithTag("app_settings_done").performClick()
        importFixture()
        awaitTag("reader")
        ui.onNodeWithTag("page_slider").assertDoesNotExist()
        ui.onNodeWithTag("reader_settings").performClick()
        ui.onNodeWithContentDescription("Page slider").assertIsOff().performClick()
        ui.onNodeWithTag("reader_settings_done").performClick()
        ui.onNodeWithTag("page_slider").assertIsDisplayed()
        ui.onNodeWithTag("reader_close").performClick()
        awaitTag("library")
        ui.onNodeWithTag("app_settings").performClick()
        ui.onNodeWithContentDescription("Page slider").assertIsOn()
    }

    @Test fun compressionDefaultsOffPersistsAndDoesNotRewriteAnExistingArchive() {
        awaitTag("app_settings")
        ui.onNodeWithTag("app_settings").performClick()
        ui.onNodeWithTag("compress_images").performScrollTo().assertIsOff()
        ui.onNodeWithTag("app_settings_done").performClick()
        importFixture()
        awaitTag("reader")
        ui.onNodeWithTag("reader_close").performClick()
        awaitTag("library")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val retained = File(context.filesDir, "archive-library/retained")
        fun contents() = retained.walkTopDown().filter { it.isFile && it.name != "manifest.json" }.associate { file ->
            file.relativeTo(retained).path to java.security.MessageDigest.getInstance("SHA-256")
                .digest(file.readBytes()).toList()
        }
        // Wait until the reader's progress flush and close have completed before taking a snapshot.
        ui.waitForIdle()
        val original = contents()
        org.junit.Assert.assertTrue(original.isNotEmpty())
        ui.onNodeWithTag("app_settings").performClick()
        ui.onNodeWithTag("compress_images").performScrollTo().performClick().assertIsOn()
        ui.onNodeWithTag("app_settings_done").performClick()
        activity?.close()
        activity = ActivityScenario.launch(LegacyLibraryActivity::class.java)
        awaitTag("app_settings")
        ui.onNodeWithTag("app_settings").performClick()
        ui.onNodeWithTag("compress_images").performScrollTo().assertIsOn()
        org.junit.Assert.assertEquals(original, contents())
    }

    @Test fun passwordRetriesKeepTheCompressionChoiceFromTheStartOfImport() {
        awaitTag("app_settings")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val inputDirectory = File(context.cacheDir, "snapshot-test").apply { mkdirs() }
        try {
            val source = File(inputDirectory, "page.png")
            writeUncompressedGradientPng(source)
            for (initialSetting in listOf(false, true)) {
                val archive = File(inputDirectory, "snapshot-$initialSetting.zip")
                archive.delete()
                net.lingala.zip4j.ZipFile(archive, "retry-test".toCharArray()).use { zip ->
                    zip.addFile(source, net.lingala.zip4j.model.ZipParameters().apply {
                        isEncryptFiles = true
                        encryptionMethod = net.lingala.zip4j.model.enums.EncryptionMethod.AES
                    })
                }
                lateinit var model: AppCoordinator
                activity!!.onActivity {
                    model = AppCoordinator.get(it.application)
                    model.setImageCompression(initialSetting)
                    model.import(android.net.Uri.fromFile(archive))
                }
                awaitTag("archive_password")
                ui.waitUntil(10_000) { !model.busy }
                activity!!.onActivity { model.setImageCompression(!initialSetting) }
                ui.onNodeWithTag("archive_password").performTextInput("retry-test")
                ui.onNodeWithText("Unlock").performClick()
                ui.waitUntil(120_000) { model.currentArchive != null || model.error != null }
                org.junit.Assert.assertNull(model.error)
                val record = requireNotNull(model.currentArchive)
                val page = record.pages.single()
                org.junit.Assert.assertEquals("Retry uses its original setting", initialSetting,
                    page.processingPolicy != null)
                if (!initialSetting) {
                    org.junit.Assert.assertArrayEquals(source.readBytes(), model.repository.pageFile(record, page).readBytes())
                }
                ui.onNodeWithTag("reader_close").performClick()
                awaitTag("library")
            }
        } finally { inputDirectory.deleteRecursively() }
    }

    @Test fun passwordPromptSurvivesRotationRejectsIncomingArchiveAndDismissalCleansStaging() {
        awaitTag("app_settings")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val uri = android.net.Uri.parse("content://${instrumentation.context.packageName}.import-fixtures/${java.util.UUID.randomUUID()}/encrypted.zip")
        lateinit var model: AppCoordinator
        activity!!.onActivity {
            model = AppCoordinator.get(it.application)
            model.import(uri)
            model.import(android.net.Uri.parse("content://unavailable/busy.zip"))
            org.junit.Assert.assertTrue(model.error!!.contains("Finish or cancel"))
            model.dismissError()
        }
        awaitTag("archive_password")
        ui.waitUntil(10_000) { !model.busy }
        val staged = File(context.filesDir, "archive-library/staging").listFiles()!!.single()
        org.junit.Assert.assertTrue(File(staged, "source.archive").isFile)
        activity!!.recreate()
        activity!!.onActivity {
            org.junit.Assert.assertSame(model, AppCoordinator.get(it.application))
            model.import(android.net.Uri.parse("content://unavailable/another.zip"))
        }
        ui.onNodeWithText("Finish or cancel the current archive import before opening another archive.").assertIsDisplayed()
        org.junit.Assert.assertNotNull(model.passwordPrompt)
        org.junit.Assert.assertTrue(File(staged, "source.archive").isFile)
        activity!!.onActivity { model.dismissError() }
        ui.onNodeWithText("Cancel").performClick()
        ui.waitUntil(10_000) { !staged.exists() }
        org.junit.Assert.assertNull(model.passwordPrompt)
        org.junit.Assert.assertTrue(model.archives.value.isEmpty())
        activity!!.onActivity { model.import(uri) }
        awaitTag("archive_password")
        val reopened = File(context.filesDir, "archive-library/staging").listFiles()!!.single()
        // UI detachment keeps the process-owned import; explicit cancellation releases it.
        activity!!.close()
        org.junit.Assert.assertTrue(reopened.exists())
        instrumentation.runOnMainSync { model.dismissPassword() }
        ui.waitUntil(10_000) { !reopened.exists() }
    }

    /** Large enough for profitable conversion, with deterministic uncompressed source pixels. */
    private fun writeUncompressedGradientPng(file: File) {
        val width = 1600
        val height = 1200
        val raw = java.io.ByteArrayOutputStream()
        java.util.zip.DeflaterOutputStream(raw, java.util.zip.Deflater(java.util.zip.Deflater.NO_COMPRESSION)).use { z ->
            val row = ByteArray(1 + width * 3)
            repeat(height) { y ->
                repeat(width) { x ->
                    row[1 + x * 3] = (x * 255 / width).toByte()
                    row[2 + x * 3] = (y * 255 / height).toByte()
                    row[3 + x * 3] = ((x + y) % 256).toByte()
                }
                z.write(row)
            }
        }
        java.io.DataOutputStream(file.outputStream()).use { output ->
            output.write(byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10))
            fun chunk(type: String, data: ByteArray) {
                val kind = type.toByteArray(Charsets.US_ASCII)
                output.writeInt(data.size); output.write(kind); output.write(data)
                output.writeInt(java.util.zip.CRC32().apply { update(kind); update(data) }.value.toInt())
            }
            val header = java.nio.ByteBuffer.allocate(13).putInt(width).putInt(height)
                .put(8).put(2).put(0).put(0).put(0).array()
            chunk("IHDR", header); chunk("IDAT", raw.toByteArray()); chunk("IEND", byteArrayOf())
        }
    }

    @Test fun quickActivityRelaunchPreservesTemporaryFilesUntilOldImageWorkFinishes() {
        awaitTag("open_empty_archive")
        lateinit var model: AppCoordinator
        activity!!.onActivity { model = AppCoordinator.get(it.application) }
        kotlinx.coroutines.runBlocking { model.repository.setCacheBudget(1) }
        importFixture()
        awaitTag("reader")
        ui.onNodeWithText("Continue reading").performClick()
        val record = requireNotNull(model.currentArchive)
        org.junit.Assert.assertTrue(record.isTemporary)
        val file = model.repository.pageFile(record, record.pages.first())
        val releaseWork = model.repository.retainImageWork(record.id)
        try {
            val originalRepository = model.repository
            activity!!.close()
            activity = ActivityScenario.launch(LegacyLibraryActivity::class.java)
            awaitTag("reader")
            ui.onNodeWithText("Continue reading").performClick()
            activity!!.onActivity { model = AppCoordinator.get(it.application) }
            org.junit.Assert.assertSame(originalRepository, model.repository)
            org.junit.Assert.assertEquals(record.id, model.currentArchive?.id)
            org.junit.Assert.assertTrue("Detachment must preserve the active temporary reader", file.isFile)
            ui.onNodeWithTag("reader_close").performClick()
            awaitTag("library")
            org.junit.Assert.assertTrue("Explicit close still waits for retained native decode work", file.isFile)
        } finally { releaseWork() }
        ui.waitUntil(10_000) { !file.exists() }
    }

    @Test fun immediateActivityFinishStillSavesTheLatestReadingPosition() {
        awaitTag("open_empty_archive")
        importFixture()
        awaitTag("reader")
        activity!!.onActivity {
            val model = AppCoordinator.get(it.application)
            model.progress(requireNotNull(model.currentArchive).pages[7].originalPath)
        }
        activity!!.close()
        activity = ActivityScenario.launch(LegacyLibraryActivity::class.java)
        awaitTag("reader")
        ui.onNodeWithTag("page_jump").assertTextContains("8 / 12")
        ui.onNodeWithTag("reader_close").performClick()
        awaitTag("library")
        ui.waitUntil(10_000) { ui.onAllNodesWithText("Page 8 of 12").fetchSemanticsNodes().isNotEmpty() }
        ui.onNodeWithText("Field Notes.cbz").performClick()
        awaitTag("reader")
        ui.onNodeWithTag("page_jump").assertTextContains("8 / 12")
    }

    @Test fun cacheLimitsRequireConfirmationAndSurviveNewActivity() {
        awaitTag("app_settings")
        ui.onNodeWithTag("app_settings").performClick()
        ui.onNodeWithTag("archive_limit").performScrollTo().performClick()
        ui.onNodeWithText("5", useUnmergedTree = true).performClick()
        awaitTag("apply_cache_limits")
        ui.onNodeWithText("No cached archives will be removed now.").assertIsDisplayed()
        ui.onNodeWithTag("apply_cache_limits").performClick()
        ui.waitUntil(5_000) { ui.onAllNodesWithText("Archive limit: 5").fetchSemanticsNodes().isNotEmpty() }
        ui.onNodeWithTag("storage_limit").performScrollTo().performClick()
        ui.onNodeWithText("500.0 MB", useUnmergedTree = true).performClick()
        awaitTag("apply_cache_limits")
        ui.onNodeWithText("Cancel").performClick()
        ui.onNodeWithTag("storage_limit").assertTextContains("Storage limit: 2.0 GB")
        ui.onNodeWithTag("app_settings_done").performClick()
        activity?.close()
        activity = ActivityScenario.launch(LegacyLibraryActivity::class.java)
        awaitTag("app_settings")
        ui.onNodeWithTag("app_settings").performClick()
        ui.onNodeWithTag("archive_limit").performScrollTo().assertTextContains("Archive limit: 5")
    }

}
