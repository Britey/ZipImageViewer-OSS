package com.brite.zipimageviewer.data

import android.net.Uri
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/** An immutable source selection and compression snapshot, with an app-private staged download. */
class ArchiveImportSession internal constructor(
    internal val repositoryToken: String,
    internal val uri: Uri,
    internal val compressImages: Boolean,
    internal val directory: File,
) {
    internal val closed = AtomicBoolean(false)
    // Accessed only under the repository mutex. No passwords are persisted in a session.
    internal var prepared: PreparedArchiveSource? = null
}

internal data class PreparedArchiveSource(val name: String, val digest: String)
