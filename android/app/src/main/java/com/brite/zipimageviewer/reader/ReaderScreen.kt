package com.brite.zipimageviewer.reader

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.RotateLeft
import androidx.compose.material.icons.outlined.RotateRight
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReaderScreen(
    title: String,
    pages: List<ReaderPage>,
    initialPagePath: String?,
    preferences: ReaderPreferences,
    onPreferencesChange: (ReaderPreferences) -> Unit,
    onPageChange: (String) -> Unit,
    onClose: () -> Unit,
    onOpenAppSettings: (() -> Unit)? = null,
    retainImageWork: (() -> (() -> Unit))? = null,
    shared: SharedReaderAdapter? = null,
) {
    val prefs = preferences.validated()
    val currentRetain by rememberUpdatedState(retainImageWork)
    val pipeline = remember(title) { ReaderImagePipeline(retainImageWork = { currentRetain?.invoke() ?: {} }) }
    val context = LocalContext.current
    val windowSize = LocalWindowInfo.current.containerSize
    val target = maxOf(windowSize.width, windowSize.height).coerceAtLeast(384)
    DisposableEffect(pipeline, context) {
        val unregister = pipeline.registerMemoryCallbacks(context)
        onDispose { unregister(); pipeline.close() }
    }
    fun closeReader() { pipeline.close(); onClose() }
    val ordered = remember(pages, prefs.sortCriterion, prefs.descending) { sortedReaderPages(pages, prefs) }
    var selectedPath by rememberSaveable(title) { mutableStateOf(initialPagePath) }
    val index = ordered.indexOfFirst { it.relativePath == selectedPath }.coerceAtLeast(0)
    val page = ordered.getOrNull(index)
    var imageQuarterTurns by rememberSaveable(title) { mutableIntStateOf(shared?.initialQuarterTurns ?: 0) }
    var rotationPagePath by rememberSaveable(title) { mutableStateOf(shared?.rotationPagePath ?: page?.relativePath) }
    if (rotationPagePath != page?.relativePath) {
        rotationPagePath = page?.relativePath
        imageQuarterTurns = 0
    }
    var controls by rememberSaveable(title) { mutableStateOf(shared?.initialControls ?: true) }
    var overview by remember { mutableStateOf(false) }
    var settings by remember { mutableStateOf(false) }
    var jump by remember { mutableStateOf(false) }
    var scrub by remember { mutableStateOf<Float?>(null) }
    val reportPage by rememberUpdatedState(onPageChange)
    var navigationStep by remember { mutableStateOf(0) }
    var lastReported by remember(title) { mutableStateOf<String?>(null) }
    fun select(path: String, physicalStep: Int = 0) {
        // Reset at selection, even if rapid scrub-away/back commands are coalesced
        // before Compose can render the intermediate page.
        if (rotationPagePath != path) { rotationPagePath = path; imageQuarterTurns = 0 }
        navigationStep = physicalStep
        selectedPath = path
        if (lastReported != path) { lastReported = path; reportPage(path) }
    }
    LaunchedEffect(page?.relativePath) { page?.let { if (lastReported != it.relativePath) select(it.relativePath) } }
    fun navigate(next: Int, animate: Boolean = false) {
        if (next in ordered.indices) {
            val step = if (!animate || next == index) 0 else (if (next > index) 1 else -1) * (if (prefs.reversed) -1 else 1)
            val wasScrubbing = scrub != null
            select(ordered[next].relativePath, step); scrub = null
            // An away/back scrub can finish within one frame, leaving every effect
            // key unchanged. Settle its decode here rather than waiting for an effect.
            if (wasScrubbing) pipeline.select(ordered[next], target,
                listOfNotNull(ordered.getOrNull(next + 1), ordered.getOrNull(next - 1)))
        }
    }
    fun escape() { if (!controls) controls = true else closeReader() }
    if (shared == null) BackHandler { escape() }
    var imageSurface by remember { mutableStateOf<ReaderImageSurface?>(null) }
    fun rotate(step: Int) {
        if (prefs.showRotationButtons && scrub == null && pipeline.frame?.page?.relativePath == page?.relativePath) {
            imageQuarterTurns = (imageQuarterTurns + step + 4) % 4
            imageSurface?.setQuarterTurns(imageQuarterTurns)
        }
    }
    DisposableEffect(shared) { onDispose { shared?.action = null } }
    // Observe the turn in composition; reads inside SideEffect alone do not
    // schedule a new session snapshot when only the angle changes.
    val reportedQuarterTurns = imageQuarterTurns
    SideEffect {
        shared?.onState(ReaderSurfaceState(index + 1, ordered.size,
            ordered.indexOfFirst { it.relativePath == pipeline.frame?.page?.relativePath }.takeIf { it >= 0 }?.plus(1),
            controls, pipeline.failed, pipeline.detailFailed, reportedQuarterTurns, page?.relativePath))
        shared?.action = { action, requestedPage, scrubbing ->
            when (action) {
                "seek" -> requestedPage?.let { number ->
                    if (scrubbing) {
                        scrub = (number - 1).toFloat()
                        ordered.getOrNull(number - 1)?.let { select(it.relativePath); pipeline.scrub(it, number - 1, maxOf(windowSize.width, windowSize.height).coerceAtLeast(384)) }
                    } else navigate(number - 1)
                }
                "toggleControls" -> controls = !controls
                "showControls" -> controls = true
                "retry" -> pipeline.retry()
                "retryDetail" -> pipeline.requestDetail()
                "rotateCounterclockwise" -> rotate(-1)
                "rotateClockwise" -> rotate(1)
            }
        }
    }
    LaunchedEffect(page?.relativePath, target, prefs.reversed, prefs.sortCriterion, prefs.descending, scrub == null) {
        page?.let {
            if (scrub == null) pipeline.select(it, target, listOfNotNull(ordered.getOrNull(index + 1), ordered.getOrNull(index - 1)))
            else pipeline.scrub(it, index, target)
        }
    }
    val frame = pipeline.frame
    val displayedIndex = ordered.indexOfFirst { it.relativePath == frame?.page?.relativePath }
    Box(Modifier.fillMaxSize().background(Color.Black).testTag("reader")) {
        if (page == null) {
            Text("No readable pages", color = Color.White, modifier = Modifier.align(Alignment.Center))
        } else {
            AndroidView(
                factory = { ReaderImageSurface(it).also { surface -> imageSurface = surface } }, onReset = null, onRelease = { it.release() },
                update = { view ->
                    view.preferences = prefs
                    view.onStep = { delta ->
                        // Immediate taps can arrive before Compose renders the preceding selection.
                        val currentIndex = ordered.indexOfFirst { it.relativePath == selectedPath }.coerceAtLeast(0)
                        navigate(currentIndex + delta, animate = true)
                    }
                    view.navigationStep = navigationStep
                    view.onToggle = { controls = !controls }
                    view.onZoomChanged = { zoom -> if (zoom > 1.01f) pipeline.requestDetail() }
                    view.contentDescription = "Page ${index + 1} of ${ordered.size}. Showing ${if (displayedIndex >= 0) displayedIndex + 1 else "loading"}. Double tap to zoom; long press for controls."
                    view.resetGeometry(pipeline.geometryEpoch)
                    view.show(frame?.page?.relativePath, frame?.bitmap)
                    if (frame?.page?.relativePath == page.relativePath) view.setQuarterTurns(imageQuarterTurns)
                },
                modifier = Modifier.fillMaxSize().testTag("reader_page"),
            )
            if (frame == null && !pipeline.failed) CircularProgressIndicator(Modifier.align(Alignment.Center).size(32.dp), color = Color.White)
            if (pipeline.failed && shared == null) Column(Modifier.align(Alignment.Center).padding(32.dp).background(Color.Black.copy(alpha = 0.8f)), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("This page cannot be displayed", color = Color.White, style = MaterialTheme.typography.titleMedium)
                Text("You can still move to another page.", color = Color.Gray, modifier = Modifier.padding(top = 12.dp))
                TextButton(onClick = { pipeline.retry() }, modifier = Modifier.testTag("reader_retry")) { Text("Retry", color = Color.White) }
            }
        }
        if (controls && shared == null) {
            val topInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Top)
            FloatingReaderAction(Icons.AutoMirrored.Filled.ArrowBack, "Back to library", "reader_close", { closeReader() },
                Modifier.align(Alignment.TopStart).windowInsetsPadding(topInsets).padding(8.dp))
            Row(Modifier.align(Alignment.TopEnd).windowInsetsPadding(topInsets).padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (prefs.showRotationButtons) {
                    FloatingReaderAction(Icons.Outlined.RotateLeft, "Rotate image counterclockwise 90 degrees", "reader_rotate_counterclockwise", { rotate(-1) })
                    FloatingReaderAction(Icons.Outlined.RotateRight, "Rotate image clockwise 90 degrees", "reader_rotate_clockwise", { rotate(1) })
                }
                FloatingReaderAction(Icons.Outlined.Settings, "Reader settings", "reader_settings", { settings = true })
                FloatingReaderAction(Icons.Outlined.VisibilityOff, "Hide controls", "reader_hide", { controls = false })
            }
            Column(Modifier.align(Alignment.BottomCenter)
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom))
                .padding(8.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if ((scrub != null || displayedIndex >= 0 && displayedIndex != index) && ordered.isNotEmpty()) {
                    Row(Modifier.background(Color.Black.copy(alpha = 0.72f), MaterialTheme.shapes.large).padding(8.dp).testTag("reader_preview_identity"), verticalAlignment = Alignment.CenterVertically) {
                        frame?.let { Image(it.bitmap.asImageBitmap(), contentDescription = null, modifier = Modifier.size(48.dp), contentScale = ContentScale.Fit) }
                        Text("Preview: ${if (displayedIndex >= 0) displayedIndex + 1 else "loading"} · Target: ${index + 1}", color = Color.White, modifier = Modifier.padding(horizontal = 12.dp))
                    }
                }
                if (pipeline.detailFailed) TextButton(onClick = { pipeline.requestDetail() }, modifier = Modifier.testTag("reader_detail_retry").background(Color.Black.copy(alpha = 0.75f), CircleShape)) {
                    Text("Retry zoom detail", color = Color.White)
                }
                val bottomWidth = if (prefs.showSlider) Modifier.widthIn(max = 600.dp).fillMaxWidth() else Modifier.wrapContentWidth()
                Row(bottomWidth.testTag("reader_bottom_controls"), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (prefs.showCount) {
                        TextButton(onClick = { jump = true }, enabled = ordered.isNotEmpty(),
                            modifier = Modifier.height(48.dp).widthIn(min = 48.dp, max = 160.dp)
                                .background(Color.Black.copy(alpha = 0.68f), CircleShape).testTag("page_jump")
                                .semantics { contentDescription = "Go to page. Current page ${if (ordered.isEmpty()) 0 else index + 1} of ${ordered.size}" },
                            contentPadding = PaddingValues(horizontal = 12.dp)) {
                            Text("${if (ordered.isEmpty()) 0 else index + 1} / ${ordered.size}", color = Color.White,
                                style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    } else {
                        FloatingReaderAction(Icons.Outlined.Tag, "Go to page", "page_jump", { jump = true }, enabled = ordered.isNotEmpty())
                    }
                    if (prefs.showSlider) {
                        val sliderColors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Color.White, inactiveTrackColor = Color.DarkGray)
                        Slider(value = scrub ?: index.toFloat(), onValueChange = { value ->
                            scrub = value
                            ordered.getOrNull(value.roundToInt())?.let { select(it.relativePath); pipeline.scrub(it, value.roundToInt(), target) }
                        },
                            onValueChangeFinished = { scrub?.let { navigate(it.roundToInt()) } },
                            enabled = ordered.size > 1, valueRange = 0f..ordered.lastIndex.coerceAtLeast(1).toFloat(),
                            colors = sliderColors,
                            thumb = { Box(Modifier.size(16.dp).background(if (ordered.size > 1) Color.White else Color.Gray, CircleShape)) },
                            track = { state -> SliderDefaults.Track(sliderState = state, modifier = Modifier.height(4.dp),
                                enabled = ordered.size > 1, colors = sliderColors, drawStopIndicator = null, thumbTrackGapSize = 0.dp) },
                            modifier = Modifier.weight(1f).height(48.dp).background(Color.Black.copy(alpha = 0.68f), CircleShape)
                                .padding(horizontal = 12.dp).testTag("page_slider").semantics { contentDescription = "Page position" })
                    }
                    FloatingReaderAction(Icons.Outlined.GridView, "All pages", "page_overview", { overview = true }, enabled = ordered.isNotEmpty())
                }
            }
        }
    }
    if (jump) PageJumpDialog(index + 1, ordered.size, onDismiss = { jump = false }, onJump = { navigate(it - 1); jump = false })
    if (overview) PageOverview(ordered, page?.relativePath, prefs.thumbnailSize, onDismiss = { overview = false }, onSelect = { select(it); overview = false }, retainImageWork = retainImageWork)
    if (settings) ReaderSettingsDialog(prefs, onPreferencesChange, onDismiss = { settings = false }, onOpenAppSettings = onOpenAppSettings?.let { action -> { settings = false; action() } })
}

/** Only the 48 dp action surface handles touches; surrounding layout remains transparent. */
@Composable
private fun FloatingReaderAction(icon: ImageVector, label: String, tag: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    Box(modifier) {
        IconButton(onClick = onClick, enabled = enabled,
            modifier = Modifier.size(48.dp).background(Color.Black.copy(alpha = 0.68f), CircleShape).testTag(tag)) {
            Icon(icon, contentDescription = label, tint = if (enabled) Color.White else Color.Gray, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun PageThumbnail(page: ReaderPage, modifier: Modifier, retainImageWork: (() -> (() -> Unit))? = null) {
    key(page.relativePath) {
        val state by rememberReaderBitmap(page, 384, thumbnail = true, retainImageWork = retainImageWork)
        Box(modifier.background(Color(0xFF202127)), contentAlignment = Alignment.Center) {
            val image = state as? BitmapState.Ready
            if (image != null) Image(image.bitmap.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
            else Text(if (state == BitmapState.Loading) "…" else "Unavailable", color = Color.LightGray, style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
private fun PageOverview(pages: List<ReaderPage>, selected: String?, thumbnailSize: Float, onDismiss: () -> Unit, onSelect: (String) -> Unit, retainImageWork: (() -> (() -> Unit))?) {
    val gridState = rememberLazyGridState(initialFirstVisibleItemIndex = pages.indexOfFirst { it.relativePath == selected }.coerceAtLeast(0))
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize().systemBarsPadding(), color = MaterialTheme.colorScheme.surface) {
            Column(Modifier.fillMaxSize().padding(16.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("All pages", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
                    TextButton(onClick = onDismiss) { Text("Done") }
                }
                Text("${pages.size} pages · Tap a page to continue", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(bottom = 16.dp))
                LazyVerticalGrid(state = gridState, columns = GridCells.Adaptive((80 + thumbnailSize * 150).dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.testTag("thumbnail_grid")) {
                    itemsIndexed(pages, key = { _, page -> page.relativePath }) { index, page ->
                        Column(Modifier.clickable { onSelect(page.relativePath) }.semantics { contentDescription = "Open page ${index + 1}: ${page.relativePath}" }.testTag("thumbnail_$index")) {
                            PageThumbnail(page, Modifier.fillMaxWidth().aspectRatio(0.7f), retainImageWork)
                            Text("Page ${index + 1}", style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, color = if (page.relativePath == selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface, modifier = Modifier.padding(top = 6.dp))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PageJumpDialog(current: Int, count: Int, onDismiss: () -> Unit, onJump: (Int) -> Unit) {
    var value by remember { mutableStateOf(current.toString()) }
    val number = value.toIntOrNull()
    val valid = number != null && number in 1..count
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Go to page") }, text = {
        OutlinedTextField(value, onValueChange = { value = it }, label = { Text("Page (1–$count)") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), isError = !valid,
            supportingText = { if (!valid) Text("Enter a whole number from 1 to $count.") }, modifier = Modifier.testTag("page_number_input"))
    }, confirmButton = { TextButton(onClick = { number?.let(onJump) }, enabled = valid, modifier = Modifier.testTag("confirm_page_jump")) { Text("Go") } }, dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } })
}

@Composable
private fun ReaderSettingsDialog(prefs: ReaderPreferences, onChange: (ReaderPreferences) -> Unit, onDismiss: () -> Unit, onOpenAppSettings: (() -> Unit)?) {
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Reader settings") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()).testTag("reader_settings_list")) {
            if (onOpenAppSettings != null) TextButton(onClick = onOpenAppSettings) { Text("App settings") }
            ReaderPreferenceControls(prefs, onChange)
        }
    }, confirmButton = { TextButton(onClick = onDismiss, modifier = Modifier.testTag("reader_settings_done")) { Text("Done") } })
}
