package com.brite.zipimageviewer

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.ActivityInfo
import android.os.Bundle
import android.view.KeyEvent
import android.widget.CheckBox
import android.widget.LinearLayout
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.defaults.DefaultReactActivityDelegate
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.distinctUntilChanged

/** Native intake is registered before React starts; URI grants never travel through JavaScript. */
class MainActivity : ReactActivity() {
    private val coordinator by lazy { AppCoordinator.get(application) }
    private val picker = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val uri = archivePickerResultUri(result.data)
            if (uri == null) coordinator.showError("This file app did not return one readable archive. Try another file picker.")
            else coordinator.import(uri)
        }
    }
    override fun getMainComponentName() = "ZipImageViewer"
    override fun createReactActivityDelegate(): ReactActivityDelegate =
        DefaultReactActivityDelegate(this, mainComponentName, true)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (resources.configuration.isScreenWideColorGamut) window.colorMode = ActivityInfo.COLOR_MODE_WIDE_COLOR_GAMUT
        if (savedInstanceState == null) receiveArchive(intent)
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                coordinator.changes.map { coordinator.currentArchive?.id }.distinctUntilChanged().collect { id ->
                    if (id != null) startActivity(Intent(this@MainActivity, ReaderActivity::class.java))
                }
            }
        }
    }
    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        // RN Modal forwards key-up to the Activity, whose currentFocus cannot
        // see the dialog's EditText. Password typing must not trigger double-R reload.
        if (BuildConfig.DEBUG && keyCode == KeyEvent.KEYCODE_R && coordinator.passwordPrompt != null) return false
        return super.onKeyUp(keyCode, event)
    }
    override fun onStop() { coordinator.flushProgress(); super.onStop() }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receiveArchive(intent)
    }
    private fun receiveArchive(intent: Intent) {
        when (val request = IncomingArchiveIntent.parse(intent)) {
            IncomingArchiveIntent.Result.Ignore -> Unit
            is IncomingArchiveIntent.Result.Invalid -> coordinator.showError(request.message)
            is IncomingArchiveIntent.Result.Open -> coordinator.import(request.uri)
        }
    }
    fun openArchivePicker() {
        if (coordinator.busy || coordinator.passwordPrompt != null) {
            coordinator.showError("Finish or cancel the current archive import first.")
            return
        }
        val choice = getSharedPreferences("archive_picker", MODE_PRIVATE).getString("selection", "system") ?: "system"
        if (choice == "ask") configureArchivePicker(false) else launchPicker(choice)
    }
    private fun launchPicker(choice: String) {
        val all = getSharedPreferences("archive_picker", MODE_PRIVATE).getBoolean("show_all_files", true)
        try {
            picker.launch(if (choice == "system") archiveSystemPickerIntent(all)
                else archiveFileAppIntent(all, ComponentName.unflattenFromString(choice)
                    ?: throw IllegalArgumentException("Missing picker")))
        } catch (_: RuntimeException) {
            coordinator.showError("That file picker is unavailable. Choose System files or another app in Settings.")
        }
    }
    fun configureArchivePicker(configuring: Boolean = true) {
        val prefs = getSharedPreferences("archive_picker", MODE_PRIVATE)
        val apps = compatiblePickerApps(this)
        val choices = listOf("system") + (if (configuring) listOf("ask") else emptyList()) + apps.map { it.component.flattenToString() }
        val labels = listOf("System files") + (if (configuring) listOf("Choose a file app each time") else emptyList()) + apps.map { it.label }
        val allFiles = CheckBox(this).apply { text = "Show all files"; isChecked = prefs.getBoolean("show_all_files", true) }
        val remember = CheckBox(this).apply { text = "Remember this picker" }
        val options = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; addView(allFiles); if (!configuring) addView(remember) }
        AlertDialog.Builder(this).setTitle(if (configuring) "Default file picker" else "Open archive using")
            .setView(options).setItems(labels.toTypedArray()) { _, index ->
                prefs.edit().putBoolean("show_all_files", allFiles.isChecked).apply()
                if (configuring || remember.isChecked) prefs.edit().putString("selection", choices[index]).putString("label", labels[index]).apply()
                coordinator.pickerChanged()
                if (!configuring) launchPicker(choices[index])
            }.setNegativeButton("Cancel", null).show()
    }
}
