package com.brite.zipimageviewer.data

import java.io.File
import java.io.RandomAccessFile

/** Validate the actual directory with constant scratch space BEFORE Zip4j allocates its model.
 * Deliberately rejects split/SFX archives, trailing junk and ambiguous ZIP64 declarations.
 * The source must be the operation-owned, immutable copy, not a provider-controlled file.
 */
internal object ZipMetadataAdmission {
    fun check(source: File, limits: ExtractionLimits, cancelled: () -> Unit) {
        RandomAccessFile(source, "r").use { input ->
            fun invalid(): Nothing = throw ImportFailure("Invalid or unsupported ZIP directory.")
            fun u16(): Long = input.readUnsignedByte().toLong() or (input.readUnsignedByte().toLong() shl 8)
            fun u32(): Long = u16() or (u16() shl 16)
            fun u64(): Long { val low = u32(); val high = u32(); if (high >= 0x80000000L) invalid(); return low or (high shl 32) }
            val length = input.length()
            if (length < 22) invalid()
            var end = length - 4
            val lower = maxOf(0, length - 65557)
            while (true) {
                cancelled()
                input.seek(end)
                if (u32() == 0x06054b50L) {
                    if (end > length - 22) invalid()
                    input.seek(end + 20)
                    // Zip4j uses the last signature, even inside a comment. Do not
                    // admit one directory and then let it parse a different one.
                    if (end + 22 + u16() != length) invalid()
                    break
                }
                if (end == lower) invalid()
                end--
            }
            input.seek(end + 4)
            if (u16() != 0L || u16() != 0L) invalid()
            val diskCount = u16(); val count32 = u16(); val size32 = u32(); val offset32 = u32()
            if (diskCount != count32) invalid()
            var count = count32; var size = size32; var offset = offset32; var directoryEnd = end
            if (end >= 20) {
                input.seek(end - 20)
                if (u32() == 0x07064b50L) {
                    if (u32() != 0L) invalid()
                    val zip64 = u64()
                    if (u32() != 1L || zip64 > end - 76) invalid()
                    input.seek(zip64)
                    if (u32() != 0x06064b50L) invalid()
                    val recordSize = u64()
                    if (recordSize < 44 || recordSize > 4096 || zip64 + 12 + recordSize != end - 20) invalid()
                    u16(); u16()
                    if (u32() != 0L || u32() != 0L) invalid()
                    val countOnDisk = u64(); count = u64(); size = u64(); offset = u64()
                    if (countOnDisk != count || (count32 != 65535L && count32 != count) ||
                        (size32 != 0xffffffffL && size32 != size) || (offset32 != 0xffffffffL && offset32 != offset)) invalid()
                    directoryEnd = zip64
                } else if (count32 == 65535L || size32 == 0xffffffffL || offset32 == 0xffffffffL) invalid()
            }
            if (count > limits.maximumEntryCount || size > limits.maximumZipMetadataBytes) {
                throw ImportFailure("The ZIP directory exceeds the safe metadata limit.")
            }
            if (offset > directoryEnd || size != directoryEnd - offset || count > size / 46) invalid()
            var position = offset
            var extraRecords = 0
            repeat(count.toInt()) {
                cancelled()
                if (directoryEnd - position < 46) invalid()
                input.seek(position)
                if (u32() != 0x02014b50L) invalid()
                input.seek(position + 28)
                val name = u16(); val extra = u16(); val comment = u16(); val disk = u16()
                if (name == 0L || name > 4096 || extra > 16384 || comment > 4096 || disk != 0L) invalid()
                val next = position + 46 + name + extra + comment
                if (next > directoryEnd) invalid()
                // A short field can create an object in Zip4j: bound object count too.
                var field = position + 46 + name
                val extraEnd = field + extra
                while (field < extraEnd) {
                    cancelled()
                    if (extraEnd - field < 4 || ++extraRecords > 65536) invalid()
                    input.seek(field); u16(); val bytes = u16()
                    field += 4 + bytes
                    if (field > extraEnd) invalid()
                }
                position = next
            }
            if (position != directoryEnd) invalid()
            cancelled()
        }
    }
}
