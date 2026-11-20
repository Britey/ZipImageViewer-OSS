package com.brite.zipimageviewer.bridge

import android.app.Application
import androidx.appcompat.widget.AppCompatImageView
import com.brite.zipimageviewer.AppCoordinator
import com.brite.zipimageviewer.reader.ReaderBitmapDecoder
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.ZIVArchiveCoverManagerDelegate
import com.facebook.react.viewmanagers.ZIVArchiveCoverManagerInterface
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class ArchiveCoverManager : SimpleViewManager<ArchiveCoverView>(), ZIVArchiveCoverManagerInterface<ArchiveCoverView> {
    private val delegate = ZIVArchiveCoverManagerDelegate(this)
    override fun getName() = "ZIVArchiveCover"
    override fun getDelegate() = delegate
    override fun createViewInstance(context: ThemedReactContext) = ArchiveCoverView(context)
    @ReactProp(name = "archiveId")
    override fun setArchiveId(view: ArchiveCoverView, value: String?) { view.setArchive(value) }
    @ReactProp(name = "readerId")
    override fun setReaderId(view: ArchiveCoverView, value: String?) { view.setReader(value) }
    @ReactProp(name = "pageIndex", defaultInt = 0)
    override fun setPageIndex(view: ArchiveCoverView, value: Int) { view.setPageIndex(value) }
    override fun onDropViewInstance(view: ArchiveCoverView) { view.dispose(); super.onDropViewInstance(view) }
}

/** Preview lanes, color/orientation handling and leases are the same as the native library. */
class ArchiveCoverView(context: ThemedReactContext) : AppCompatImageView(context) {
    private val coordinator = AppCoordinator.get(context.applicationContext as Application)
    private var scope: CoroutineScope? = null
    private var job: Job? = null
    private var archiveId: String? = null
    private var readerId: String? = null
    private var pageIndex = 0
    private var generation = 0
    init { scaleType = ScaleType.FIT_CENTER; importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO; placeholder() }
    private fun placeholder() { setImageResource(android.R.drawable.ic_menu_gallery) }
    fun setArchive(value: String?) {
        if (archiveId == value) return
        archiveId = value
        load()
    }
    fun setReader(value: String?) { if (readerId != value) { readerId = value; load() } }
    fun setPageIndex(value: Int) { if (pageIndex != value) { pageIndex = value; load() } }
    override fun onAttachedToWindow() { super.onAttachedToWindow(); load() }
    override fun onDetachedFromWindow() { dispose(); super.onDetachedFromWindow() }
    fun dispose() { generation++; scope?.cancel(); scope = null; job = null; placeholder() }
    private fun load() {
        generation++
        job?.cancel()
        placeholder()
        if (!isAttachedToWindow) return
        if (scope == null) scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val record = if (!readerId.isNullOrEmpty()) coordinator.currentArchive?.takeIf { coordinator.readerSessionId == readerId }
            else coordinator.archives.value.firstOrNull { it.id == archiveId && it.available }
        if (record == null) return
        val page = if (!readerId.isNullOrEmpty()) {
            coordinator.readerCoverPage(readerId!!, pageIndex)
        } else record.pages.firstOrNull()
        if (page == null) return
        // Reserve synchronously, before IO dispatch or a possible cache removal.
        val release = runCatching { coordinator.repository.retainImageWork(record.id) }.getOrNull() ?: return
        val token = generation
        job = scope!!.launch {
            try {
                val image = withContext(Dispatchers.IO) {
                    val preview = coordinator.repository.previewFile(record, page)
                    preview?.let { ReaderBitmapDecoder.decode(it, 384, thumbnail = true) }
                        ?: ReaderBitmapDecoder.decode(coordinator.repository.pageFile(record, page), 384, thumbnail = true)
                }
                if (generation == token && image != null) setImageBitmap(image)
            } catch (cancelled: CancellationException) { throw cancelled }
              catch (_: Exception) { /* Unavailable/corrupt cover keeps its placeholder. */ }
            finally { release() }
        }
    }
}
