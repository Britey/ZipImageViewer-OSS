package com.brite.zipimageviewer

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.content.IntentFilter
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Exercises persisted picker preferences and the actual library/settings controls. */
/** Retained native picker preferences coverage in the explicit legacy harness. */
class ArchivePickerUiTest {
    @get:Rule val ui = createEmptyComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val pickerPreferences get() = context.getSharedPreferences("archive_picker", 0)
    private var activity: ActivityScenario<LegacyLibraryActivity>? = null

    @Before fun before() {
        runBlocking { AppRepository.resetForTests() }
        File(context.filesDir, "archive-library").deleteRecursively()
        context.getSharedPreferences("reader", 0).edit().clear().commit()
        context.getSharedPreferences("archive-repository", 0).edit().clear().commit()
        pickerPreferences.edit().clear().commit()
        activity = ActivityScenario.launch(LegacyLibraryActivity::class.java)
        awaitTag("library")
    }

    @After fun after() {
        activity?.close()
        pickerPreferences.edit().clear().commit()
    }

    private fun awaitTag(tag: String) = ui.waitUntil(30_000) {
        ui.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
    }

    private fun chooseEachTimeInSettings() {
        ui.onNodeWithTag("app_settings").performClick()
        ui.onNodeWithTag("default_file_picker").performScrollTo().performClick()
        awaitTag("picker_ask")
        ui.onNodeWithTag("picker_ask").performScrollTo().performClick()
        ui.onNodeWithTag("default_file_picker").assertTextContains("File picker: Choose a file app each time")
        ui.onNodeWithTag("app_settings_done").performClick()
    }

    @Test fun emptyLibraryActionCanCancelRepeatedlyAndImportARealArchive() {
        val filter = IntentFilter(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            addDataType("*/*")
        }
        repeat(2) {
            val monitor = instrumentation.addMonitor(filter,
                Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null), true)
            try {
                ui.onNodeWithTag("open_demo").assertDoesNotExist()
                ui.onNodeWithTag("open_empty_archive").performScrollTo().performClick()
                ui.waitUntil(10_000) { monitor.hits == 1 }
                ui.waitForIdle()
                ui.onNodeWithText("No archives yet").assertIsDisplayed()
                assertEquals(0, AppCoordinator.get(context.applicationContext as android.app.Application).archives.value.size)
            } finally { instrumentation.removeMonitor(monitor) }
        }
        val uri = android.net.Uri.parse("content://com.brite.zipimageviewer.test.intents/one")
        val result = Intent().setData(uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val monitor = instrumentation.addMonitor(filter,
            Instrumentation.ActivityResult(Activity.RESULT_OK, result), true)
        try {
            ui.onNodeWithTag("open_empty_archive").performScrollTo().performClick()
            ui.waitUntil(10_000) { monitor.hits == 1 }
            awaitTag("reader")
            ui.onNodeWithTag("page_jump").assertTextContains("1 / 3")
            ui.onNodeWithTag("reader_close").performClick()
            awaitTag("library")
            ui.onNodeWithText("External plain.cbz").assertIsDisplayed()
            ui.onNodeWithTag("open_empty_archive").assertDoesNotExist()
        } finally { instrumentation.removeMonitor(monitor) }
    }

    @Test fun defaultPickerPersistsAcrossFinishAndRelaunchAndCancelKeepsLibrary() {
        chooseEachTimeInSettings()
        assertEquals("ask", pickerPreferences.getString("selection", null))
        activity!!.close()
        activity = ActivityScenario.launch(LegacyLibraryActivity::class.java)
        awaitTag("library")
        ui.onNodeWithTag("app_settings").performClick()
        ui.onNodeWithTag("default_file_picker").performScrollTo()
            .assertTextContains("File picker: Choose a file app each time")
        ui.onNodeWithTag("app_settings_done").performClick()

        ui.onNodeWithTag("open_archive").performClick()
        awaitTag("picker_system")
        ui.onNodeWithText("Open archive using").assertIsDisplayed()
        ui.onNodeWithTag("picker_remember").performScrollTo().assertIsOff()
        ui.onNodeWithText("Cancel").performClick()
        ui.onNodeWithTag("picker_system").assertDoesNotExist()
        ui.onNodeWithTag("library").assertIsDisplayed()
        ui.onNodeWithText("No archives yet").assertIsDisplayed()
        assertEquals("ask", pickerPreferences.getString("selection", null))
    }

    @Test fun perUseSystemOverrideAndCancelledSystemPickerDoNotChangeDefault() {
        chooseEachTimeInSettings()
        // Return a real cancelled activity result without depending on an OEM file-picker UI.
        val filter = IntentFilter(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            addDataType("*/*")
        }
        val monitor = instrumentation.addMonitor(filter,
            Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null), true)
        try {
            ui.onNodeWithTag("choose_archive_picker").performClick()
            awaitTag("picker_system")
            ui.onNodeWithTag("picker_remember").performScrollTo().assertIsOff()
            ui.onNodeWithTag("picker_system").performScrollTo().performClick()
            ui.waitUntil(10_000) { monitor.hits == 1 }
            ui.waitForIdle()
            ui.onNodeWithTag("library").assertIsDisplayed()
            ui.onNodeWithTag("picker_system").assertDoesNotExist()
            ui.onNodeWithText("No archives yet").assertIsDisplayed()
            assertEquals("ask", pickerPreferences.getString("selection", null))

            ui.onNodeWithTag("open_archive").performClick()
            awaitTag("picker_system")
            ui.onNodeWithText("Open archive using").assertIsDisplayed()
            ui.onNodeWithText("Cancel").performClick()
        } finally {
            instrumentation.removeMonitor(monitor)
        }
    }
}
