package com.brite.zipimageviewer.bridge

import android.app.Application
import com.brite.zipimageviewer.AppCoordinator
import com.brite.zipimageviewer.MainActivity
import com.brite.zipimageviewer.data.CacheLimitPreview
import com.brite.zipimageviewer.data.CacheLimits
import com.brite.zipimageviewer.reader.ReaderCoverIndex
import com.brite.zipimageviewer.reader.ReaderPreferences
import com.brite.zipimageviewer.reader.SortCriterion
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

/** Small JSON messages only: no sandbox paths, URI grants, passwords, or image buffers in snapshots. */
class NativeProtocol(private val model: AppCoordinator, private val application: Application) {
    private val libraryOrder = mutableMapOf<String, ReaderCoverIndex>()
    private var revision = 0L
    private var previousPayload: String? = null
    private var dismissedStorageWarning: String? = null
    private var lastError: String? = null
    private var errorId: String? = null
    private var lastPreview: CacheLimitPreview? = null
    private var previewToken: String? = null

    /** Called on main. A revision identifies content, so snapshot responses and events can race safely. */
    fun snapshot(): String {
        val payload = content()
        val body = payload.toString()
        if (body != previousPayload) { revision++; previousPayload = body }
        return payload.put("revision", revision).toString()
    }

    private fun content(): JSONObject {
        val p = model.preferences
        val archives = model.archives.value
        libraryOrder.keys.retainAll(archives.map { it.id }.toSet())
        val error = model.error ?: model.repository.storageWarning.value?.takeUnless { it == dismissedStorageWarning }
        if (lastError != error) { lastError = error; errorId = error?.let { UUID.randomUUID().toString() } }
        val preview = model.cachePreview
        if (lastPreview !== preview) { lastPreview = preview; previewToken = preview?.let { UUID.randomUUID().toString() } }
        val picker = application.getSharedPreferences("archive_picker", 0)
        val choice = picker.getString("selection", "system") ?: "system"
        return JSONObject().apply {
            put("protocolVersion", 1)
            put("ready", model.ready)
            put("busy", model.busy || model.cacheSettingsBusy)
            put("capabilities", JSONObject().put("pickerPreferences", true))
            put("archives", JSONArray(archives.map { archive -> JSONObject().apply {
                put("id", archive.id); put("title", archive.title); put("pageCount", archive.pages.size)
                put("retainedBytes", archive.bytes); put("available", archive.available)
                val index = libraryOrder.getOrPut(archive.id) { ReaderCoverIndex() }
                    .position(archive.id, archive.pages, p, archive.currentPagePath)
                put("progress", if (index < 0 || archive.pages.isEmpty()) 0.0 else (index + 1).toDouble() / archive.pages.size)
                put("currentPage", if (archive.pages.isEmpty()) 0 else (index + 1).coerceIn(1, archive.pages.size))
                put("format", archive.format)
                put("lastOpenedAt", Instant.ofEpochMilli(archive.lastOpened).toString())
            } }))
            put("preferences", JSONObject().apply {
                put("showRotationButtons", p.showRotationButtons); put("showSlider", p.showSlider); put("showCount", p.showCount); put("centerTap", p.centerTap); put("doubleTapZoom", p.doubleTapZoom)
                put("reversed", p.reversed); put("animate", p.animate); put("tapRatio", p.tapRatio.toDouble())
                put("sortCriterion", p.sortCriterion.name.lowercase()); put("descending", p.descending)
                put("thumbnailSize", p.thumbnailSize.toDouble())
            })
            put("compressImages", model.compressImages)
            put("cache", limitsJSON(CacheLimits(model.cacheBudget, model.archiveCountLimit)).apply {
                put("retainedBytes", archives.sumOf { it.bytes }); put("archiveCount", archives.size)
                put("pendingDeletionBytes", model.repository.pendingDeletionBytes.value)
            })
            put("import", model.operationId?.let { id -> JSONObject().apply {
                put("id", id); put("phase", model.status); put("busy", model.busy)
                put("fraction", model.fraction?.toDouble() ?: JSONObject.NULL)
                put("passwordRequired", model.passwordPrompt != null)
                model.passwordPrompt?.let { put("passwordMessage", it) }
                put("cancellable", true)
            } } ?: JSONObject.NULL)
            put("reader", model.currentArchive?.let { JSONObject().put("id", model.readerSessionId).put("archiveId", it.id).put("title", it.title).put("ui", JSONObject().apply {
                val surface = model.readerSurface
                put("page", surface.page); put("count", surface.count); put("displayedPage", surface.displayedPage ?: JSONObject.NULL)
                put("controls", surface.controls); put("failed", surface.failed); put("detailFailed", surface.detailFailed); put("sorting", false)
                put("sequence", model.readerSeekSequence)
                put("tool", model.readerTool ?: JSONObject.NULL); put("temporary", it.isTemporary); put("noticePending", model.readerNoticePending)
            }) } ?: JSONObject.NULL)
            put("error", error?.let { JSONObject().put("id", errorId).put("title", "ZipImageViewer").put("message", it) } ?: JSONObject.NULL)
            put("cachePreview", preview?.let { JSONObject().apply {
                put("reclaimedBytes", it.reclaimedBytes)
                put("token", previewToken); put("limits", limitsJSON(it.limits)); put("changed", model.cachePreviewChanged)
                put("victims", JSONArray(it.candidates.map { victim -> JSONObject().put("id", victim.id).put("title", victim.title) }))
            } } ?: JSONObject.NULL)
            put("picker", JSONObject().apply {
                picker.getString("label", null)?.let { put("label", it) }
                put("mode", when (choice) { "system" -> "system"; "ask" -> "ask"; else -> "selected" })
                if (choice != "system" && choice != "ask") put("packageName", choice.substringBefore('/'))
                put("showAllFiles", picker.getBoolean("show_all_files", true))
            })
        }
    }

    fun dispatch(raw: String, host: MainActivity?): String {
        require(raw.length <= 32_768) { "Command is too large." }
        val command = JSONObject(raw)
        fun integer(name: String, maximum: Double): Long? {
            if (!command.has(name)) return null
            val number = command.get(name) as? Number ?: throw IllegalArgumentException("Invalid $name.")
            val value = number.toDouble()
            require(value.isFinite() && value >= 0 && value <= maximum && value == kotlin.math.floor(value)) { "Invalid $name." }
            return number.toLong()
        }
        fun operation() { require(command.getString("operationId") == model.operationId) { "That import is no longer active." } }
        fun idle() { require(model.ready && !model.busy && !model.cacheSettingsBusy && model.operationId == null && model.currentArchive == null) { "Finish the current operation before opening another archive or changing storage." } }
        fun archive() = model.archives.value.firstOrNull { it.id == command.getString("id") }
            ?: throw IllegalArgumentException("That archive is no longer in the library.")
        when (command.getString("type")) {
            "refresh" -> model.bootstrap()
            "presentationReady" -> Unit
            "pickArchive" -> { idle(); requireNotNull(host) { "Open the library before choosing an archive." }.openArchivePicker() }
            "pickArchiveOnce" -> { idle(); requireNotNull(host) { "Open the library before choosing an archive." }.configureArchivePicker(false) }
            "configurePicker" -> { idle(); requireNotNull(host) { "Open the library before configuring its picker." }.configureArchivePicker() }
            "openArchive" -> { idle(); model.open(archive()) }
            "submitPassword" -> { operation(); require(model.passwordPrompt != null) { "No password is requested." }; model.submitPassword(command.getString("password")) }
            "cancelImport" -> { operation(); model.cancelImport() }
            "closeReader" -> model.closeReader()
            "readerAction" -> model.readerAction(command.getString("readerId"), command.getString("action"),
                integer("page", Int.MAX_VALUE.toDouble())?.toInt(), command.optBoolean("scrubbing", false),
                integer("sequence", 9_007_199_254_740_991.0))
            "updatePreferences" -> {
                val p = command.getJSONObject("preferences")
                val ratio = p.getDouble("tapRatio"); val thumbnail = p.getDouble("thumbnailSize")
                require(ratio.isFinite() && ratio in .1.. .9 && thumbnail.isFinite() && thumbnail in 0.0..1.0) { "Invalid reader preference." }
                model.updatePreferences(ReaderPreferences(p.getBoolean("showSlider"), p.getBoolean("showCount"),
                    p.getBoolean("centerTap"), p.getBoolean("reversed"), p.getBoolean("animate"), ratio.toFloat(),
                    SortCriterion.valueOf(p.getString("sortCriterion").uppercase()), p.getBoolean("descending"), thumbnail.toFloat(), p.getBoolean("doubleTapZoom"), p.optBoolean("showRotationButtons", false)))
            }
            "setCompression" -> { idle(); model.setImageCompression(command.getBoolean("enabled")) }
            "removeArchive" -> { idle(); model.remove(archive()) }
            "clearArchives" -> { idle(); model.clear() }
            "previewCacheLimits" -> {
                idle()
                val limits = command.getJSONObject("limits")
                model.previewCacheLimits(CacheLimits(limits.getLong("maximumBytes"),
                    if (limits.isNull("maximumArchiveCount")) null else limits.getInt("maximumArchiveCount")))
            }
            "applyCachePreview" -> { idle(); require(command.getString("token") == previewToken && model.cachePreview != null) { "That cache preview is no longer current." }; model.applyCachePreview() }
            "dismissCachePreview" -> { idle(); model.dismissCachePreview() }
            "dismissError" -> { require(command.getString("id") == errorId) { "That message is no longer current." }; if (model.error == null) dismissedStorageWarning = model.repository.storageWarning.value; model.dismissError() }
            "setShowAllFiles" -> { application.getSharedPreferences("archive_picker", 0).edit().putBoolean("show_all_files", command.getBoolean("enabled")).apply(); model.pickerChanged() }
            else -> throw IllegalArgumentException("Unsupported command.")
        }
        return snapshot()
    }
    private fun limitsJSON(limits: CacheLimits) = JSONObject().put("maximumBytes", limits.maximumBytes)
        .put("maximumArchiveCount", limits.maximumArchiveCount ?: JSONObject.NULL)
}
