package com.brite.zipimageviewer.access

import android.content.Intent
import android.content.IntentFilter
import android.app.Activity
import android.app.Instrumentation
import android.accessibilityservice.AccessibilityServiceInfo
import android.view.accessibility.AccessibilityNodeInfo
import android.net.Uri
import com.brite.zipimageviewer.reader.ReaderImageSurface
import com.brite.zipimageviewer.reader.ReaderGeometry
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.*
import androidx.test.platform.app.InstrumentationRegistry
import com.brite.zipimageviewer.AppRepository
import com.brite.zipimageviewer.AppCoordinator
import com.brite.zipimageviewer.MainActivity
import com.brite.zipimageviewer.ReaderActivity
import com.brite.zipimageviewer.ZipImageViewerApplication
import com.facebook.react.interfaces.TaskInterface
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File

class ExternalArchiveActivityTest {
    @get:Rule val ui = createEmptyComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val provider = Uri.parse("content://com.brite.zipimageviewer.test.intents")
    private var activity: MainActivity? = null
    private lateinit var model: AppCoordinator
    @Before fun before() {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        automation.serviceInfo = automation.serviceInfo.apply { flags = flags or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS }
        resetReactRuntime()
        runBlocking { AppRepository.resetForTests() }
        File(context.filesDir, "archive-library").deleteRecursively()
        context.getSharedPreferences("reader", 0).edit().clear().commit()
        context.getSharedPreferences("archive-repository", 0).edit().clear().commit()
        context.getSharedPreferences("archive_picker", 0).edit().clear().commit()
        context.contentResolver.call(provider, "reset", null, null)
    }
    @After fun after() {
        val hosts = mutableListOf<android.app.Activity>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            if (::model.isInitialized) { model.closeReader(); model.cancelImport() }
            val monitor = ActivityLifecycleMonitorRegistry.getInstance()
            hosts += listOf(Stage.RESUMED, Stage.PAUSED, Stage.STARTED, Stage.STOPPED, Stage.CREATED)
                .flatMap { monitor.getActivitiesInStage(it) }.distinct()
                .filter { it is MainActivity || it is ReaderActivity }
            hosts.forEach { it.finish() }
        }
        // finish() and an idle main queue do not establish onDestroy: the window transition
        // can finish later. RN detaches a surface synchronously in onDestroy, then stops it
        // asynchronously. Destroying the runtime first resets the instance reference, so that
        // later stop is dropped and Fabric is destroyed with an outstanding surface.
        ui.waitUntil(30_000) {
            var destroyed = false
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                destroyed = hosts.all { it.isDestroyed }
            }
            destroyed
        }
        resetReactRuntime()
    }

    private fun resetReactRuntime() {
        lateinit var task: TaskInterface<Void>
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            task = (context.applicationContext as ZipImageViewerApplication).reactHost.destroy("Disposable native-owner test reset", null)
        }
        ui.waitUntil(30_000) { task.isCompleted() }
        assertNull("React teardown must finish without an error", task.getError())
        assertFalse("React teardown must not be cancelled", task.isCancelled())
    }
    private fun onMainActivity(block: (MainActivity) -> Unit) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync { block(requireNotNull(activity)) }
    }
    private fun launch(request: Intent) {
        // ActivityScenario matches lifecycle callbacks using the original intent. Real VIEW/SEND
        // replaces that intent, and the separate reader also covers MainActivity. Use the actual
        // lifecycle monitor here so this test does not change app intents to satisfy a harness.
        activity = InstrumentationRegistry.getInstrumentation().startActivitySync(request.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        onMainActivity { model = AppCoordinator.get(it.application) }
    }
    private fun recreateAfterIncomingIntent() {
        ui.waitUntil(10_000) {
            var resumed = false
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                resumed = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                    .any { it === activity }
            }
            resumed
        }
        val previous = activity
        onMainActivity { it.recreate() }
        ui.waitUntil(10_000) {
            var replaced = false
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                val current = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                    .filterIsInstance<MainActivity>().firstOrNull { it !== previous }
                if (current != null) { activity = current; replaced = true }
            }
            replaced
        }
        onMainActivity { model = AppCoordinator.get(it.application) }
    }
    private fun sharedReaderVisible(identifier: String = "readerClose"): Boolean {
        fun containsChrome(node: AccessibilityNodeInfo): Boolean {
            if (node.viewIdResourceName == identifier || node.viewIdResourceName?.endsWith("/$identifier") == true) return true
            for (index in 0 until node.childCount) {
                val child = node.getChild(index) ?: continue
                try { if (containsChrome(child)) return true } finally { child.recycle() }
            }
            return false
        }
        val root = InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow ?: return false
        return try { containsChrome(root) } finally { root.recycle() }
    }
    private fun recreateForegroundReader() {
        ui.waitUntil(30_000) { sharedReaderVisible() }
        lateinit var previous: ReaderActivity
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            previous = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                .filterIsInstance<ReaderActivity>().single()
            previous.recreate()
        }
        ui.waitUntil(10_000) {
            var replaced = false
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                replaced = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                    .filterIsInstance<ReaderActivity>().any { it !== previous }
            }
            replaced
        }
    }
    private fun intent(action: String, name: String) = Intent(context, MainActivity::class.java).apply {
        this.action = action
        val uri = provider.buildUpon().appendPath(name).build()
        if (action == Intent.ACTION_VIEW) setDataAndType(uri, "application/octet-stream")
        else { type = "application/zip"; putExtra(Intent.EXTRA_STREAM, uri) }
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    private fun awaitReader() {
        ui.waitUntil(30_000) { model.currentArchive != null || model.error != null }
        assertNull(model.error)
        assertNotNull(model.currentArchive)
    }
    private fun opens() = context.contentResolver.call(provider, "count", null, null)!!.getInt("opens")
    @Test fun coldViewRotationAndNewShareUseOneActivityAndDoNotReplayTheLaunch() {
        launch(intent(Intent.ACTION_VIEW, "one"))
        awaitReader()
        assertEquals(1, opens())
        val firstModel = model
        // The reader is now a separate foreground Activity; forcing the covered React host
        // to RESUMED via ActivityScenario.recreate would immediately present the reader again.
        recreateForegroundReader()
        onMainActivity { model = AppCoordinator.get(it.application) }
        assertSame(firstModel, model)
        assertEquals(1, opens())
        context.startActivity(intent(Intent.ACTION_SEND, "two"))
        ui.waitUntil(30_000) { model.currentArchive?.title == "External plain.zip" || model.error != null }
        assertNull(model.error)
        assertEquals("External plain.zip", model.currentArchive?.title)
        assertEquals(2, opens())
        onMainActivity {
            assertEquals(Intent.ACTION_SEND, it.intent.action)
            assertSame(model, AppCoordinator.get(it.application))
            model.closeReader()
        }
        recreateAfterIncomingIntent()
        ui.waitForIdle()
        assertNull(model.currentArchive)
        assertEquals(2, opens())
    }
    @Test fun freshSendOpensAndUnreadableReplacementPreservesReader() {
        launch(intent(Intent.ACTION_SEND, "one"))
        awaitReader()
        val original = model.currentArchive!!.id
        context.startActivity(intent(Intent.ACTION_VIEW, "missing"))
        ui.waitUntil(15_000) { model.error != null }
        assertEquals(original, model.currentArchive?.id)
        onMainActivity {
            assertEquals(Intent.ACTION_VIEW, it.intent.action)
            assertEquals("missing", it.intent.data?.lastPathSegment)
            assertSame(model, AppCoordinator.get(it.application))
        }
    }
    private fun clickSharedAction(identifier: String): Boolean {
        fun click(node: AccessibilityNodeInfo): Boolean {
            if (node.viewIdResourceName == identifier || node.viewIdResourceName?.endsWith("/$identifier") == true || node.contentDescription?.toString() == identifier) {
                return node.refresh() && node.isVisibleToUser && node.isEnabled && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            }
            for (index in 0 until node.childCount) {
                val child = node.getChild(index) ?: continue
                try { if (click(child)) return true } finally { child.recycle() }
            }
            return false
        }
        val root = InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow ?: return false
        return try { click(root) } finally { root.recycle() }
    }

    private fun awaitSharedAction(identifier: String) {
        fun frame(): Pair<Int, android.graphics.Rect>? {
            fun find(node: AccessibilityNodeInfo): Pair<Int, android.graphics.Rect>? {
                if (node.viewIdResourceName == identifier || node.viewIdResourceName?.endsWith("/$identifier") == true || node.contentDescription?.toString() == identifier) {
                    if (!node.refresh() || !node.isVisibleToUser || !node.isEnabled) return null
                    val bounds = android.graphics.Rect(); node.getBoundsInScreen(bounds)
                    return if (bounds.isEmpty) null else node.windowId to bounds
                }
                for (index in 0 until node.childCount) {
                    val child = node.getChild(index) ?: continue
                    try { find(child)?.let { return it } } finally { child.recycle() }
                }
                return null
            }
            val root = InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow ?: return null
            return try { if (root.refresh()) find(root) else null } finally { root.recycle() }
        }
        var previous: Pair<Int, android.graphics.Rect>? = null
        var stableSince = android.os.SystemClock.uptimeMillis()
        // Native state and accessibility identifiers can arrive before the new
        // Activity/modal touch surface settles. Poll only readiness, then click once.
        ui.waitUntil(10_000) {
            val current = frame()
            if (current == null || current != previous) {
                previous = current; stableSince = android.os.SystemClock.uptimeMillis()
            }
            current != null && android.os.SystemClock.uptimeMillis() - stableSince >= 1_000
        }
    }

    @Test fun emptySharedLibraryPickerCancelsImportsAndReturnsAfterCacheClear() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assertFalse(context.assets.list("")!!.contains("demo.cbz"))
        assertFalse(context.assets.list("archive-fixtures")?.contains("field-notes.cbz") ?: false)
        launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN))
        ui.waitUntil(30_000) { model.ready && sharedReaderVisible("openEmptyArchive") }
        assertFalse(sharedReaderVisible("openSample"))
        val filter = IntentFilter(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            addDataType("*/*")
        }
        fun cancelPicker() {
            val monitor = instrumentation.addMonitor(filter,
                Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null), true)
            try {
                awaitSharedAction("openEmptyArchive")
                assertTrue(clickSharedAction("openEmptyArchive"))
                ui.waitUntil(10_000) { monitor.hits == 1 }
                ui.waitUntil(10_000) { sharedReaderVisible("openEmptyArchive") }
                onMainActivity {
                    assertTrue(model.archives.value.isEmpty())
                    assertNull(model.currentArchive)
                    assertNull(model.error)
                    assertFalse(model.busy)
                }
            } finally { instrumentation.removeMonitor(monitor) }
        }
        repeat(2) { cancelPicker() }
        val result = Intent().setData(provider.buildUpon().appendPath("one").build())
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val monitor = instrumentation.addMonitor(filter,
            Instrumentation.ActivityResult(Activity.RESULT_OK, result), true)
        try {
            awaitSharedAction("openEmptyArchive")
            assertTrue(clickSharedAction("openEmptyArchive"))
            ui.waitUntil(10_000) { monitor.hits == 1 }
            awaitReader()
            ui.waitUntil(30_000) { sharedReaderVisible() }
            assertEquals(3, model.currentArchive!!.pages.size)
            assertFalse(sharedReaderVisible("openEmptyArchive"))
            assertTrue(clickSharedAction("readerClose"))
            ui.waitUntil(30_000) { sharedReaderVisible("openArchive") }
            onMainActivity { assertEquals(1, model.archives.value.size); model.clear() }
            ui.waitUntil(30_000) { !model.cacheSettingsBusy && sharedReaderVisible("openEmptyArchive") }
        } finally { instrumentation.removeMonitor(monitor) }
        cancelPicker()
    }

    @Test fun incomingArchiveUpdatesSharedSnapshotAndPresentsSharedReader() {
        launch(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN))
        context.startActivity(intent(Intent.ACTION_VIEW, "one"))
        awaitReader()
        onMainActivity {
            val snapshot = org.json.JSONObject(model.protocol.snapshot())
            assertEquals(model.currentArchive!!.id, snapshot.getJSONObject("reader").getString("archiveId"))
        }
        ui.waitUntil(30_000) { sharedReaderVisible() }
        ui.onNodeWithTag("reader").assertIsDisplayed()
    }
    private fun nativeGeometry(): ReaderGeometry? {
        var geometry: ReaderGeometry? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            geometry = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                .filterIsInstance<ReaderActivity>().firstOrNull()?.window?.decorView
                ?.findViewWithTag<ReaderImageSurface>("reader_image_surface")?.geometrySnapshot()
        }
        return geometry
    }
    @Test fun rotationPreferenceReloadsFromDurableStorageInANewCoordinator() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val application = context.applicationContext as android.app.Application
        instrumentation.runOnMainSync { model = AppCoordinator.get(application) }
        assertFalse(model.preferences.showRotationButtons)
        for (enabled in listOf(true, false)) {
            instrumentation.runOnMainSync { model.updatePreferences(model.preferences.copy(showRotationButtons = enabled)) }
            runBlocking { AppCoordinator.resetForTests() }
            instrumentation.runOnMainSync { model = AppCoordinator.get(application) }
            assertEquals(enabled, model.preferences.showRotationButtons)
            assertEquals(enabled, org.json.JSONObject(model.protocol.snapshot()).getJSONObject("preferences").getBoolean("showRotationButtons"))
        }
    }

    @Test fun sharedRotationControlsPersistAndSurviveReaderRecreationAndOrientation() {
        launch(intent(Intent.ACTION_VIEW, "one")); awaitReader()
        ui.waitUntil(30_000) { sharedReaderVisible() }
        assertFalse(model.preferences.showRotationButtons)
        assertFalse(sharedReaderVisible("readerRotateClockwise"))
        awaitSharedAction("readerSettings")
        assertTrue(clickSharedAction("readerSettings"))
        awaitSharedAction("Show image rotation buttons")
        assertTrue(clickSharedAction("Show image rotation buttons"))
        ui.waitUntil(5_000) { model.preferences.showRotationButtons }
        assertTrue(context.getSharedPreferences("reader", 0).getBoolean("showRotationButtons", false))
        assertTrue(clickSharedAction("readerSettingsDone"))
        ui.waitUntil(10_000) { sharedReaderVisible("readerRotateClockwise") && (nativeGeometry()?.bitmapHeight ?: 0) > 0 }
        assertTrue(clickSharedAction("readerRotateCounterclockwise"))
        ui.waitUntil(5_000) { nativeGeometry()?.quarterTurns == 3 }
        assertTrue(clickSharedAction("readerRotateClockwise"))
        ui.waitUntil(5_000) { nativeGeometry()?.quarterTurns == 0 }
        for (turn in listOf(1, 2, 3, 0)) {
            assertTrue(clickSharedAction("readerRotateClockwise"))
            ui.waitUntil(5_000) { nativeGeometry()?.quarterTurns == turn }
        }
        assertTrue(clickSharedAction("readerRotateClockwise"))
        ui.waitUntil(5_000) { nativeGeometry()?.quarterTurns == 1 && model.readerSurface.imageQuarterTurns == 1 }
        recreateForegroundReader()
        ui.waitUntil(30_000) { sharedReaderVisible("readerRotateClockwise") && nativeGeometry()?.quarterTurns == 1 }
        awaitSharedAction("readerRotateClockwise")
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                .filterIsInstance<ReaderActivity>().single().requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
        ui.waitUntil(30_000) {
            context.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE &&
                sharedReaderVisible("readerRotateClockwise") && nativeGeometry()?.quarterTurns == 1
        }
        awaitSharedAction("readerRotateCounterclockwise")
        assertTrue(clickSharedAction("readerRotateCounterclockwise"))
        ui.waitUntil(5_000) { nativeGeometry()?.quarterTurns == 0 }
        ui.onNodeWithTag("reader_page").performTouchInput { swipeLeft() }
        ui.waitUntil(10_000) { model.readerSurface.page == 2 && model.readerSurface.displayedPage == 2 }
        assertEquals(0, nativeGeometry()?.quarterTurns)
        awaitSharedAction("readerSettings")
        assertTrue(clickSharedAction("readerSettings"))
        awaitSharedAction("Show image rotation buttons")
        assertTrue(clickSharedAction("Show image rotation buttons"))
        ui.waitUntil(5_000) { !model.preferences.showRotationButtons }
        assertFalse(context.getSharedPreferences("reader", 0).getBoolean("showRotationButtons", true))
        assertTrue(clickSharedAction("readerSettingsDone"))
        ui.waitUntil(10_000) { !sharedReaderVisible("readerRotateClockwise") }
    }

    @Test fun fabricCanvasKeepsNativePageGesturesZoomAndPan() {
        launch(intent(Intent.ACTION_VIEW, "one"))
        awaitReader()
        ui.waitUntil(30_000) { sharedReaderVisible() }
        ui.waitUntil(10_000) { (nativeGeometry()?.bitmapHeight ?: 0) > 0 }
        ui.onNodeWithTag("reader_page").performTouchInput { swipeLeft() }
        ui.waitUntil(10_000) { model.readerSurface.page == 2 && model.readerSurface.displayedPage == 2 }
        ui.onNodeWithTag("reader_page").performTouchInput { doubleClick(center) }
        ui.waitUntil(5_000) { (nativeGeometry()?.zoom ?: 0f) > 1.01f }
        ui.onNodeWithTag("reader_page").performTouchInput { swipeLeft() }
        ui.waitForIdle()
        assertEquals(2, model.readerSurface.page)
        assertTrue((nativeGeometry()?.zoom ?: 0f) > 1.01f)
        ui.onNodeWithTag("reader_page").performTouchInput { doubleClick(center) }
        ui.waitUntil(5_000) { nativeGeometry()?.zoom == 1f }
        ui.onNodeWithTag("reader_page").performTouchInput { swipeRight() }
        // Native page state can precede React's accessibility-tree update.
        // Keep the same deadline and require both observable postconditions.
        ui.waitUntil(5_000) { model.readerSurface.page == 1 && sharedReaderVisible() }
    }
    @Test fun encryptedReplacementUsesTheSharedReaderPasswordPromptAndKeepsTheOldLeaseUntilAccepted() {
        launch(intent(Intent.ACTION_VIEW, "one"))
        awaitReader()
        val original = model.currentArchive!!.id
        ui.waitUntil(30_000) { sharedReaderVisible() }
        context.startActivity(intent(Intent.ACTION_SEND, "encrypted"))
        ui.waitUntil(30_000) { model.passwordPrompt != null || model.error != null }
        assertNull(model.error)
        assertEquals(original, model.currentArchive?.id)
        ui.waitUntil(30_000) { sharedReaderVisible("passwordInput") }
        onMainActivity { model.submitPassword("test-password") }
        ui.waitUntil(30_000) { model.currentArchive?.title == "External encrypted.zip" || model.error != null }
        assertNull(model.error)
        assertEquals("External encrypted.zip", model.currentArchive?.title)
        ui.waitUntil(30_000) { sharedReaderVisible() }
        assertEquals(2, opens())
    }
    @Test fun manifestResolvesArchivesButDoesNotClaimTextOrWebLinks() {
        for (action in listOf(Intent.ACTION_VIEW, Intent.ACTION_SEND)) {
            for (type in listOf("application/zip", "application/x-zip-compressed", "application/vnd.comicbook+zip", "application/x-cbz", "application/x-7z-compressed", "application/octet-stream")) {
                val request = Intent(action).setPackage(context.packageName).apply {
                    if (action == Intent.ACTION_VIEW) setDataAndType(provider, type) else this.type = type
                }
                assertNotNull("$action $type", context.packageManager.resolveActivity(request, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY))
            }
        }
        assertNull(context.packageManager.resolveActivity(Intent(Intent.ACTION_SEND).setType("text/plain").setPackage(context.packageName), android.content.pm.PackageManager.MATCH_DEFAULT_ONLY))
        assertNull(context.packageManager.resolveActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://example.com/a.zip")).setPackage(context.packageName), android.content.pm.PackageManager.MATCH_DEFAULT_ONLY))
    }

    @Test fun absentProviderGrantShowsAnErrorWithoutOpeningAnything() {
        val request = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            setDataAndType(Uri.parse("content://com.brite.zipimageviewer.test.private-intents/one"), "application/zip")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        launch(request)
        ui.waitUntil(15_000) { model.error != null }
        assertNull(model.currentArchive)
    }
}
