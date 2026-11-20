package com.brite.zipimageviewer.bridge

import android.app.Application
import android.widget.FrameLayout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import com.brite.zipimageviewer.AppCoordinator
import com.brite.zipimageviewer.reader.ReaderPage
import com.brite.zipimageviewer.reader.ReaderScreen
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.ZIVReaderCanvasManagerDelegate
import com.facebook.react.viewmanagers.ZIVReaderCanvasManagerInterface

class ReaderCanvasManager : SimpleViewManager<ReaderCanvasView>(), ZIVReaderCanvasManagerInterface<ReaderCanvasView> {
    private val delegate = ZIVReaderCanvasManagerDelegate(this)
    override fun getName() = "ZIVReaderCanvas"
    override fun getDelegate() = delegate
    override fun createViewInstance(context: ThemedReactContext) = ReaderCanvasView(context)
    @ReactProp(name = "readerId")
    override fun setReaderId(view: ReaderCanvasView, value: String?) { view.setReader(value) }
    override fun onDropViewInstance(view: ReaderCanvasView) { view.disposeComposition(); super.onDropViewInstance(view) }
}
class ReaderCanvasView(context: ThemedReactContext) : FrameLayout(context) {
    private val canvas = ComposeView(context)
    fun disposeComposition() { canvas.disposeComposition() }
    private val model = AppCoordinator.get(context.applicationContext as Application)
    private var readerId: String? = null
    init {
        addView(canvas, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        canvas.setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnDetachedFromWindow)
    }
    fun setReader(value: String?) {
        if (readerId == value) return
        readerId = value
        canvas.setContent {
            val record = model.currentArchive
            if (record != null && model.readerSessionId == value && value != null) {
                val adapter = remember(value) { model.attachReaderAdapter(value) }
                val pages = remember(value) { record.pages.map { ReaderPage(it.originalPath,
                    model.repository.pageFile(record, it), it.modifiedAt, it.createdAt, model.repository.previewFile(record, it)) } }
                MaterialTheme(colorScheme = darkColorScheme()) {
                    ReaderScreen(record.title, pages, model.readerPagePath, model.preferences, model::updatePreferences,
                        model::progress, model::closeReader, retainImageWork = { model.repository.retainImageWork(record.id) }, shared = adapter)
                }
            }
        }
    }
}
