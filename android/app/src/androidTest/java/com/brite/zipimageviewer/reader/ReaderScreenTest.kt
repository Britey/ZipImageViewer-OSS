package com.brite.zipimageviewer.reader

import android.graphics.Bitmap
import android.graphics.Color
import android.view.KeyEvent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Real Android gesture dispatch and decoder-backed UI, independent of library/import screens. */
@RunWith(AndroidJUnit4::class)
class ReaderScreenTest {
    @get:Rule val compose = createComposeRule()
    private lateinit var directory: File
    private lateinit var pages: List<ReaderPage>
    private val selected = AtomicReference<String?>(null)
    private val closed = AtomicInteger(0)
    private val preferences = mutableStateOf(ReaderPreferences())

    @Before fun fixtures() {
        directory = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "reader-test-${UUID.randomUUID()}").apply { mkdirs() }
        pages = listOf("page1.png", "page2.png", "page10.png").mapIndexed { index, name ->
            val file = File(directory, name)
            val bitmap = Bitmap.createBitmap(160, 240, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(listOf(Color.RED, Color.GREEN, Color.BLUE)[index])
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
            ReaderPage(name, file, modifiedAt = (3 - index).toLong())
        }
    }
    @After fun cleanup() { directory.deleteRecursively() }

    private fun start(initial: Int = 0, reversed: Boolean = false) {
        preferences.value = ReaderPreferences(reversed = reversed)
        compose.setContent {
            MaterialTheme {
                ReaderScreen("Test archive", pages, pages[initial].relativePath, preferences.value,
                    onPreferencesChange = { preferences.value = it }, onPageChange = { selected.set(it) }, onClose = { closed.incrementAndGet() })
            }
        }
        awaitPage(initial)
    }
    private fun awaitPage(index: Int) {
        compose.waitUntil(5_000) { selected.get() == pages[index].relativePath }
        compose.onNodeWithTag("page_jump").assertTextContains("${index + 1} / 3")
    }
    private fun waitForChrome(visible: Boolean) {
        compose.waitUntil(5_000) { compose.onAllNodesWithTag("reader_close").fetchSemanticsNodes().isNotEmpty() == visible }
    }
    private fun back() = InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)

    @Test fun rapidSharedSelectionsResetRotationEvenWhenTheFinalPageIsUnchanged() {
        val surfaceState = AtomicReference(ReaderSurfaceState())
        val adapter = SharedReaderAdapter(true, { surfaceState.set(it) }, {})
        preferences.value = ReaderPreferences(showRotationButtons = true)
        compose.setContent {
            MaterialTheme {
                ReaderScreen("Rapid selections", pages, pages[0].relativePath, preferences.value,
                    { preferences.value = it }, { selected.set(it) }, {}, shared = adapter)
            }
        }
        compose.waitUntil(5_000) { surfaceGeometry().bitmapWidth > 0 && adapter.action != null }
        compose.runOnIdle { adapter.action!!.invoke("rotateClockwise", null, false) }
        assertEquals(1, surfaceGeometry().quarterTurns)
        compose.runOnIdle {
            adapter.action!!.invoke("seek", 2, true)
            adapter.action!!.invoke("seek", 1, false)
        }
        var stableSince = android.os.SystemClock.uptimeMillis()
        compose.waitUntil(5_000) {
            val state = surfaceState.get()
            if (surfaceGeometry().quarterTurns != 0 || state.page != 1 || state.displayedPage != 1) {
                stableSince = android.os.SystemClock.uptimeMillis(); false
            } else android.os.SystemClock.uptimeMillis() - stableSince >= 500
        }
        assertEquals("page1.png", selected.get())
    }

    @Test fun liveRotationButtonsBothDirectionsZoomPanAndOverviewReset() {
        start()
        compose.onNodeWithTag("reader_rotate_clockwise").assertDoesNotExist()
        compose.onNodeWithTag("reader_settings").performClick()
        compose.onNodeWithContentDescription("Show image rotation buttons").performScrollTo().assertIsOff().performClick().assertIsOn()
        compose.onNodeWithTag("reader_settings_done").performClick()
        compose.waitUntil(5_000) { surfaceGeometry().bitmapWidth > 0 }
        compose.onNodeWithTag("reader_rotate_counterclockwise").performClick()
        assertEquals(3, surfaceGeometry().quarterTurns)
        compose.onNodeWithTag("reader_rotate_clockwise").performClick()
        assertEquals(0, surfaceGeometry().quarterTurns)
        repeat(4) { compose.onNodeWithTag("reader_rotate_clockwise").performClick() }
        assertEquals(0, surfaceGeometry().quarterTurns)
        compose.onNodeWithTag("reader_rotate_clockwise").performClick()
        compose.onNodeWithTag("reader_page").performTouchInput { doubleClick(center) }
        compose.waitUntil(5_000) { surfaceGeometry().zoom > 1.01f }
        compose.onNodeWithTag("reader_page").performTouchInput { swipe(Offset(width * .5f, height * .5f), Offset(width * .7f, height * .7f)) }
        assertEquals(1, surfaceGeometry().quarterTurns)
        assertEquals("page1.png", selected.get())
        compose.onNodeWithTag("reader_rotate_clockwise").performClick()
        assertEquals(1f, surfaceGeometry().zoom, .01f)
        compose.onNodeWithTag("reader_page").performTouchInput { swipeLeft() }; awaitPage(1)
        compose.waitUntil(5_000) { surfaceGeometry().quarterTurns == 0 }
        compose.onNodeWithTag("reader_rotate_clockwise").performClick()
        compose.onNodeWithTag("page_overview").performClick()
        compose.onNodeWithTag("thumbnail_0").performClick(); awaitPage(0)
        compose.waitUntil(5_000) { surfaceGeometry().quarterTurns == 0 }
        compose.onNodeWithTag("reader_settings").performClick()
        compose.onNodeWithContentDescription("Show image rotation buttons").performScrollTo().performClick().assertIsOff()
        compose.onNodeWithTag("reader_settings_done").performClick()
        compose.onNodeWithTag("reader_rotate_clockwise").assertDoesNotExist()
    }

    @Test fun gesturesAndBoundariesReportExactOriginalPagePath() {
        start()
        compose.onNodeWithTag("reader_page").performTouchInput { swipeRight() }
        awaitPage(0)
        compose.onNodeWithTag("reader_page").performTouchInput { swipeLeft() }; awaitPage(1)
        compose.onNodeWithTag("reader_page").performTouchInput { swipeLeft() }; awaitPage(2)
        compose.onNodeWithTag("reader_page").performTouchInput { swipeLeft() }; awaitPage(2)
        compose.onNodeWithTag("reader_page").performTouchInput { swipeRight() }; awaitPage(1)
        compose.onNodeWithTag("reader_close").performClick()
        assertEquals(1, closed.get())
        assertEquals("page2.png", selected.get())
    }

    @Test fun jumpRejectsOutOfRangeAndNonNumericInputThenNavigates() {
        start()
        compose.onNodeWithTag("page_jump").performClick()
        for (invalid in listOf("0", "4", "999999999999999999999", "abc")) {
            compose.onNodeWithTag("page_number_input").performTextReplacement(invalid)
            compose.onNodeWithTag("confirm_page_jump").assertIsNotEnabled()
            assertEquals("page1.png", selected.get())
        }
        compose.onNodeWithTag("page_number_input").performTextReplacement("3")
        compose.onNodeWithTag("confirm_page_jump").performClick()
        awaitPage(2)
    }

    @Test fun overviewSelectsTheOriginalRelativePath() {
        start()
        compose.onNodeWithTag("page_overview").performClick()
        compose.onNodeWithTag("thumbnail_2").performClick()
        awaitPage(2)
        compose.onNodeWithTag("thumbnail_grid").assertDoesNotExist()
    }

    @Test fun reversedTapZonesNavigateInTheOppositeDirection() {
        start(initial = 1, reversed = true)
        compose.onNodeWithTag("reader_page").performTouchInput { click(Offset(width * 0.85f, height * 0.45f)) }
        awaitPage(0)
        compose.onNodeWithTag("reader_page").performTouchInput { click(Offset(width * 0.15f, height * 0.45f)) }
        awaitPage(1)
    }

    @Test fun reversedSwipesNavigateInTheOppositeDirection() {
        start(initial = 1, reversed = true)
        compose.onNodeWithTag("reader_page").performTouchInput { swipeLeft() }
        awaitPage(0)
        compose.onNodeWithTag("reader_page").performTouchInput { swipeRight() }
        awaitPage(1)
    }

    @Test fun backRevealsHiddenControlsBeforeClosingReader() {
        start()
        compose.onNodeWithTag("reader_page").performTouchInput { click(center) }
        waitForChrome(false)
        back(); waitForChrome(true)
        assertEquals(0, closed.get())
        assertEquals("page1.png", selected.get())
        back()
        compose.waitUntil(5_000) { closed.get() == 1 }
    }

    @Test fun zoomedSwipeKeepsPageAndCenterTapStillTogglesControls() {
        start(initial = 1)
        compose.onNodeWithTag("reader_page").performTouchInput { doubleClick(center) }
        // Native GestureDetector uses wall-clock timers rather than the Compose animation clock.
        android.os.SystemClock.sleep(400)
        compose.onNodeWithTag("reader_page").performTouchInput { swipeLeft() }
        compose.waitForIdle()
        assertEquals("page2.png", selected.get())
        compose.onNodeWithTag("reader_page").performTouchInput { click(center) }
        waitForChrome(false)
        assertEquals("page2.png", selected.get())
    }

    @Test fun doubleTapZoomToggleAppliesImmediatelyDuringReading() {
        start()
        compose.onNodeWithTag("reader_settings").performClick()
        compose.onNodeWithContentDescription("Double-tap to zoom").performScrollTo().assertIsOn().performClick().assertIsOff()
        compose.onNodeWithTag("reader_settings_done").performClick()
        compose.onNodeWithTag("reader_page").performTouchInput { doubleClick(Offset(width * .9f, height * .4f)) }
        compose.runOnIdle { assertEquals("Both immediate taps must advance, including before recomposition", "page10.png", selected.get()) }
        awaitPage(2)
        assertEquals(1f, surfaceGeometry().zoom, .01f)
        compose.onNodeWithTag("reader_settings").performClick()
        compose.onNodeWithContentDescription("Double-tap to zoom").performScrollTo().assertIsOff().performClick().assertIsOn()
        compose.onNodeWithTag("reader_settings_done").performClick()
        compose.onNodeWithTag("reader_page").performTouchInput { doubleClick(center) }
        compose.waitUntil(5_000) { surfaceGeometry().zoom > 1.01f }
        assertEquals("page10.png", selected.get())
    }

    @Test fun actualZoomRequestsLargerDecodedPixelsAndDoesNotFadeUpgrade() {
        val big = Bitmap.createBitmap(3000, 4000, Bitmap.Config.RGB_565)
        big.eraseColor(Color.MAGENTA)
        pages[1].file.outputStream().use { big.compress(Bitmap.CompressFormat.PNG, 100, it) }
        big.recycle()
        start(initial = 1)
        compose.waitUntil(10_000) { surfaceGeometry().bitmapHeight >= 720 }
        val fitted = surfaceGeometry()
        compose.runOnIdle { preferences.value = preferences.value.copy(animate = true) }
        compose.onNodeWithTag("reader_page").performTouchInput { doubleClick(center) }
        compose.waitUntil(15_000) { surfaceGeometry().bitmapHeight > fitted.bitmapHeight }
        val detailed = surfaceGeometry()
        assertEquals(2.5f, detailed.zoom, 0.01f)
        assertEquals(255, detailed.alpha)
        assertTrue(detailed.bitmapWidth.toLong() * detailed.bitmapHeight * 4 <= 30L * 1024 * 1024)
    }

    private fun surfaceGeometry(): ReaderGeometry {
        var result: ReaderGeometry? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val surface = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                .firstNotNullOfOrNull { it.window.decorView.findViewWithTag<ReaderImageSurface>("reader_image_surface") }
            result = checkNotNull(surface).geometrySnapshot()
        }
        return checkNotNull(result)
    }

    @Test fun expiredThumbnailLeaseBecomesUnavailableWithoutCrashingComposition() {
        compose.setContent {
            val state by rememberReaderBitmap(pages[0], 384, thumbnail = true, retainImageWork = { throw IllegalStateException("Session closed") })
            Text(if (state == BitmapState.Failed) "Unavailable" else "Loading")
        }
        compose.onNodeWithText("Unavailable").assertExists()
    }

    @Test fun corruptPageKeepsNavigationAvailable() {
        pages[0].file.writeText("not an image")
        start()
        compose.waitUntil(5_000) { compose.onAllNodesWithText("This page cannot be displayed").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("reader_page").performTouchInput { swipeLeft() }
        awaitPage(1)
    }

    @Test fun controlsAreOneCompactRowWithoutFilenamesOrTurnButtons() {
        start()
        compose.onNodeWithText("Test archive").assertDoesNotExist()
        pages.forEach { compose.onNodeWithText(it.relativePath, substring = true).assertDoesNotExist() }
        compose.onNodeWithText("Previous").assertDoesNotExist()
        compose.onNodeWithText("Next").assertDoesNotExist()
        compose.onNodeWithTag("previous_page").assertDoesNotExist()
        compose.onNodeWithTag("next_page").assertDoesNotExist()
        val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        val row = compose.onNodeWithTag("reader_bottom_controls").fetchSemanticsNode().boundsInRoot
        assertTrue("Bottom controls must remain bounded on tablets", row.width <= 600 * density + 1)
        assertEquals("Controls stay in one 48 dp row", 48 * density, row.height, 1f)
        val actions = listOf("reader_close", "reader_settings", "reader_hide", "page_jump", "page_overview")
        actions.forEach { tag ->
            val bounds = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot
            assertTrue("$tag needs a 48 dp touch target", bounds.width >= 48 * density - 1 && bounds.height >= 48 * density - 1)
        }
        compose.onNodeWithTag("page_overview").performClick()
        pages.forEach { compose.onNodeWithText(it.relativePath, substring = true).assertDoesNotExist() }
    }

    @Test fun hidingSliderAndCountLeavesTwoCompactActions() {
        start()
        compose.runOnIdle { preferences.value = preferences.value.copy(showSlider = false, showCount = false) }
        compose.onNodeWithTag("page_slider").assertDoesNotExist()
        compose.onNodeWithTag("page_jump").assertHasClickAction()
        compose.onNodeWithTag("page_overview").assertHasClickAction()
        val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        val row = compose.onNodeWithTag("reader_bottom_controls").fetchSemanticsNode().boundsInRoot
        assertEquals(104 * density, row.width, 1f)
        compose.onNodeWithTag("reader_hide").performClick()
        waitForChrome(false)
        compose.onNodeWithTag("reader_bottom_controls").assertDoesNotExist()
        back(); waitForChrome(true)
    }

    @Test fun emptySpaceBetweenTopActionsRemainsReadingCanvas() {
        start()
        val closeBounds = compose.onNodeWithTag("reader_close").fetchSemanticsNode().boundsInRoot
        val pageBounds = compose.onNodeWithTag("reader_page").fetchSemanticsNode().boundsInRoot
        compose.onNodeWithTag("reader_page").performTouchInput {
            click(Offset(width * 0.5f, closeBounds.center.y - pageBounds.top))
        }
        awaitPage(1)
    }

    @Test fun tapAreaPresetsUseExactPhysicalWidthsAndReverseOnlyTheirActions() {
        start()
        compose.onNodeWithTag("reader_settings").performClick()
        compose.onNodeWithTag("tap_area_settings").performScrollTo().performClick()
        for (percent in listOf(10, 30, 50, 70, 90)) {
            compose.onNodeWithTag("tap_area_preset_$percent").performScrollTo().performClick().assertIsSelected()
            compose.runOnIdle { assertEquals(percent / 100f, preferences.value.tapRatio, 0.0001f) }
        }
        compose.onNodeWithTag("tap_area_preview").performScrollTo().assertContentDescriptionEquals(
            "Tap area preview. Left 90 percent: Previous page. Right 10 percent: Next page. Small center area: show or hide controls.")
        compose.onNodeWithTag("tap_area_done").performClick()
        compose.onNodeWithContentDescription("Reverse taps and swipes").performScrollTo().performClick()
        compose.onNodeWithTag("tap_area_settings").performScrollTo().performClick()
        compose.onNodeWithTag("tap_area_preview").performScrollTo().assertContentDescriptionEquals(
            "Tap area preview. Left 90 percent: Next page. Right 10 percent: Previous page. Small center area: show or hide controls.")
        compose.onNodeWithTag("tap_area_preset_70").performScrollTo()
        compose.onNodeWithTag("tap_area_recommended_70", useUnmergedTree = true).assertExists()
        compose.onNodeWithTag("tap_area_recommended_30", useUnmergedTree = true).assertDoesNotExist()
        compose.runOnIdle { assertEquals(0.9f, preferences.value.tapRatio, 0.0001f) }
        compose.onNodeWithTag("tap_area_done").performClick()
        compose.onNodeWithTag("reader_settings_done").performClick()
        compose.onNodeWithTag("reader_settings_list").assertDoesNotExist()
    }

    @Test fun sharedSettingsExplainGesturesAndRemainDismissible() {
        start()
        compose.onNodeWithTag("reader_settings").performClick()
        compose.onNodeWithTag("reader_help_settings").performScrollTo().performClick()
        compose.onNodeWithTag("reader_help_dialog").assertIsDisplayed()
        compose.onNodeWithText("Pinch to zoom and drag to pan.", substring = true).assertExists()
        compose.onNodeWithTag("reader_help_done").performClick()
        compose.onNodeWithTag("reader_settings_done").performClick()
        awaitPage(0)
    }

    @Test fun changingSortKeepsCurrentIdentityAndChangesItsPosition() {
        start(initial = 0)
        compose.runOnIdle { preferences.value = preferences.value.copy(sortCriterion = SortCriterion.MODIFIED) }
        compose.onNodeWithTag("page_jump").assertTextContains("3 / 3")
        assertEquals("page1.png", selected.get())
        compose.onNodeWithTag("reader_page").performTouchInput { swipeRight() }
        compose.waitUntil(5_000) { selected.get() == "page2.png" }
    }
}
