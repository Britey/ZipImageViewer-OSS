package com.brite.zipimageviewer

import android.app.Application
import android.net.Uri
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import com.brite.zipimageviewer.data.ArchiveRecord
import com.brite.zipimageviewer.data.ArchiveImportSession
import com.brite.zipimageviewer.data.CacheLimits
import com.brite.zipimageviewer.data.CacheLimitPreview
import com.brite.zipimageviewer.data.CacheLimitApplyResult
import com.brite.zipimageviewer.data.PasswordRequiredException
import com.brite.zipimageviewer.reader.ReaderPreferences
import com.brite.zipimageviewer.reader.SortCriterion
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow


/** Process-owned native operations. React module detach/reload never cancels these sessions. */
class AppCoordinator private constructor(private val application: Application) {
    private val mutableChanges = MutableStateFlow(0L)
    val changes = mutableChanges.asStateFlow()
    // Native events are the source of invalidation; Compose is only a retained UI adapter.
    private fun <T> nativeState(initial: T) = NativeState(initial) { mutableChanges.value += 1 }
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    companion object {
        private var instance: AppCoordinator? = null
        @Synchronized fun get(application: Application): AppCoordinator =
            instance ?: AppCoordinator(application).also { instance = it }
        internal suspend fun resetForTests() {
            val previous = synchronized(this) { instance }
            withContext(Dispatchers.Main) { previous?.shutdown() }
            previous?.serviceScope?.coroutineContext?.get(Job)?.join()
            synchronized(this) { check(instance === previous); instance = null }
        }
    }
    val protocol by lazy { com.brite.zipimageviewer.bridge.NativeProtocol(this, application) }
    var ready by nativeState(false); private set
    var operationId by nativeState<String?>(null); private set
    var pickerRevision by nativeState(0L); private set
    fun pickerChanged() { pickerRevision++ }
    val repository = AppRepository.get(application)
    val archives = repository.archives
    private val settings = application.getSharedPreferences("reader", 0)
    var preferences by nativeState(readPreferences()); private set
    var compressImages by nativeState(settings.getBoolean("compress-images", false)); private set
    var currentArchive by nativeState<ArchiveRecord?>(null); private set
    var readerSessionId by nativeState<String?>(null); private set
    var readerSurface by nativeState(com.brite.zipimageviewer.reader.ReaderSurfaceState()); private set
    var readerTool by nativeState<String?>(null); private set
    var readerNoticePending by nativeState(false); private set
    var readerAdapter: com.brite.zipimageviewer.reader.SharedReaderAdapter? = null; private set
    private val readerCoverIndex = com.brite.zipimageviewer.reader.ReaderCoverIndex()
    fun readerCoverPage(id: String, index: Int): com.brite.zipimageviewer.data.PageRecord? {
        if (id != readerSessionId) return null
        val archive = currentArchive ?: return null
        return readerCoverIndex.page(id, archive.pages, preferences, index)
    }
    val readerSeekSequence: Long get() = seekSequence
    private var seekSequence = -1L
    fun attachReaderAdapter(id: String): com.brite.zipimageviewer.reader.SharedReaderAdapter {
        check(id == readerSessionId)
        lateinit var adapter: com.brite.zipimageviewer.reader.SharedReaderAdapter
        adapter = com.brite.zipimageviewer.reader.SharedReaderAdapter(readerSurface.controls,
            { state -> if (readerSessionId == id && readerAdapter === adapter) readerSurface = state },
            { tool -> if (readerSessionId == id && readerAdapter === adapter) {
                if (tool == "back") readerAction(id, "back", null, false, null) else readerTool = tool
            } }, readerSurface.imageQuarterTurns, readerSurface.rotationPagePath)
        readerAdapter = adapter
        return adapter
    }
    private fun startReader(archive: ArchiveRecord) {
        currentArchive = archive
        readerSessionId = java.util.UUID.randomUUID().toString()
        readerSurface = com.brite.zipimageviewer.reader.ReaderSurfaceState(count = archive.pages.size)
        readerTool = null; readerNoticePending = archive.isTemporary; readerAdapter = null; seekSequence = -1
    }
    fun readerAction(id: String, action: String, page: Int?, scrubbing: Boolean, sequence: Long?) {
        require(id == readerSessionId && currentArchive != null) { "That reader session has already closed." }
        when (action) {
            "close" -> closeReader()
            "back" -> if (readerTool != null) readerTool = null else if (!readerSurface.controls) readerAdapter?.action?.invoke("showControls", null, false) else closeReader()
            "openJump" -> readerTool = "jump"
            "openPages" -> readerTool = "pages"
            "openSettings" -> readerTool = "settings"
            "openHelp" -> readerTool = "help"
            "dismissTool" -> readerTool = null
            "acknowledgeNotice" -> readerNoticePending = false
            "seek" -> {
                require(page != null && page in 1..readerSurface.count && sequence != null && sequence >= 0) { "Invalid page selection." }
                if (sequence > seekSequence) {
                    val target = requireNotNull(readerAdapter?.action) { "The reading canvas is reconnecting. Try again." }
                    seekSequence = sequence
                    target(action, page, scrubbing)
                }
            }
            "rotateClockwise", "rotateCounterclockwise", "showControls", "toggleControls", "retry", "retryDetail" -> requireNotNull(readerAdapter?.action) { "The reading canvas is reconnecting. Try again." }(action, page, scrubbing)
            else -> throw IllegalArgumentException("Unsupported reader action.")
        }
    }
    var busy by nativeState(false); private set
    var status by nativeState("Preparing archive…"); private set
    var fraction by nativeState<Float?>(null); private set
    var error by nativeState<String?>(null); private set
    var passwordPrompt by nativeState<String?>(null); private set
    var cacheBudget by nativeState(2_000_000_000L); private set
    var archiveCountLimit: Int? by nativeState(null); private set
    var cacheSettingsBusy by nativeState(true); private set
    var cachePreview: CacheLimitPreview? by nativeState(null); private set
    var cachePreviewChanged by nativeState(false); private set
    var query by nativeState("")
    private var pendingImport: ArchiveImportSession? = null
    private var importJob: Job? = null
    private var progressJob: Job? = null
    private var pendingProgress: Pair<String, String>? = null
    private var lastReadingPath: Pair<String, String>? = null
    val readerPagePath: String? get() = lastReadingPath?.takeIf { it.first == currentArchive?.id }?.second
        ?: currentArchive?.currentPagePath

    private var bootstrapJob: Job? = null
    init { bootstrap() }
    fun bootstrap() {
        if (ready || bootstrapJob?.isActive == true) return
        cacheSettingsBusy = true
        bootstrapJob = serviceScope.launch {
        try {
            repository.load()
            cacheBudget = repository.cacheLimits.maximumBytes
            archiveCountLimit = repository.cacheLimits.maximumArchiveCount
            ready = true
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { error = e.message ?: "The library could not be loaded. Try again." }
        finally { cacheSettingsBusy = false }
    } }

    fun import(uri: Uri) {
        if (busy || pendingImport != null) {
            error = "Finish or cancel the current archive import before opening another archive."
            return
        }
        startImport(repository.newImportSession(uri, compressImages), null)
    }

    private fun startImport(request: ArchiveImportSession, password: String?) {
        if (busy) return
        if (pendingImport !== request) operationId = java.util.UUID.randomUUID().toString()
        pendingImport = request
        passwordPrompt = null
        error = null
        busy = true
        status = "Preparing archive…"
        fraction = null
        importJob = serviceScope.launch {
            try {
                val archive = repository.importSession(request, password) { stage, progress ->
                    serviceScope.launch {
                        if (pendingImport === request && busy && importJob?.isActive == true) { status = stage; fraction = progress }
                    }
                }
                closeReader()
                startReader(archive)
                pendingImport = null
            } catch (e: CancellationException) {
                pendingImport = null
                throw e
            } catch (e: PasswordRequiredException) {
                passwordPrompt = e.message ?: "Enter the archive password."
            } catch (e: Exception) {
                pendingImport = null
                error = e.message ?: "The archive could not be opened."
            } finally {
                if (pendingImport !== request) repository.closeImportSession(request)
                busy = false
                if (pendingImport == null) operationId = null
                importJob = null
            }
        }
    }

    fun submitPassword(password: String) { pendingImport?.let { startImport(it, password) } }
    fun dismissPassword() {
        passwordPrompt = null
        pendingImport?.let(repository::closeImportSession)
        pendingImport = null
        operationId = null
    }
    fun setImageCompression(enabled: Boolean) {
        compressImages = enabled
        settings.edit().putBoolean("compress-images", enabled).apply()
    }
    fun cancelImport() { if (passwordPrompt != null) dismissPassword() else { status = "Cancelling…"; importJob?.cancel() } }
    fun dismissError() { error = null }
    fun showError(message: String) { error = message }
    fun open(archive: ArchiveRecord) {
        if (busy || pendingImport != null) return
        busy = true
        serviceScope.launch {
            runCatching { repository.openArchive(archive.id) }
                .onSuccess { closeReader(); startReader(it) }
                .onFailure { error = it.message ?: "Select the source archive again." }
            busy = false
        }
    }
    fun closeReader() {
        val archive = currentArchive
        val lastPath = lastReadingPath
        progressJob?.cancel()
        pendingProgress = null
        lastReadingPath = null
        readerCoverIndex.clear()
        currentArchive = null
        readerSessionId = null; readerTool = null; readerAdapter = null; readerNoticePending = false
        if (archive != null) repository.finishReader(archive.id,
            lastPath?.takeIf { it.first == archive.id }?.second)
    }
    fun progress(path: String) {
        val archive = currentArchive ?: return
        pendingProgress = archive.id to path
        lastReadingPath = pendingProgress
        progressJob?.cancel()
        progressJob = serviceScope.launch { delay(250); flushProgress() }
    }
    fun flushProgress() {
        val pending = pendingProgress ?: return
        pendingProgress = null
        repository.queueProgress(pending.first, pending.second)
    }
    fun remove(archive: ArchiveRecord) {
        if (cacheSettingsBusy) return
        cacheSettingsBusy = true
        serviceScope.launch {
            try { repository.remove(archive.id) } catch (e: Exception) { error = e.message }
            finally { cacheSettingsBusy = false }
        }
    }
    fun clear() {
        if (cacheSettingsBusy) return
        cacheSettingsBusy = true
        serviceScope.launch {
            try { repository.clear() } catch (e: Exception) { error = e.message }
            finally { cacheSettingsBusy = false }
        }
    }
    fun previewCacheLimits(limits: CacheLimits) {
        if (cacheSettingsBusy) return
        cacheSettingsBusy = true
        serviceScope.launch {
            try { cachePreview = repository.previewCacheLimits(limits); cachePreviewChanged = false }
            catch (e: Exception) { error = e.message }
            finally { cacheSettingsBusy = false }
        }
    }
    fun dismissCachePreview() {
        if (!cacheSettingsBusy) { cachePreview = null; cachePreviewChanged = false }
    }
    fun applyCachePreview() {
        val preview = cachePreview ?: return
        if (cacheSettingsBusy) return
        cacheSettingsBusy = true
        serviceScope.launch {
            try {
                when (val result = repository.applyCacheLimits(preview)) {
                    is CacheLimitApplyResult.Applied -> {
                        cacheBudget = result.limits.maximumBytes
                        archiveCountLimit = result.limits.maximumArchiveCount
                        cachePreview = null
                        cachePreviewChanged = false
                    }
                    is CacheLimitApplyResult.NeedsConfirmation -> {
                        cachePreview = result.preview
                        cachePreviewChanged = true
                    }
                }
            } catch (e: Exception) {
                // A disk failure may occur after limits were saved but before eviction finished.
                cacheBudget = repository.cacheLimits.maximumBytes
                archiveCountLimit = repository.cacheLimits.maximumArchiveCount
                error = e.message
            } finally { cacheSettingsBusy = false }
        }
    }
    fun updatePreferences(p: ReaderPreferences) {
        preferences = p
        settings.edit().putBoolean("slider", p.showSlider).putBoolean("count", p.showCount)
            .putBoolean("showRotationButtons", p.showRotationButtons).putBoolean("doubleTapZoom", p.doubleTapZoom).putBoolean("center", p.centerTap).putBoolean("reversed", p.reversed)
            .putBoolean("animate", p.animate).putFloat("tapRatio", p.tapRatio)
            .putString("sort", p.sortCriterion.name).putBoolean("descending", p.descending)
            .putFloat("thumbnail", p.thumbnailSize).apply()
    }
    private fun readPreferences() = ReaderPreferences(
        showRotationButtons = settings.getBoolean("showRotationButtons", false),
        doubleTapZoom = settings.getBoolean("doubleTapZoom", true),
        showSlider = settings.getBoolean("slider", true), showCount = settings.getBoolean("count", true),
        centerTap = settings.getBoolean("center", true), reversed = settings.getBoolean("reversed", false),
        animate = settings.getBoolean("animate", false), tapRatio = settings.getFloat("tapRatio", .3f),
        sortCriterion = runCatching { SortCriterion.valueOf(settings.getString("sort", "FILENAME")!!) }.getOrDefault(SortCriterion.FILENAME),
        descending = settings.getBoolean("descending", false), thumbnailSize = settings.getFloat("thumbnail", .25f)
    ).validated()
    private fun shutdown() {
        importJob?.cancel()
        pendingImport?.let(repository::closeImportSession)
        pendingImport = null
        closeReader()
        serviceScope.cancel()
    }
}
