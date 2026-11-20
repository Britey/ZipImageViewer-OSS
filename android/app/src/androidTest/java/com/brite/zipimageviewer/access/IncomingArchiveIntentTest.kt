package com.brite.zipimageviewer.access

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import com.brite.zipimageviewer.IncomingArchiveIntent
import org.junit.Assert.*
import org.junit.Test

class IncomingArchiveIntentTest {
    private val uri = Uri.parse("content://com.brite.zipimageviewer.test.intents/one")
    @Test fun viewAndSendAcceptContentWithoutTrustingItsTypeOrExtension() {
        for (intent in listOf(Intent(Intent.ACTION_VIEW, uri),
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uri))) {
            assertEquals(IncomingArchiveIntent.Result.Open(uri), IncomingArchiveIntent.parse(intent))
        }
    }
    @Test fun clipDataFallbackAndDuplicatedGrantAreAccepted() {
        val intent = Intent(Intent.ACTION_SEND).apply { clipData = ClipData.newRawUri("Archive", uri) }
        assertEquals(IncomingArchiveIntent.Result.Open(uri), IncomingArchiveIntent.parse(intent))
        intent.putExtra(Intent.EXTRA_STREAM, uri)
        assertEquals(IncomingArchiveIntent.Result.Open(uri), IncomingArchiveIntent.parse(intent))
    }
    @Test fun pathsNetworkAddressesAndMalformedContentAreRejected() {
        for (value in listOf("file:///data/user/0/secret.zip", "smb://server/archive.cbz",
            "https://example.com/archive.zip", "content:///missing-authority", "content://user:pass@server/file")) {
            assertTrue(value, IncomingArchiveIntent.parse(Intent(Intent.ACTION_VIEW, Uri.parse(value))) is IncomingArchiveIntent.Result.Invalid)
        }
    }
    @Test fun multipleAndConflictingFilesAreRejected() {
        val clip = ClipData.newRawUri("Archive", uri).apply { addItem(ClipData.Item(uri)) }
        assertTrue(IncomingArchiveIntent.parse(Intent(Intent.ACTION_SEND).apply { clipData = clip }) is IncomingArchiveIntent.Result.Invalid)
        assertTrue(IncomingArchiveIntent.parse(Intent(Intent.ACTION_SEND_MULTIPLE)) is IncomingArchiveIntent.Result.Invalid)
        assertTrue(IncomingArchiveIntent.parse(Intent(Intent.ACTION_VIEW, uri).apply {
            clipData = ClipData.newRawUri("Different", Uri.parse("content://provider/two"))
        }) is IncomingArchiveIntent.Result.Invalid)
    }
    @Test fun missingAndWronglyTypedStreamsFailWithoutCrashing() {
        assertTrue(IncomingArchiveIntent.parse(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "smb://server/file")) is IncomingArchiveIntent.Result.Invalid)
        assertTrue(IncomingArchiveIntent.parse(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, "bad")) is IncomingArchiveIntent.Result.Invalid)
        assertEquals(IncomingArchiveIntent.Result.Ignore, IncomingArchiveIntent.parse(Intent(Intent.ACTION_MAIN)))
    }
}
