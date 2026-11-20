package com.brite.zipimageviewer.data

import net.lingala.zip4j.model.FileHeader
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** ZIP NTFS and extended timestamp metadata describe the original archive member, never extraction time. */
object ZipEntryMetadata {
    fun page(header: FileHeader): PageRecord {
        var modified = header.lastModifiedTimeEpoch.takeIf { header.lastModifiedTime != 0L && it > 0 }
        var created: Long? = null
        header.extraDataRecords.orEmpty().forEach { extra ->
            val data = extra.data ?: return@forEach
            val buffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
            if (extra.header == 0x000aL && data.size >= 8) {
                buffer.position(4)
                while (buffer.remaining() >= 4) {
                    val tag = buffer.short.toInt() and 0xffff
                    val size = buffer.short.toInt() and 0xffff
                    if (size > buffer.remaining()) break
                    val end = buffer.position() + size
                    if (tag == 1 && size >= 24) {
                        modified = fileTime(buffer.long) ?: modified
                        buffer.long // access time is deliberately not reader metadata
                        created = fileTime(buffer.long)
                    }
                    buffer.position(end)
                }
            } else if (extra.header == 0x5455L && data.isNotEmpty()) {
                val flags = buffer.get().toInt() and 255
                for (bit in 0..2) if ((flags and (1 shl bit)) != 0 && buffer.remaining() >= 4) {
                    val value = (buffer.int.toLong() and 0xffffffffL) * 1000
                    if (bit == 0 && value > 0) modified = value
                    if (bit == 2 && value > 0) created = value
                }
            }
        }
        return PageRecord(header.fileName, header.fileName, modified, created)
    }

    private fun fileTime(value: Long): Long? = if (value <= 0) null else (value / 10_000 - 11_644_473_600_000L).takeIf { it >= 0 }
}
