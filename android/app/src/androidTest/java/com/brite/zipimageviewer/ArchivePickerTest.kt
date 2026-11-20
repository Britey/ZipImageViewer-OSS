package com.brite.zipimageviewer

import android.content.ClipData
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ArchivePickerTest {
    @Test fun fileAppRequestAllowsNetworkAndOptionalMimeFiltering() {
        val component = ComponentName("example.files", "example.files.Picker")
        val all = archiveFileAppIntent(true, component)
        assertEquals(Intent.ACTION_GET_CONTENT, all.action)
        assertTrue(all.hasCategory(Intent.CATEGORY_OPENABLE))
        assertEquals("*/*", all.type)
        assertEquals(component, all.component)
        assertFalse(all.hasExtra(Intent.EXTRA_LOCAL_ONLY))
        assertFalse(all.hasExtra(Intent.EXTRA_MIME_TYPES))
        assertArrayEquals(archivePickerMimeTypes, archiveFileAppIntent(false).getStringArrayExtra(Intent.EXTRA_MIME_TYPES))
        val system = archiveSystemPickerIntent(false)
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, system.action)
        assertTrue(system.hasCategory(Intent.CATEGORY_OPENABLE))
        assertNull(system.component)
        assertFalse(system.hasExtra(Intent.EXTRA_LOCAL_ONLY))
        assertArrayEquals(archivePickerMimeTypes, system.getStringArrayExtra(Intent.EXTRA_MIME_TYPES))
    }

    @Test fun acceptsSingleGrantedContentResultFromDataOrClipData() {
        val uri = Uri.parse("content://example.files/network/book.cbz")
        assertEquals(uri, archivePickerResultUri(Intent().setData(uri)))
        assertEquals(uri, archivePickerResultUri(Intent().apply { clipData = ClipData.newRawUri("archive", uri) }))
        assertEquals(uri, archivePickerResultUri(Intent().setData(uri).apply { clipData = ClipData.newRawUri("archive", uri) }))
    }

    @Test fun rejectsAmbiguousMalformedAndRawFilesystemResults() {
        val uri = Uri.parse("content://example.files/book.cbz")
        val other = Uri.parse("content://example.files/other.cbz")
        assertNull(archivePickerResultUri(null))
        assertNull(archivePickerResultUri(Intent()))
        assertNull(archivePickerResultUri(Intent().setData(Uri.parse("file:///sdcard/book.cbz"))))
        assertNull(archivePickerResultUri(Intent().setData(Uri.parse("content:///book.cbz"))))
        assertNull(archivePickerResultUri(Intent().setData(Uri.parse("content://user:pass@provider/book.cbz"))))
        assertNull(archivePickerResultUri(Intent().setData(uri).apply { clipData = ClipData.newRawUri("archive", other) }))
        assertNull(archivePickerResultUri(Intent().apply {
            clipData = ClipData.newRawUri("archive", uri).apply { addItem(ClipData.Item(other)) }
        }))
    }
}
