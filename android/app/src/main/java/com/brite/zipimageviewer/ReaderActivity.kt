package com.brite.zipimageviewer

import android.content.pm.ActivityInfo
import android.os.Bundle
import android.view.KeyEvent
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.defaults.DefaultReactActivityDelegate
import kotlinx.coroutines.launch

/** Shares React controls with iOS; Fabric hosts the retained native reading canvas. */
class ReaderActivity : ReactActivity() {
    private val coordinator by lazy { AppCoordinator.get(application) }
    override fun getMainComponentName() = "ZipImageReader"
    override fun createReactActivityDelegate(): ReactActivityDelegate = DefaultReactActivityDelegate(this, mainComponentName, true)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (resources.configuration.isScreenWideColorGamut) window.colorMode = ActivityInfo.COLOR_MODE_WIDE_COLOR_GAMUT
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                coordinator.changes.collect { if (coordinator.currentArchive == null) finish() }
            }
        }
    }
    override fun onResume() {
        super.onResume()
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }
    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        // RN Modal forwards key-up to the Activity, whose currentFocus cannot
        // see the dialog's EditText. Password typing must not trigger double-R reload.
        if (BuildConfig.DEBUG && keyCode == KeyEvent.KEYCODE_R && coordinator.passwordPrompt != null) return false
        return super.onKeyUp(keyCode, event)
    }
    override fun onStop() { coordinator.flushProgress(); super.onStop() }
    // Activity destruction is canvas detachment. Explicit Close/Back owns finalization.
}
