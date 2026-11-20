package com.brite.zipimageviewer.reader

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import kotlin.math.roundToInt

/** Shared library/reader settings content. The caller owns scrolling and its enclosing surface. */
@Composable
fun ReaderPreferenceControls(prefs: ReaderPreferences, onChange: (ReaderPreferences) -> Unit) {
    val current = prefs.validated()
    var tapAreasOpen by rememberSaveable { mutableStateOf(false) }
    var helpOpen by rememberSaveable { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth()) {
        PreferenceSwitch("Show image rotation buttons", current.showRotationButtons) { onChange(current.copy(showRotationButtons = it)) }
        PreferenceSwitch("Page slider", current.showSlider) { onChange(current.copy(showSlider = it)) }
        PreferenceSwitch("Page count", current.showCount) { onChange(current.copy(showCount = it)) }
        PreferenceSwitch("Center tap shows controls", current.centerTap) { onChange(current.copy(centerTap = it)) }
        PreferenceSwitch("Reverse taps and swipes", current.reversed) { onChange(current.copy(reversed = it)) }
        PreferenceSwitch("Double-tap to zoom", current.doubleTapZoom) { onChange(current.copy(doubleTapZoom = it)) }
        PreferenceSwitch("Animate page changes", current.animate) { onChange(current.copy(animate = it)) }
        HorizontalDivider(Modifier.padding(vertical = 16.dp))
        SettingsDetailRow("Tap areas", "Left ${(current.tapRatio * 100).roundToInt()}% · Right ${100 - (current.tapRatio * 100).roundToInt()}%", "tap_area_settings") { tapAreasOpen = true }
        HorizontalDivider(Modifier.padding(vertical = 16.dp))
        Text("Sort pages", style = MaterialTheme.typography.titleSmall)
        SortCriterion.entries.forEach { criterion ->
            Row(Modifier.fillMaxWidth().clickable { onChange(current.copy(sortCriterion = criterion)) }, verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected = current.sortCriterion == criterion, onClick = { onChange(current.copy(sortCriterion = criterion)) })
                Text(criterion.label)
            }
        }
        PreferenceSwitch("Descending order", current.descending) { onChange(current.copy(descending = it)) }
        Text("The current page stays selected when sorting changes.", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(vertical = 8.dp))
        Text("Thumbnail size", style = MaterialTheme.typography.titleSmall)
        Slider(current.thumbnailSize, onValueChange = { onChange(current.copy(thumbnailSize = it)) }, valueRange = 0f..1f,
            modifier = Modifier.semantics { contentDescription = "Thumbnail size" })
        HorizontalDivider(Modifier.padding(vertical = 16.dp))
        SettingsDetailRow("Reader gestures", "Learn how to turn pages and show controls", "reader_help_settings") { helpOpen = true }
    }
    if (tapAreasOpen) AlertDialog(onDismissRequest = { tapAreasOpen = false }, title = { Text("Tap areas") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()).testTag("tap_area_dialog")) { TapAreaPresetPicker(current, onChange) }
    }, confirmButton = { TextButton(onClick = { tapAreasOpen = false }, modifier = Modifier.testTag("tap_area_done")) { Text("Done") } })
    if (helpOpen) AlertDialog(onDismissRequest = { helpOpen = false }, title = { Text("Reader gestures") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()).testTag("reader_help_dialog")) { ReaderInteractionHelp() }
    }, confirmButton = { TextButton(onClick = { helpOpen = false }, modifier = Modifier.testTag("reader_help_done")) { Text("Done") } })
}

@Composable
private fun SettingsDetailRow(title: String, summary: String, tag: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(role = Role.Button, onClick = onClick).testTag(tag),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
            Text(title, style = MaterialTheme.typography.bodyMedium)
            Text(summary, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text("›", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(start = 12.dp))
    }
}

@Composable
private fun TapAreaPresetPicker(prefs: ReaderPreferences, onChange: (ReaderPreferences) -> Unit) {
    val leftPercent = (prefs.tapRatio * 100).roundToInt()
    val rightPercent = 100 - leftPercent
    val leftAction = if (prefs.reversed) "Next page" else "Previous page"
    val rightAction = if (prefs.reversed) "Previous page" else "Next page"
    val summary = "Left $leftPercent percent: $leftAction. Right $rightPercent percent: $rightAction." +
        if (prefs.centerTap) " Small center area: show or hide controls." else ""
    Text("Left $leftPercent% · Right $rightPercent%", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 8.dp, bottom = 12.dp))
    Box(Modifier.fillMaxWidth().height(88.dp).clip(RoundedCornerShape(12.dp))
        .testTag("tap_area_preview").clearAndSetSemantics { contentDescription = "Tap area preview. $summary" }) {
        // Canvas x-coordinates are physical positions, so RTL locales do not mirror these zones.
        Canvas(Modifier.fillMaxSize()) {
            val boundary = size.width * prefs.tapRatio
            drawRect(Color(0xFF2D6798))
            drawRect(Color(0xFF9B6234), topLeft = Offset(boundary, 0f), size = Size(size.width - boundary, size.height))
            drawLine(Color.White.copy(alpha = 0.8f), Offset(boundary, 0f), Offset(boundary, size.height), strokeWidth = 2.dp.toPx())
        }
        if (prefs.centerTap) {
            Box(Modifier.align(Alignment.Center).size(44.dp, 32.dp).background(MaterialTheme.colorScheme.surface, RoundedCornerShape(6.dp)), contentAlignment = Alignment.Center) {
                Icon(Icons.Outlined.Visibility, contentDescription = null, modifier = Modifier.size(20.dp))
            }
        }
    }
    Text("Left $leftPercent%: $leftAction", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 8.dp))
    Text("Right $rightPercent%: $rightAction", style = MaterialTheme.typography.bodySmall)
    if (prefs.centerTap) Text("Small center area: show or hide controls", style = MaterialTheme.typography.bodySmall)
    Text("Choose a layout", style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 16.dp, bottom = 4.dp))
    ReaderPreferences.tapAreaPresets.forEach { ratio ->
        val percent = (ratio * 100).roundToInt()
        val recommended = abs(ratio - if (prefs.reversed) 0.7f else 0.3f) < 0.001f
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp)
            .selectable(selected = abs(prefs.tapRatio - ratio) < 0.001f, role = Role.RadioButton, onClick = { onChange(prefs.copy(tapRatio = ratio)) })
            .testTag("tap_area_preset_$percent"), verticalAlignment = Alignment.CenterVertically) {
            RadioButton(selected = abs(prefs.tapRatio - ratio) < 0.001f, onClick = null, modifier = Modifier.padding(end = 12.dp))
            Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
                Text("Left $percent% · Right ${100 - percent}%", style = MaterialTheme.typography.bodyMedium)
                if (recommended) Text("Recommended for this reading direction", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("tap_area_recommended_$percent"))
            }
        }
    }
    Text("These are physical screen areas. Reversing the reading direction swaps their page actions. A larger next-page area helps with one-handed reading.",
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp))
}

@Composable
private fun ReaderInteractionHelp() {
    Column(Modifier.testTag("reader_interaction_help"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Tap either side or swipe left or right to turn pages. Reverse reading direction swaps these actions.", style = MaterialTheme.typography.bodySmall)
        Text("Pinch to zoom and drag to pan. Double tap changes zoom when enabled in Settings.", style = MaterialTheme.typography.bodySmall)
        Text("Touch and hold anywhere on the image to show or hide controls. When enabled, a small center tap does the same. Back shows hidden controls before returning to the library.", style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun PreferenceSwitch(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, modifier = Modifier.weight(1f).padding(end = 12.dp), style = MaterialTheme.typography.bodyMedium)
        Switch(checked, onCheckedChange, modifier = Modifier.semantics { contentDescription = label })
    }
}
