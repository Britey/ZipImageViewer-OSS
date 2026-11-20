package com.brite.zipimageviewer.reader

/** Per-session bridge. Detaching a canvas never releases its archive. */
data class ReaderSurfaceState(val page: Int = 1, val count: Int = 0, val displayedPage: Int? = null,
    val controls: Boolean = true, val failed: Boolean = false, val detailFailed: Boolean = false,
    val imageQuarterTurns: Int = 0, val rotationPagePath: String? = null)
class SharedReaderAdapter(val initialControls: Boolean, val onState: (ReaderSurfaceState) -> Unit,
    val onTool: (String) -> Unit, val initialQuarterTurns: Int = 0, val rotationPagePath: String? = null) {
    var action: ((String, Int?, Boolean) -> Unit)? = null
}
