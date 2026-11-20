package com.brite.zipimageviewer.bridge

import android.app.Application
import android.net.Uri
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import com.brite.zipimageviewer.AppCoordinator
import com.brite.zipimageviewer.AppRepository
import com.facebook.react.bridge.BridgeReactContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.drop

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File

/** Exercises the shipping native boundary and process owner, independently of a JS runtime. */
class NativeProtocolTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val app get() = instrumentation.targetContext.applicationContext as Application
    private lateinit var coordinator: AppCoordinator
    @Before fun before() {
        runBlocking { AppRepository.resetForTests() }
        File(app.filesDir, "archive-library").deleteRecursively()
        app.getSharedPreferences("reader", 0).edit().clear().commit()
        app.getSharedPreferences("archive-repository", 0).edit().clear().commit()
        main { coordinator = AppCoordinator.get(app) }
        await { coordinator.ready }
    }
    @After fun after() {
        runBlocking { AppRepository.resetForTests() }
        File(app.cacheDir, "bridge-reader-fixture.cbz").delete()
    }
    private fun main(block: () -> Unit) = instrumentation.runOnMainSync(block)
    private fun await(predicate: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 30_000
        var satisfied = false
        while (!satisfied && SystemClock.uptimeMillis() < deadline) {
            main { satisfied = predicate() }
            if (!satisfied) SystemClock.sleep(20)
        }
        assertTrue("Native operation did not finish", satisfied)
    }
    private fun snapshot(): JSONObject {
        lateinit var result: JSONObject
        main { result = JSONObject(coordinator.protocol.snapshot()) }
        return result
    }
    private fun command(command: JSONObject): JSONObject {
        lateinit var result: JSONObject
        main { result = JSONObject(coordinator.protocol.dispatch(command.toString(), null)) }
        return result
    }
    private fun readerFixture(): File {
        val file = File(app.cacheDir, "bridge-reader-fixture.cbz")
        instrumentation.context.assets.open("archive-fixtures/field-notes.cbz").use { input ->
            file.outputStream().use { input.copyTo(it) }
        }
        return file
    }
    @Test fun nativeOnlyObserversReceiveAsyncImportBeforeAnyComposeViewExists() {
        var readerEvent: JSONObject? = null
        val source = readerFixture()
        lateinit var observer: Job
        main {
            observer = CoroutineScope(Dispatchers.Main.immediate).launch {
                coordinator.changes.drop(1).collect {
                    val state = JSONObject(coordinator.protocol.snapshot())
                    if (!state.isNull("reader")) readerEvent = state
                }
            }
            coordinator.import(Uri.fromFile(source))
        }
        try {
            await { readerEvent != null || coordinator.error != null }
            assertNull(coordinator.error)
            assertEquals(coordinator.currentArchive!!.id, readerEvent!!.getJSONObject("reader").getString("archiveId"))
        } finally { main { observer.cancel(); coordinator.closeReader() } }
    }
    @Test fun snapshotsHaveStableRevisionsAndDurablePreferencesHaveOneOwner() {
        val first = snapshot()
        assertEquals(first.getLong("revision"), snapshot().getLong("revision"))
        val preferences = first.getJSONObject("preferences").put("showSlider", false)
        val changed = command(JSONObject().put("type", "updatePreferences").put("preferences", preferences))
        assertTrue(changed.getLong("revision") > first.getLong("revision"))
        assertFalse(app.getSharedPreferences("reader", 0).getBoolean("slider", true))
        assertFalse(changed.getJSONObject("preferences").getBoolean("showSlider"))
        main { assertSame(coordinator, AppCoordinator.get(app)) }
    }
    @Test fun doubleTapZoomDefaultsOnAndPersistsAcrossOwnerRecreation() {
        val first = snapshot()
        assertTrue(first.getJSONObject("preferences").getBoolean("doubleTapZoom"))
        command(JSONObject().put("type", "updatePreferences").put("preferences",
            first.getJSONObject("preferences").put("doubleTapZoom", false)))
        assertFalse(app.getSharedPreferences("reader", 0).getBoolean("doubleTapZoom", true))
        runBlocking { AppRepository.resetForTests() }
        main { coordinator = AppCoordinator.get(app) }
        await { coordinator.ready }
        assertFalse(snapshot().getJSONObject("preferences").getBoolean("doubleTapZoom"))
    }
    @Test fun moduleDetachPreservesStagedPasswordSessionAndRejectsLatePassword() {
        val source = File(app.cacheDir, "bridge-encrypted.zip")
        instrumentation.context.assets.open("archive-fixtures/encrypted.zip").use { input -> source.outputStream().use { input.copyTo(it) } }
        main { coordinator.import(Uri.fromFile(source)) }
        await { coordinator.passwordPrompt != null }
        val pending = snapshot().getJSONObject("import")
        val operationId = pending.getString("id")
        source.delete() // A reconnect/password retry must use native staged bytes.
        main {
            ZipImageViewerModule(BridgeReactContext(app)).invalidate()
            assertSame(coordinator, AppCoordinator.get(app))
        }
        assertEquals(operationId, snapshot().getJSONObject("import").getString("id"))
        command(JSONObject().put("type", "submitPassword").put("operationId", operationId).put("password", "test-password"))
        await { coordinator.currentArchive != null || coordinator.error != null }
        assertNull(coordinator.error)
        assertNotNull(coordinator.currentArchive)
        assertFalse(snapshot().toString().contains("test-password"))
        main {
            assertThrows(IllegalArgumentException::class.java) {
                coordinator.protocol.dispatch(JSONObject().put("type", "submitPassword").put("operationId", operationId).put("password", "ignored").toString(), null)
            }
            coordinator.closeReader()
            coordinator.closeReader() // Close is idempotent and does not release a second lease.
        }
        assertTrue(snapshot().isNull("reader"))
    }
    @Test fun readerCommandsRejectOldSessionsAndOutOfOrderScrubsWithoutClosingTheirLeases() {
        val source = readerFixture()
        main { coordinator.import(Uri.fromFile(source)) }
        await { coordinator.currentArchive != null && !coordinator.busy }
        val id = snapshot().getJSONObject("reader").getString("id")
        val selected = mutableListOf<Pair<Int?, Boolean>>()
        main { coordinator.attachReaderAdapter(id).action = { action, page, scrub -> if (action == "seek") selected += page to scrub } }
        fun seek(sequence: Long, page: Int, scrub: Boolean) = command(JSONObject().put("type", "readerAction")
            .put("readerId", id).put("action", "seek").put("page", page).put("scrubbing", scrub).put("sequence", sequence))
        main {
            for (invalid in listOf(1.5, "2", -1, Double.POSITIVE_INFINITY)) {
                val raw = JSONObject().put("type", "readerAction").put("readerId", id).put("action", "seek")
                    .put("page", if (invalid == Double.POSITIVE_INFINITY) 2 else invalid).put("sequence", if (invalid == Double.POSITIVE_INFINITY) 9_007_199_254_740_992L else 1)
                assertThrows(IllegalArgumentException::class.java) { coordinator.protocol.dispatch(raw.toString(), null) }
            }
        }
        seek(10, 2, true); seek(11, 3, false); seek(9, 1, true)
        assertEquals(listOf(2 to true, 3 to false), selected)
        main {
            assertThrows(IllegalArgumentException::class.java) {
                coordinator.readerAction("expired", "close", null, false, null)
            }
            assertNotNull(coordinator.currentArchive)
        }
        main {
            val previous = coordinator.attachReaderAdapter(id)
            previous.onState(com.brite.zipimageviewer.reader.ReaderSurfaceState(count = 3, controls = false))
            previous.action = null
            val reconnected = coordinator.attachReaderAdapter(id)
            assertNotSame(previous, reconnected)
            assertFalse(reconnected.initialControls)
            previous.onState(com.brite.zipimageviewer.reader.ReaderSurfaceState(count = 3, controls = true))
            assertFalse(coordinator.readerSurface.controls)
        }
        command(JSONObject().put("type", "readerAction").put("readerId", id).put("action", "openPages"))
        assertEquals("pages", snapshot().getJSONObject("reader").getJSONObject("ui").getString("tool"))
        command(JSONObject().put("type", "readerAction").put("readerId", id).put("action", "back"))
        assertTrue(snapshot().getJSONObject("reader").getJSONObject("ui").isNull("tool"))
        command(JSONObject().put("type", "readerAction").put("readerId", id).put("action", "close"))
        assertTrue(snapshot().isNull("reader"))
        main { assertThrows(IllegalArgumentException::class.java) { coordinator.readerAction(id, "close", null, false, null) } }
    }
    @Test fun storageWorkRemainsBusyAndRejectsOverlappingCommands() {
        main {
            val result = JSONObject(coordinator.protocol.dispatch("{\"type\":\"clearArchives\"}", null))
            assertTrue(result.getBoolean("busy"))
            assertThrows(IllegalArgumentException::class.java) {
                coordinator.protocol.dispatch("{\"type\":\"pickArchive\"}", null)
            }
        }
        await { !coordinator.cacheSettingsBusy }
        assertFalse(snapshot().getBoolean("busy"))
    }
    @Test fun dismissedQuotaPreviewCannotBeCommittedByDelayedJavascript() {
        command(JSONObject().put("type", "previewCacheLimits").put("limits",
            JSONObject().put("maximumBytes", 500_000_000).put("maximumArchiveCount", 5)))
        await { coordinator.cachePreview != null && !coordinator.cacheSettingsBusy }
        val token = snapshot().getJSONObject("cachePreview").getString("token")
        command(JSONObject().put("type", "dismissCachePreview"))
        main {
            assertThrows(IllegalArgumentException::class.java) {
                coordinator.protocol.dispatch(JSONObject().put("type", "applyCachePreview").put("token", token).toString(), null)
            }
        }
        assertEquals(2_000_000_000L, snapshot().getJSONObject("cache").getLong("maximumBytes"))
        assertTrue(snapshot().isNull("cachePreview"))
    }
    @Test fun staleIdsAndInvalidPreferenceValuesDoNotMutateState() {
        val before = snapshot()
        main {
            assertThrows(IllegalArgumentException::class.java) { coordinator.protocol.dispatch("{\"type\":\"openArchive\",\"id\":\"missing\"}", null) }
            assertThrows(IllegalArgumentException::class.java) {
                coordinator.protocol.dispatch(JSONObject().put("type", "updatePreferences")
                    .put("preferences", before.getJSONObject("preferences").put("tapRatio", 3)).toString(), null)
            }
        }
        assertEquals(.3, snapshot().getJSONObject("preferences").getDouble("tapRatio"), .00001)
        assertTrue(snapshot().getJSONArray("archives").length() == 0)
    }
}
