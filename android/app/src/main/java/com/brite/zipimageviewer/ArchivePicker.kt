package com.brite.zipimageviewer

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal val archivePickerMimeTypes = arrayOf(
    "application/zip", "application/x-zip", "application/x-zip-compressed", "application/x-cbz", "application/cbz",
    "application/vnd.comicbook+zip", "application/x-7z-compressed", "application/octet-stream"
)

internal fun archiveFileAppIntent(showAllFiles: Boolean, component: ComponentName? = null) =
    Intent(Intent.ACTION_GET_CONTENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        type = "*/*"
        if (!showAllFiles) putExtra(Intent.EXTRA_MIME_TYPES, archivePickerMimeTypes)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        this.component = component
        // Do not set EXTRA_LOCAL_ONLY: document providers and file apps may stream a network file.
    }

internal fun archiveSystemPickerIntent(showAllFiles: Boolean) = archiveFileAppIntent(showAllFiles).apply {
    action = Intent.ACTION_OPEN_DOCUMENT
}

/** Some apps use data, others ClipData; never silently pick one item from a multi-file result. */
internal fun archivePickerResultUri(intent: Intent?): Uri? {
    if (intent == null) return null
    return try {
        val clip = intent.clipData
        if (clip != null && clip.itemCount != 1) return null
        val dataUri = intent.data
        val clipUri = clip?.getItemAt(0)?.uri
        if (dataUri != null && clipUri != null && dataUri != clipUri) return null
        val uri = dataUri ?: clipUri ?: return null
        uri.takeIf { it.scheme == "content" && !it.authority.isNullOrBlank() && it.userInfo == null }
    } catch (_: RuntimeException) {
        // File apps are outside this process; malformed parcelables must not crash the reader.
        null
    }
}

internal data class PickerApp(val component: ComponentName, val label: String)

@Suppress("DEPRECATION")
internal fun compatiblePickerApps(context: Context): List<PickerApp> =
    // A */* discovery query also matches image/video-only pickers. Require at least
    // one archive/binary type while still allowing broad file managers.
    archivePickerMimeTypes.flatMap { mime ->
        context.packageManager.queryIntentActivities(
            archiveFileAppIntent(true).setType(mime), PackageManager.MATCH_DEFAULT_ONLY)
    }
        .filter { it.activityInfo.exported && it.activityInfo.packageName != context.packageName }
        .map { PickerApp(ComponentName(it.activityInfo.packageName, it.activityInfo.name), it.loadLabel(context.packageManager).toString()) }
        .distinctBy { it.component }
        .sortedBy { it.label.lowercase() }

@Stable
internal class ArchivePickerController(
    val open: () -> Unit,
    val chooseOnce: () -> Unit,
    val configure: () -> Unit,
    val dismiss: () -> Unit,
    val description: String,
)

/** Keeps URI grants transient: the importer makes its own private copy before reading. */
@Composable
internal fun rememberArchivePicker(onArchive: (Uri) -> Unit): ArchivePickerController {
    val context = LocalContext.current
    val onArchiveNow by rememberUpdatedState(onArchive)
    val preferences = remember(context) { context.getSharedPreferences("archive_picker", Context.MODE_PRIVATE) }
    var selection by remember { mutableStateOf(preferences.getString("selection", "system") ?: "system") }
    var selectedLabel by remember { mutableStateOf(preferences.getString("label", null)) }
    var showAllFiles by remember { mutableStateOf(preferences.getBoolean("show_all_files", true)) }
    var dialog by rememberSaveable { mutableStateOf<String?>(null) }
    var rememberChoice by rememberSaveable { mutableStateOf(false) }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    var apps by remember { mutableStateOf<List<PickerApp>?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val uri = archivePickerResultUri(result.data)
            if (uri != null) onArchiveNow(uri)
            else error = "This file app did not return a readable file. Try System files, another file app, or share the archive from your file manager."
        }
    }
    fun save(choice: String, label: String?) {
        selection = choice
        selectedLabel = label
        preferences.edit().putString("selection", choice).putString("label", label).apply()
    }
    fun launch(choice: String) {
        try {
            if (choice == "system") picker.launch(archiveSystemPickerIntent(showAllFiles))
            else {
                val component = ComponentName.unflattenFromString(choice)
                    ?: throw IllegalArgumentException("Missing file app")
                picker.launch(archiveFileAppIntent(showAllFiles, component))
            }
        } catch (_: android.content.ActivityNotFoundException) {
            error = "That file picker is no longer available. Choose System files or another app."
        } catch (_: SecurityException) {
            error = "That file app could not be opened. Choose System files or another app."
        } catch (_: IllegalArgumentException) {
            error = "That saved file picker is unavailable. Choose another picker."
        }
    }
    LaunchedEffect(dialog) {
        if (dialog != null) {
            apps = null
            apps = withContext(Dispatchers.IO) { compatiblePickerApps(context) }
        }
    }
    if (dialog != null) {
        val configuring = dialog == "settings"
        fun select(choice: String, label: String?) {
            if (configuring || rememberChoice) save(choice, label)
            dialog = null
            if (!configuring) launch(choice)
        }
        AlertDialog(onDismissRequest = { dialog = null }, title = { Text(if (configuring) "Default file picker" else "Open archive using") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Network shares appear when your file app or document provider supports them.", style = MaterialTheme.typography.bodySmall)
                    OutlinedButton(onClick = { select("system", null) }, modifier = Modifier.fillMaxWidth().testTag("picker_system")) { Text("System files") }
                    if (configuring) OutlinedButton(onClick = { save("ask", null); dialog = null }, modifier = Modifier.fillMaxWidth().testTag("picker_ask")) {
                        Text("Choose a file app each time")
                    }
                    Text("Installed file apps", style = MaterialTheme.typography.titleSmall)
                    val installed = apps
                    if (installed == null) LinearProgressIndicator(Modifier.fillMaxWidth())
                    else if (installed.isEmpty()) Text("No compatible file apps found. Install a file manager that supports choosing files, or use System files.", style = MaterialTheme.typography.bodySmall)
                    else installed.forEach { app ->
                        OutlinedButton(onClick = { select(app.component.flattenToString(), app.label) }, modifier = Modifier.fillMaxWidth()) { Text(app.label) }
                    }
                    HorizontalDivider()
                    Row {
                        Checkbox(checked = showAllFiles, onCheckedChange = {
                            showAllFiles = it
                            preferences.edit().putBoolean("show_all_files", it).apply()
                        }, modifier = Modifier.testTag("picker_show_all"))
                        Column(Modifier.weight(1f).padding(top = 12.dp)) {
                            Text("Show all files")
                            Text("Keep this on if a provider hides ZIP, CBZ or 7z archives. Only supported archives can be opened.", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    if (!configuring) Row {
                        Checkbox(checked = rememberChoice, onCheckedChange = { rememberChoice = it }, modifier = Modifier.testTag("picker_remember"))
                        Text("Remember this picker", modifier = Modifier.padding(top = 12.dp))
                    }
                }
            }, confirmButton = { TextButton(onClick = { dialog = null }) { Text("Cancel") } })
    }
    error?.let { message ->
        AlertDialog(onDismissRequest = { error = null }, title = { Text("Choose another file picker") }, text = { Text(message) },
            confirmButton = { TextButton(onClick = { error = null; rememberChoice = false; dialog = "open" }) { Text("Choose picker") } },
            dismissButton = { TextButton(onClick = { error = null }) { Text("Cancel") } })
    }
    return ArchivePickerController(
        open = { if (selection == "ask") { rememberChoice = false; dialog = "open" } else launch(selection) },
        chooseOnce = { rememberChoice = false; dialog = "open" },
        configure = { dialog = "settings" },
        dismiss = { dialog = null; error = null },
        description = when (selection) { "system" -> "System files"; "ask" -> "Choose a file app each time"; else -> selectedLabel ?: "Preferred file app" },
    )
}
