package com.brite.zipimageviewer

import android.app.Activity
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.Image
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.brite.zipimageviewer.data.ArchiveRecord
import com.brite.zipimageviewer.reader.ReaderPage
import com.brite.zipimageviewer.reader.ReaderScreen
import com.brite.zipimageviewer.reader.ReaderPreferenceControls
import com.brite.zipimageviewer.data.CacheLimits
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.Locale

@Composable
fun ZipImageViewerApp(model: AppCoordinator) {
    val archives by model.archives.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var settings by rememberSaveable { mutableStateOf(false) }
    val reader = model.currentArchive
    val picker = rememberArchivePicker(model::import)
    LaunchedEffect(reader) {
        if (reader != null) {
            settings = false
            picker.dismiss()
        }
    }
    DisposableEffect(reader != null) {
        val window = (context as? Activity)?.window
        val controller = window?.let { WindowCompat.getInsetsController(it, it.decorView) }
        if (reader != null) {
            controller?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller?.hide(WindowInsetsCompat.Type.systemBars())
        } else controller?.show(WindowInsetsCompat.Type.systemBars())
        onDispose { controller?.show(WindowInsetsCompat.Type.systemBars()) }
    }
    Surface(Modifier.fillMaxSize()) {
        if (reader != null) {
            var temporaryAcknowledged by rememberSaveable(reader.id) { mutableStateOf(false) }
            val pages = remember(reader.id, reader.storageDirectory) { reader.pages.map { ReaderPage(it.originalPath, model.repository.pageFile(reader, it), it.modifiedAt, it.createdAt, model.repository.previewFile(reader, it)) } }
            ReaderScreen(title = reader.title + if (reader.isTemporary) " · Temporary" else "", pages = pages, initialPagePath = model.readerPagePath,
                preferences = model.preferences, onPreferencesChange = model::updatePreferences,
                onPageChange = model::progress, onClose = model::closeReader,
                onOpenAppSettings = { settings = true },
                retainImageWork = { model.repository.retainImageWork(reader.id) })
            if (reader.isTemporary && !temporaryAcknowledged) AlertDialog(onDismissRequest = { temporaryAcknowledged = true },
                title = { Text("Reading a temporary copy") },
                text = { Text("This archive is larger than your retained cache limit. You can read it now; its extracted pages will be removed when you close the reader. Your original archive stays unchanged.") },
                confirmButton = { TextButton(onClick = { temporaryAcknowledged = true }) { Text("Continue reading") } })
        } else LibraryContent(model, archives, picker.open, picker.chooseOnce, { settings = true })
    }
    if (settings) AppSettings(model, archives, picker, onDismiss = { settings = false })
    if (model.busy) AlertDialog(
        onDismissRequest = {}, icon = { Icon(Icons.Outlined.FolderZip, null) },
        title = { Text("Opening archive") },
        text = { Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(model.status)
            val progress = model.fraction
            if (progress != null) LinearProgressIndicator(progress = { progress.coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
            else LinearProgressIndicator(Modifier.fillMaxWidth())
            Text("Your original archive stays unchanged.", style = MaterialTheme.typography.bodySmall)
        } }, confirmButton = {}, dismissButton = { TextButton(onClick = model::cancelImport) { Text("Cancel") } }
    )
    model.passwordPrompt?.let { message ->
        var password by remember { mutableStateOf("") }
        AlertDialog(onDismissRequest = model::dismissPassword,
            icon = { Icon(Icons.Outlined.Lock, null) }, title = { Text("Archive password") },
            text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(message)
                OutlinedTextField(password, { password = it }, label = { Text("Password") },
                    visualTransformation = PasswordVisualTransformation(), singleLine = true,
                    modifier = Modifier.testTag("archive_password"))
                Text("Passwords are never saved. Spaces are preserved.", style = MaterialTheme.typography.bodySmall)
            } }, confirmButton = { TextButton(onClick = { model.submitPassword(password) }) { Text("Unlock") } },
            dismissButton = { TextButton(onClick = model::dismissPassword) { Text("Cancel") } })
    }
    model.error?.let { message -> AlertDialog(onDismissRequest = model::dismissError,
        title = { Text("Couldn’t open archive") }, text = { Text(message) },
        confirmButton = { TextButton(onClick = model::dismissError) { Text("OK") } }) }
}

@Composable
private fun LibraryContent(model: AppCoordinator, archives: List<ArchiveRecord>, onOpen: () -> Unit, onChoosePicker: () -> Unit, onSettings: () -> Unit) {
    var removing by remember { mutableStateOf<ArchiveRecord?>(null) }
    var details by remember { mutableStateOf<ArchiveRecord?>(null) }
    val shown = archives.filter { it.title.contains(model.query, ignoreCase = true) }
    BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding().testTag("library")) {
        val wide = maxWidth >= 720.dp
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).testTag("library_toolbar"),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("ZipImageViewer", modifier = Modifier.weight(1f).padding(start = 4.dp),
                    style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (wide && archives.isNotEmpty()) LibrarySearch(model, Modifier.width(300.dp))
                if (wide) OpenArchiveButton(onOpen, Modifier.widthIn(min = 184.dp))
                IconButton(onClick = onChoosePicker, modifier = Modifier.testTag("choose_archive_picker")) {
                    Icon(Icons.Outlined.MoreHoriz, "Open archive using another picker")
                }
                IconButton(onClick = onSettings, modifier = Modifier.testTag("app_settings")) {
                    Icon(Icons.Outlined.Settings, "Settings")
                }
            }
            if (!wide) OpenArchiveButton(onOpen,
                Modifier.fillMaxWidth().padding(horizontal = 12.dp).padding(bottom = 8.dp))
            if (!wide && archives.isNotEmpty()) LibrarySearch(model,
                Modifier.fillMaxWidth().padding(horizontal = 12.dp).padding(bottom = 8.dp))
            if (archives.isEmpty()) {
                Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No archives yet", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(8.dp))
                    Text("Open a ZIP, CBZ or 7z archive to start reading.", style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    Spacer(Modifier.height(12.dp))
                    OpenArchiveButton(onOpen, tag = "open_empty_archive")
                }
            } else if (shown.isEmpty()) Box(Modifier.weight(1f).fillMaxWidth().padding(16.dp), contentAlignment = Alignment.TopCenter) {
                Text("No matching archives", color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else LazyVerticalGrid(columns = GridCells.Adaptive(320.dp), contentPadding = PaddingValues(12.dp, 4.dp, 12.dp, 12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.weight(1f).testTag("archive_grid")) {
                items(shown, key = { it.id }) { archive ->
                    ArchiveCard(archive, model, { model.open(archive) }, { removing = archive }, { details = archive })
                }
            }
        }
    }
    removing?.let { a -> AlertDialog(onDismissRequest = { removing = null }, title = { Text("Remove cached archive?") },
        text = { Text("Remove “${a.title}” and its reading position from this app? Your original archive will stay unchanged.") },
        confirmButton = { TextButton(onClick = { model.remove(a); removing = null }) { Text("Remove") } },
        dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel") } }) }
    details?.let { a -> AlertDialog(onDismissRequest = { details = null }, title = { Text(a.title) },
        text = { Text("${a.format.uppercase()} archive\n${a.pages.size} pages\n${formatBytes(a.bytes)} cached\nLast opened ${DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(a.lastOpened))}\n\n${if (a.available) "Available offline" else "Cached files unavailable. Select the original archive again."}") },
        confirmButton = { TextButton(onClick = { details = null }) { Text("Done") } }) }
}

@Composable
private fun OpenArchiveButton(onOpen: () -> Unit, modifier: Modifier = Modifier, tag: String = "open_archive") {
    Button(onClick = onOpen, modifier = modifier.heightIn(min = 56.dp).testTag(tag),
        shape = RoundedCornerShape(12.dp), contentPadding = PaddingValues(horizontal = 24.dp, vertical = 12.dp)) {
        Icon(Icons.Outlined.FolderOpen, null)
        Spacer(Modifier.width(10.dp))
        Text("Open archive", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun LibrarySearch(model: AppCoordinator, modifier: Modifier) {
    OutlinedTextField(value = model.query, onValueChange = { model.query = it }, modifier = modifier.testTag("archive_search"),
        placeholder = { Text("Search archives") }, leadingIcon = { Icon(Icons.Outlined.Search, null) },
        singleLine = true, shape = RoundedCornerShape(12.dp))
}

@Composable
private fun ArchiveCard(archive: ArchiveRecord, model: AppCoordinator, onOpen: () -> Unit, onRemove: () -> Unit, onDetails: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val page = archive.pages.indexOfFirst { it.originalPath == archive.currentPagePath }.coerceAtLeast(0) + 1
    Card(onClick = onOpen, shape = RoundedCornerShape(12.dp), modifier = Modifier.fillMaxWidth().testTag("archive_${archive.id}"),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
        Row(Modifier.padding(start = 10.dp, top = 10.dp, bottom = 10.dp, end = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            val file = archive.pages.firstOrNull()?.let { model.repository.previewFile(archive, it) ?: model.repository.pageFile(archive, it) }
            Cover(file, Modifier.width(48.dp).height(68.dp).clip(RoundedCornerShape(8.dp)),
                retainImageWork = { model.repository.retainImageWork(archive.id) })
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(archive.title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(if (archive.available) "Page $page of ${archive.pages.size}" else "Select source again", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                LinearProgressIndicator(progress = { page.toFloat() / archive.pages.size.coerceAtLeast(1) }, modifier = Modifier.fillMaxWidth().height(3.dp))
            }
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, "Archive actions for ${archive.title}") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Details") }, onClick = { menu = false; onDetails() })
                    DropdownMenuItem(text = { Text("Remove cached archive") }, onClick = { menu = false; onRemove() })
                }
            }
        }
    }
}

@Composable
private fun Cover(file: File?, modifier: Modifier, retainImageWork: () -> (() -> Unit)) {
    val image by produceState<android.graphics.Bitmap?>(null, file?.absolutePath) {
        if (file != null) {
            val release = runCatching { retainImageWork() }.getOrNull()
            if (release != null) try {
                value = com.brite.zipimageviewer.reader.ReaderBitmapDecoder.decode(file, 384, thumbnail = true)
            } finally { release() }
        }
    }
    Box(modifier.background(MaterialTheme.colorScheme.surfaceContainerHigh), contentAlignment = Alignment.Center) {
        image?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
            ?: Icon(Icons.Outlined.Image, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun AppSettings(model: AppCoordinator, archives: List<ArchiveRecord>, picker: ArchivePickerController, onDismiss: () -> Unit) {
    val storageWarning by model.repository.storageWarning.collectAsStateWithLifecycle()
    val pendingDeletionBytes by model.repository.pendingDeletionBytes.collectAsStateWithLifecycle()
    var clearConfirm by remember { mutableStateOf(false) }
    var byteMenu by remember { mutableStateOf(false) }
    var countMenu by remember { mutableStateOf(false) }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.widthIn(max = 680.dp).fillMaxWidth().fillMaxHeight(0.95f).safeDrawingPadding(),
            shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surface) {
            Column {
                Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 8.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Settings", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                    TextButton(onClick = onDismiss, modifier = Modifier.testTag("app_settings_done")) { Text("Done") }
                }
                HorizontalDivider()
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp).testTag("app_settings_list"),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Opening archives", style = MaterialTheme.typography.titleMedium)
                    OutlinedButton(onClick = picker.configure, modifier = Modifier.fillMaxWidth().testTag("default_file_picker")) {
                        Text("File picker: ${picker.description}", modifier = Modifier.weight(1f))
                        Icon(Icons.Outlined.ExpandMore, null)
                    }
                    Text("Choose a file app with network support, or add a network document provider to System files. You can also share an archive or use Open with in another app.", style = MaterialTheme.typography.bodySmall)
                    HorizontalDivider()
                    Text("Reading", style = MaterialTheme.typography.titleMedium)
                    ReaderPreferenceControls(model.preferences, model::updatePreferences)
                    HorizontalDivider()
                    Text("Storage", style = MaterialTheme.typography.titleMedium)
                    Text("${formatBytes(archives.sumOf { it.bytes })} cached · ${archives.size} archives", style = MaterialTheme.typography.bodyMedium)
                    if (pendingDeletionBytes > 0) Text("${formatBytes(pendingDeletionBytes)} awaiting cleanup.", style = MaterialTheme.typography.bodySmall)
                    storageWarning?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                    Box {
                        OutlinedButton(onClick = { byteMenu = true }, enabled = !model.cacheSettingsBusy,
                            modifier = Modifier.fillMaxWidth().testTag("storage_limit")) {
                            Text("Storage limit: ${formatBytes(model.cacheBudget)}", modifier = Modifier.weight(1f))
                            Icon(Icons.Outlined.ExpandMore, null)
                        }
                        DropdownMenu(expanded = byteMenu, onDismissRequest = { byteMenu = false }) {
                            listOf(500_000_000L, 1_000_000_000L, 2_000_000_000L, 5_000_000_000L, 10_000_000_000L).forEach { bytes ->
                                DropdownMenuItem(text = { Text(formatBytes(bytes)) }, onClick = {
                                    byteMenu = false; model.previewCacheLimits(CacheLimits(bytes, model.archiveCountLimit))
                                })
                            }
                        }
                    }
                    Box {
                        OutlinedButton(onClick = { countMenu = true }, enabled = !model.cacheSettingsBusy,
                            modifier = Modifier.fillMaxWidth().testTag("archive_limit")) {
                            Text("Archive limit: ${model.archiveCountLimit?.toString() ?: "No limit"}", modifier = Modifier.weight(1f))
                            Icon(Icons.Outlined.ExpandMore, null)
                        }
                        DropdownMenu(expanded = countMenu, onDismissRequest = { countMenu = false }) {
                            listOf(null, 5, 10, 20, 50).forEach { count ->
                                DropdownMenuItem(text = { Text(count?.toString() ?: "No limit") }, onClick = {
                                    countMenu = false; model.previewCacheLimits(CacheLimits(model.cacheBudget, count))
                                })
                            }
                        }
                    }
                    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp)
                        .toggleable(value = model.compressImages, role = Role.Switch, onValueChange = model::setImageCompression)
                        .semantics { contentDescription = "Compress extracted images" }.testTag("compress_images"),
                        verticalAlignment = Alignment.CenterVertically) {
                        Text("Compress extracted images", modifier = Modifier.weight(1f).padding(end = 12.dp))
                        Switch(checked = model.compressImages, onCheckedChange = null)
                    }
                    Text("Saves space in newly extracted caches using JPEG XL. JPEG images are repacked losslessly; PNG conversion may slightly reduce quality. Existing cached images stay unchanged. Extraction may temporarily use extra storage.", style = MaterialTheme.typography.bodySmall)
                    if (model.cacheSettingsBusy) LinearProgressIndicator(Modifier.fillMaxWidth())
                    Text("Limits apply to cached copies. Open archives are protected until you close them. Original files stay unchanged.", style = MaterialTheme.typography.bodySmall)
                    Text("Encrypted archives are cached decrypted and reopen without a password. Passwords are never saved.", style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = { clearConfirm = true }, enabled = archives.isNotEmpty() && !model.cacheSettingsBusy) { Text("Remove all cached archives") }
                    HorizontalDivider()
                    Text("ZipImageViewer · ${BuildConfig.VERSION_NAME}", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
    model.cachePreview?.let { preview ->
        AlertDialog(onDismissRequest = model::dismissCachePreview, title = { Text("Change cache limits?") }, text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (model.cachePreviewChanged) Text("The library changed. Review this updated list before applying.")
                Text("Storage: ${formatBytes(preview.limits.maximumBytes)}\nArchives: ${preview.limits.maximumArchiveCount?.toString() ?: "No limit"}")
                if (preview.candidates.isEmpty()) Text("No cached archives will be removed now.") else {
                    Text("Remove ${preview.candidates.size} cached ${if (preview.candidates.size == 1) "archive" else "archives"} (${formatBytes(preview.reclaimedBytes)}) while keeping their reading positions:")
                    preview.candidates.forEach { Text(it.title, style = MaterialTheme.typography.bodyMedium) }
                }
                Text("Open archives stay available. If they keep the library above the new limits, older copies may be removed after closing. Original files are never deleted.", style = MaterialTheme.typography.bodySmall)
            }
        }, confirmButton = { TextButton(onClick = model::applyCachePreview, enabled = !model.cacheSettingsBusy, modifier = Modifier.testTag("apply_cache_limits")) { Text("Apply") } },
            dismissButton = { TextButton(onClick = model::dismissCachePreview, enabled = !model.cacheSettingsBusy) { Text("Cancel") } })
    }
    if (clearConfirm) AlertDialog(onDismissRequest = { clearConfirm = false }, title = { Text("Remove all cached archives?") },
        text = { Text("This removes all cached copies and saved reading positions. Your source archives stay unchanged.") },
        confirmButton = { TextButton(onClick = { model.clear(); clearConfirm = false }) { Text("Remove all") } },
        dismissButton = { TextButton(onClick = { clearConfirm = false }) { Text("Cancel") } })
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1_000_000_000 -> String.format(Locale.getDefault(), "%.1f GB", bytes / 1_000_000_000.0)
    bytes >= 1_000_000 -> String.format(Locale.getDefault(), "%.1f MB", bytes / 1_000_000.0)
    else -> "${bytes / 1000} KB"
}
