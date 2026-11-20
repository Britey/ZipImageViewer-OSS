package com.brite.zipimageviewer.bridge

import com.facebook.react.uimanager.ViewManager
import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

class ZipImageViewerPackage : BaseReactPackage() {
    override fun createViewManagers(reactContext: ReactApplicationContext): List<ViewManager<*, *>> = listOf(ArchiveCoverManager(), ReaderCanvasManager())
    override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
        if (name == "ZipImageViewer") ZipImageViewerModule(reactContext) else null
    override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
        mapOf("ZipImageViewer" to ReactModuleInfo("ZipImageViewer", ZipImageViewerModule::class.java.name, false, false, false, true))
    }
}
