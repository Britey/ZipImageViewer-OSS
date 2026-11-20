package com.brite.zipimageviewer.reader

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** One active operation and one replaceable pending request. All coordination runs on main. */
internal class LatestReaderLane(private val scope: CoroutineScope) {
    private data class Request(val epoch: Long, val identity: String?, val work: suspend () -> Bitmap?, val publish: (Bitmap?) -> Unit, val release: () -> Unit)
    private var epoch = 0L
    private var active = false
    private var pending: Request? = null
    private var closed = false
    internal val pendingCount get() = if (pending == null) 0 else 1
    internal val isActive get() = active
    fun invalidate() { epoch++; pending?.release?.invoke(); pending = null }
    fun close() { closed = true; invalidate() }
    fun dropPending(exceptIdentity: String?) {
        if (pending != null && pending?.identity != exceptIdentity) { pending?.release?.invoke(); pending = null }
    }
    fun submit(release: () -> Unit, work: suspend () -> Bitmap?, publish: (Bitmap?) -> Unit, identity: String? = null) {
        if (closed) { release(); return }
        val request = Request(epoch, identity, work, publish, release)
        if (active) { pending?.release?.invoke(); pending = request } else start(request)
    }
    private fun start(request: Request) {
        active = true
        scope.launch {
            try {
                val result = try { request.work() } catch (_: Exception) { null }
                // Keep active during publishing: reentrant requests replace pending work.
                if (!closed && request.epoch == epoch) request.publish(result)
            } finally {
                request.release()
                active = false
                val next = pending
                pending = null
                if (next != null && !closed) start(next) else next?.release?.invoke()
            }
        }
    }
}

internal data class ReaderFrame(val page: ReaderPage, val bitmap: Bitmap, val kind: ReaderDecodeKind)

/** Separate replaceable preview/fitted/detail lanes, with truthful scrub-target identity. */
internal class ReaderImagePipeline(
    private val retainImageWork: (() -> (() -> Unit))? = null,
    private val decode: suspend (ReaderPage, ReaderDecodeKind, Int) -> Bitmap? = { page, kind, edge -> ReaderBitmapDecoder.decodePage(page, kind, edge) },
    private val now: () -> Long = SystemClock::uptimeMillis,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    internal val previews = LatestReaderLane(scope)
    internal val fitted = LatestReaderLane(scope)
    internal val details = LatestReaderLane(scope)
    var frame: ReaderFrame? by mutableStateOf(null); private set
    var failed by mutableStateOf(false); private set
    var detailFailed by mutableStateOf(false); private set
    var detailLoading by mutableStateOf(false); private set
    var geometryEpoch by mutableStateOf(0L); private set
    var scrubbing by mutableStateOf(false); private set
    var targetPath: String? by mutableStateOf(null); private set
    private var target: ReaderPage? = null
    private var viewport = 384
    private var neighbors: List<ReaderPage> = emptyList()
    private var selection = 0L
    private var closed = false
    private var scrubTimer: Job? = null
    private var lastInput = 0L
    private var lastSample: String? = null
    private var settledPath: String? = null
    private var scrubDirection = 0
    private var scrubPosition = -1
    private var suppressPrefetch = false
    private var detailRequested = false

    private fun invalidate() { selection++; previews.invalidate(); fitted.invalidate(); details.invalidate(); detailLoading = false; detailRequested = false }
    private fun request(lane: LatestReaderLane, page: ReaderPage, kind: ReaderDecodeKind, complete: (Bitmap?) -> Unit) {
        if (closed) return
        // Pending jobs own leases as well as active jobs; replacement releases them immediately.
        val release = try { retainImageWork?.invoke() ?: {} } catch (_: Exception) {
            complete(null)
            return
        }
        val requestedViewport = viewport
        lane.submit(release, { decode(page, kind, requestedViewport) }, complete, identity = page.relativePath)
    }
    fun select(page: ReaderPage, viewportPixels: Int, adjacent: List<ReaderPage> = emptyList()) {
        if (closed) return
        val samePage = targetPath == page.relativePath
        val wasScrubbing = scrubbing
        val sameSource = target?.file == page.file
        if (samePage && sameSource && !wasScrubbing && (detailRequested || frame?.page?.file == page.file && frame?.kind == ReaderDecodeKind.DETAIL)) {
            // Resize/sort/direction changes must not cancel a selected zoom upgrade, or
            // replace already higher-resolution pixels with an unnecessary fitted decode.
            viewport = viewportPixels; neighbors = adjacent; target = page
            return
        }
        scrubTimer?.cancel(); scrubTimer = null; scrubbing = false
        invalidate()
        if (!samePage || wasScrubbing) geometryEpoch++
        target = page; targetPath = page.relativePath; viewport = viewportPixels; neighbors = adjacent
        failed = false; detailFailed = false; suppressPrefetch = false
        val generation = selection
        request(previews, page, ReaderDecodeKind.PREVIEW) { bitmap ->
            if (generation == selection && bitmap != null && (frame?.page?.relativePath != page.relativePath || frame?.kind == ReaderDecodeKind.PREVIEW)) {
                frame = ReaderFrame(page, bitmap, ReaderDecodeKind.PREVIEW)
            }
        }
        request(fitted, page, ReaderDecodeKind.FITTED) { bitmap ->
            if (generation != selection) return@request
            val viableCurrent = frame?.page?.file == page.file && frame?.kind != ReaderDecodeKind.PREVIEW
            failed = bitmap == null && !viableCurrent
            if (bitmap != null && !(frame?.page?.relativePath == page.relativePath && frame?.kind == ReaderDecodeKind.DETAIL)) {
                frame = ReaderFrame(page, bitmap, ReaderDecodeKind.FITTED)
            }
            if (bitmap == null && frame?.page?.relativePath != page.relativePath) frame = null
            if (!detailRequested) prefetch(generation, 0)
        }
    }
    private fun prefetch(generation: Long, index: Int) {
        if (closed || suppressPrefetch || scrubbing || detailRequested || generation != selection || index >= neighbors.size) return
        request(fitted, neighbors[index], ReaderDecodeKind.FITTED) { prefetch(generation, index + 1) }
    }
    fun requestDetail() {
        val page = target ?: return
        if (closed || scrubbing || detailRequested || (frame?.page?.relativePath == page.relativePath && frame?.kind == ReaderDecodeKind.DETAIL)) return
        detailRequested = true; detailFailed = false; detailLoading = true
        suppressPrefetch = true
        fitted.invalidate() // Do not keep queued neighbor work ahead of the requested detail.
        val generation = selection
        request(details, page, ReaderDecodeKind.DETAIL) { bitmap ->
            if (generation != selection) return@request
            detailLoading = false
            detailFailed = bitmap == null
            if (bitmap != null) { frame = ReaderFrame(page, bitmap, ReaderDecodeKind.DETAIL); failed = false }
            else detailRequested = false // Another zoom gesture or explicit retry can try again.
        }
    }
    fun scrub(page: ReaderPage, position: Int, viewportPixels: Int) {
        if (closed) return
        if (!scrubbing) {
            invalidate(); scrubbing = true; geometryEpoch++; lastSample = null; settledPath = null; scrubDirection = 0; scrubPosition = position
            scrubTimer = scope.launch { while (scrubbing && !closed) { sampleScrub(); delay(33) } }
        }
        val direction = position.compareTo(scrubPosition)
        if (direction != 0 && scrubDirection != 0 && direction != scrubDirection) { previews.invalidate(); lastSample = null }
        if (direction != 0) scrubDirection = direction
        if (targetPath != page.relativePath) { fitted.invalidate(); settledPath = null; lastInput = now() }
        target = page; targetPath = page.relativePath; viewport = viewportPixels; scrubPosition = position
        failed = false; detailFailed = false; lastInput = now()
    }
    private fun sampleScrub() {
        val page = target ?: return
        if (!scrubbing || closed) return
        if (lastSample == page.relativePath) {
            if (now() - lastInput >= 150 && settledPath != page.relativePath) {
                settledPath = page.relativePath
                val generation = selection
                fitted.invalidate()
                request(fitted, page, ReaderDecodeKind.FITTED) { bitmap ->
                    if (generation == selection && scrubbing && targetPath == page.relativePath && bitmap != null) frame = ReaderFrame(page, bitmap, ReaderDecodeKind.FITTED)
                }
            }
            return
        }
        lastSample = page.relativePath
        val sampledAt = now()
        request(previews, page, ReaderDecodeKind.PREVIEW) { bitmap ->
            val currentFitted = frame?.page?.relativePath == targetPath && frame?.kind != ReaderDecodeKind.PREVIEW
            if (scrubbing && now() - sampledAt <= 150 && !currentFitted && bitmap != null) frame = ReaderFrame(page, bitmap, ReaderDecodeKind.PREVIEW)
        }
    }
    fun retry() { val page = target ?: return; select(page, viewport, neighbors) }
    fun memoryPressure() {
        ReaderBitmapDecoder.clearCache()
        suppressPrefetch = true
        // Preserve the displayed bitmap and selected queued/active work. Dropping selected
        // detail here would strand the user on a preview until another navigation gesture.
        previews.dropPending(targetPath)
        fitted.dropPending(targetPath)
        details.dropPending(targetPath)
    }
    fun registerMemoryCallbacks(context: Context): () -> Unit {
        val callbacks = object : ComponentCallbacks2 {
            override fun onConfigurationChanged(newConfig: Configuration) = Unit
            override fun onLowMemory() = memoryPressure()
            override fun onTrimMemory(level: Int) { if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) memoryPressure() }
        }
        context.applicationContext.registerComponentCallbacks(callbacks)
        return { context.applicationContext.unregisterComponentCallbacks(callbacks) }
    }
    fun close() {
        if (closed) return
        closed = true; scrubTimer?.cancel(); scrubbing = false
        previews.close(); fitted.close(); details.close()
        frame = null; ReaderBitmapDecoder.clearCache()
        // Running noninterruptible decodes finish and release their own file leases.
    }
}
