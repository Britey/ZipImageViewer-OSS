package com.brite.zipimageviewer.data

import net.lingala.zip4j.model.ExtraDataRecord
import net.lingala.zip4j.model.FileHeader
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class ZipEntryMetadataTest {
    @Test fun ntfsCreationAndModificationTimesUseOriginalArchiveValues() {
        val modified = 1_577_836_800_000L
        val created = 1_546_300_800_000L
        val bytes = ByteBuffer.allocate(32).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(0).putShort(1).putShort(24)
            .putLong((modified + 11_644_473_600_000L) * 10_000)
            .putLong(0).putLong((created + 11_644_473_600_000L) * 10_000).array()
        val page = ZipEntryMetadata.page(header(0x000a, bytes))
        assertEquals(modified, page.modifiedAt)
        assertEquals(created, page.createdAt)
        assertEquals("page.png", page.originalPath)
    }

    @Test fun extendedTimestampCreationDoesNotInventAbsentModification() {
        val seconds = 1_577_836_800L
        val data = ByteBuffer.allocate(5).order(ByteOrder.LITTLE_ENDIAN).put(4).putInt(seconds.toInt()).array()
        val page = ZipEntryMetadata.page(header(0x5455, data))
        assertNull(page.modifiedAt)
        assertEquals(seconds * 1000, page.createdAt)
    }

    @Test fun missingAndTruncatedDatesRemainUnknownWithoutFilesystemFallback() {
        assertNull(ZipEntryMetadata.page(FileHeader().apply { fileName = "page.jpg" }).createdAt)
        assertNull(ZipEntryMetadata.page(header(0x000a, byteArrayOf(0, 0, 0))).createdAt)
        assertNull(ZipEntryMetadata.page(header(0x5455, byteArrayOf(7))).createdAt)
    }

    private fun header(tag: Long, bytes: ByteArray) = FileHeader().apply {
        fileName = "page.png"
        extraDataRecords = listOf(ExtraDataRecord().apply { this.header = tag; data = bytes; sizeOfData = bytes.size })
    }
}
