package com.brite.zipimageviewer

import android.content.Intent
import android.net.Uri
import androidx.core.content.IntentCompat

/** The exported activity accepts file grants, never filesystem paths or network addresses. */
object IncomingArchiveIntent {
    sealed interface Result {
        data object Ignore : Result
        data class Open(val uri: Uri) : Result
        data class Invalid(val message: String) : Result
    }

    fun parse(intent: Intent): Result {
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) return Result.Invalid("Open one archive at a time.")
        if (intent.action != Intent.ACTION_VIEW && intent.action != Intent.ACTION_SEND) return Result.Ignore
        return try {
            val primary = if (intent.action == Intent.ACTION_VIEW) intent.data
                else IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
            if (intent.action == Intent.ACTION_SEND && intent.hasExtra(Intent.EXTRA_STREAM) && primary == null) {
                return Result.Invalid("The sending app did not provide a readable file. Try Open using… in the library.")
            }
            val clip = intent.clipData
            if (clip != null && clip.itemCount > 1) return Result.Invalid("Open one archive at a time.")
            val fallback = clip?.takeIf { it.itemCount == 1 }?.getItemAt(0)?.uri
            if (primary != null && fallback != null && primary != fallback) {
                return Result.Invalid("The sending app provided conflicting files. Open one archive at a time.")
            }
            val uri = primary ?: fallback
                ?: return Result.Invalid("No archive was attached. Share a ZIP, CBZ or 7z file, or use Open using… in the library.")
            if (uri.scheme != "content" || uri.authority.isNullOrBlank() || uri.userInfo != null) {
                Result.Invalid("This app needs a readable file from a file provider. Use Open using… or share the file itself, rather than its address.")
            } else Result.Open(uri)
        } catch (_: RuntimeException) {
            Result.Invalid("The sending app provided an invalid file. Try selecting it with Open using… in the library.")
        }
    }
}
