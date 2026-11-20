package com.brite.zipimageviewer.data

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.util.concurrent.CancellationException
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import net.lingala.zip4j.ZipFile

class ZipMetadataAdmissionTest {
    private fun fixture(names: List<String> = listOf("1.png", "2.png")): ByteArray {
        val bytes = ByteArrayOutputStream()
        ZipOutputStream(bytes).use { zip -> names.forEach {
            zip.putNextEntry(ZipEntry(it)); zip.write(byteArrayOf(1, 2, 3)); zip.closeEntry()
        } }
        return bytes.toByteArray()
    }
    private fun withArchive(bytes: ByteArray, block: (File) -> Unit) {
        val directory = Files.createTempDirectory("zip-admission-test").toFile()
        try { val file = File(directory, "fixture.zip"); file.writeBytes(bytes); block(file) }
        finally { directory.deleteRecursively() }
    }
    private fun rejected(bytes: ByteArray, limits: ExtractionLimits = ExtractionLimits()) {
        withArchive(bytes) { file ->
            var materialized = false
            try {
                ZipMetadataAdmission.check(file, limits) {}
                materialized = true
                ZipFile(file).use { it.fileHeaders }
                fail("Expected rejection")
            } catch (_: ImportFailure) { assertFalse("Must reject before Zip4j allocation", materialized) }
        }
    }
    @Test fun validDirectoryAdmittedAndParsed() = withArchive(fixture()) {
        ZipMetadataAdmission.check(it, ExtractionLimits()) {}
        ZipFile(it).use { zip -> assertEquals(2, zip.fileHeaders.size) }
    }
    @Test fun countAndMetadataCapsPrecedeMaterialization() {
        rejected(fixture(), ExtractionLimits(maximumEntryCount = 1))
        rejected(fixture(), ExtractionLimits(maximumZipMetadataBytes = 40))
    }
    @Test fun inconsistentCountsAndSizeRejected() {
        for ((offset, value) in listOf(8 to 1, 10 to 1, 12 to 1, 16 to 1)) {
            val bytes = fixture(); bytes[bytes.size - 22 + offset] = value.toByte()
            rejected(bytes)
        }
    }
    @Test fun oversizedFilenameRejected() = rejected(fixture(listOf("a".repeat(4097) + ".png")))
    @Test fun malformedExtraFieldRejected() {
        val bytes = fixture(); val end = bytes.size - 22
        val directory = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).getInt(end + 16)
        // Claim an extra field that cannot fit in the declared directory layout.
        bytes[directory + 30] = 100
        rejected(bytes)
    }
    @Test fun commentCannotSelectDifferentDirectoryInZip4j() {
        val bytes = fixture()
        val comment = ByteArray(40)
        ByteBuffer.wrap(comment).order(ByteOrder.LITTLE_ENDIAN).putInt(0x06054b50)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).putShort(bytes.size - 2, 40)
        rejected(bytes + comment)
    }
    @Test fun splitAndTrailingDataRejected() {
        val bytes = fixture(); bytes[bytes.size - 22 + 4] = 1
        rejected(bytes)
        rejected(fixture() + byteArrayOf(0))
    }
    @Test fun cancellationStopsMetadataScan() = withArchive(fixture()) { file ->
        var calls = 0
        try {
            ZipMetadataAdmission.check(file, ExtractionLimits()) { if (++calls == 2) throw CancellationException() }
            fail("Expected cancellation")
        } catch (_: CancellationException) { assertEquals(2, calls) }
    }
    private fun zip64(): ByteArray {
        val original = fixture(); val end = original.size - 22
        val old = ByteBuffer.wrap(original).order(ByteOrder.LITTLE_ENDIAN)
        val size = old.getInt(end + 12).toLong(); val offset = old.getInt(end + 16).toLong()
        val record = ByteBuffer.allocate(76).order(ByteOrder.LITTLE_ENDIAN)
        record.putInt(0x06064b50).putLong(44).putShort(45).putShort(45).putInt(0).putInt(0)
            .putLong(2).putLong(2).putLong(size).putLong(offset)
            .putInt(0x07064b50).putInt(0).putLong(end.toLong()).putInt(1)
        val ending = original.copyOfRange(end, original.size)
        ByteBuffer.wrap(ending).order(ByteOrder.LITTLE_ENDIAN).apply {
            putShort(8, -1); putShort(10, -1); putInt(12, -1); putInt(16, -1)
        }
        return original.copyOfRange(0, end) + record.array() + ending
    }
    @Test fun zip64AdmittedAndCappedBeforeMaterialization() {
        withArchive(zip64()) { file ->
            ZipMetadataAdmission.check(file, ExtractionLimits()) {}
            ZipFile(file).use { assertEquals(2, it.fileHeaders.size) }
        }
        rejected(zip64(), ExtractionLimits(maximumEntryCount = 1))
    }
    @Test fun zip64ConflictingDeclarationsAndUnsignedOverflowRejected() {
        val conflict = zip64(); conflict[conflict.size - 22 + 12] = 1
        rejected(conflict)
        val overflow = zip64(); overflow[overflow.size - 22 - 76 + 32 + 7] = 0x80.toByte()
        rejected(overflow)
    }
}
