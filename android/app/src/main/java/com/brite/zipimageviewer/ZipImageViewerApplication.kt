package com.brite.zipimageviewer

import android.app.Application
import com.facebook.react.PackageList
import com.facebook.react.ReactApplication
import com.facebook.react.ReactHost
import com.facebook.react.ReactNativeApplicationEntryPoint.loadReactNative
import com.facebook.react.defaults.DefaultReactHost.getDefaultReactHost
import com.brite.zipimageviewer.bridge.ZipImageViewerPackage

class ZipImageViewerApplication : Application(), ReactApplication {
    override val reactHost: ReactHost by lazy {
        getDefaultReactHost(applicationContext, PackageList(this).packages.apply {
            add(ZipImageViewerPackage())
        }, useDevSupport = BuildConfig.DEBUG)
    }
    override fun onCreate() {
        super.onCreate()
        AppCoordinator.get(this)
        loadReactNative(this)
    }
}
