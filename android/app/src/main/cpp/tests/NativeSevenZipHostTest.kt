package com.brite.zipimageviewer.nativebridge

import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean

/** Integration regression runner for production Kotlin policy + JNI against the repo's independent fixtures. */
fun main(args: Array<String>) {
    require(args.size == 1) { "Pass android/app/src/androidTest/assets/archive-fixtures" }
    val fixtures = File(args[0])
    val temporary = Files.createTempDirectory("ziv-native-regression-").toFile()
    var assertions = 0
    fun expect(value: Boolean, context: String) { check(value) { context }; assertions++ }
    val hashes = mapOf(
        "panel.png" to "97a3a410c9bca540512251c37ce63982edccbed54c6f2e1d06ec717b9f753e29",
        "nested/panel.png" to "7c3c919026a6f27ace0891b608cc0697fec53dedc25562bfd1443285557cdf8f",
        "nested/PHOTO.JPG" to "bac75dc1b4d783d69d35e7e40e48a3ad294fada2b0773f2d2c9b1002b0f84cda",
    )
    fun digest(file: File): String = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
    fun extract(name: String, password: String? = null, progress: (Float) -> Unit = {}, cancelled: () -> Boolean = { false }): Pair<List<String>, File> {
        val dest = File(temporary, "attempt-${assertions}-${System.nanoTime()}")
        return NativeSevenZip.extract(File(fixtures, name).path, dest.path, password, progress, cancelled) to dest
    }
    fun failure(name: String, password: String? = null, type: Class<out Throwable> = IOException::class.java) {
        val dest = File(temporary, "failure-${assertions}")
        val result = runCatching { NativeSevenZip.extract(File(fixtures, name).path, dest.path, password, {}, { false }) }
        expect(result.exceptionOrNull()?.let { type.isInstance(it) } == true, "$name expected ${type.simpleName}, got ${result.exceptionOrNull()}")
        expect(!dest.exists(), "$name leaves no partially extracted directory")
    }
    try {
        val successes = listOf(
            "plain-lzma-solid.7z" to null, "plain-lzma2-nonsolid.7z" to null,
            "plain-ppmd.7z" to null, "content-lzma2-solid.7z" to "test-password",
            "headers-lzma-solid.7z" to "test-password", "headers-lzma2-nonsolid.7z" to "test-password",
            "unicode-password.7z" to "密码🔐café", "whitespace-password.7z" to "  padded password  ",
            "hidden-images.7z" to null,
        )
        for ((fixture, password) in successes) {
            val (names, root) = extract(fixture, password)
            expect(names.toSet() == hashes.keys, "$fixture selects visible image entries")
            hashes.forEach { (name, hash) -> expect(digest(File(root, name)) == hash, "$fixture/$name content hash") }
        }
        val metadata = NativeSevenZip.extractDetailed(File(fixtures, "plain-lzma-solid.7z").path,
            File(temporary, "metadata").path, null, {}, { false })
        expect(metadata.size == 3 && metadata.all { it.modifiedAt == 1_700_000_000_000L }, "Original modification dates from archive")
        expect(metadata.all { it.createdAt == null }, "Missing creation dates remain absent")
        val (unicode, root) = extract("unicode-filename.7z")
        expect(unicode == listOf("图像🔐.png"), "Supplementary filename survives JNI")
        expect(File(root, unicode.single()).isFile, "Unicode file exists")
        val (many, manyRoot) = extract("many-images-solid-encrypted.7z", "test-password")
        expect(many.size == 600 && many.distinct().size == 600, "600-image encrypted solid archive")
        expect(many.all { File(manyRoot, it).length() > 0 }, "All 600 streams closed with data")
        for (name in listOf("unsafe-traversal.7z", "case-collision.7z", "no-images.7z", "plain.zip")) failure(name)
        for (name in listOf("headers-lzma-solid.7z", "content-lzma2-solid.7z")) {
            failure(name, type = PasswordRequiredException::class.java)
            failure(name, "wrong", PasswordRequiredException::class.java)
        }
        failure("unicode-password.7z", "密码wrong", PasswordRequiredException::class.java)
        failure("whitespace-password.7z", "padded password", PasswordRequiredException::class.java)
        failure("truncated.7z")
        failure("damaged-content.7z", "test-password")
        val cancelled = AtomicBoolean(false)
        val cancelDest = File(temporary, "cancelled")
        val cancellation = runCatching {
            NativeSevenZip.extract(File(fixtures, "cancellation.7z").path, cancelDest.path, null,
                { if (it > 0f) cancelled.set(true) }, { cancelled.get() })
        }
        expect(cancellation.exceptionOrNull() is InterruptedIOException, "Mid-decode cancellation returns InterruptedIOException")
        expect(!cancelDest.exists(), "Cancellation rolls back output")
        val sentinel = IllegalStateException("Callback sentinel")
        val callbackError = runCatching { extract("cancellation.7z", progress = { throw sentinel }) }.exceptionOrNull()
        expect(callbackError === sentinel, "Cross-thread callback error propagates original Throwable")
        val existing = File(temporary, "existing").apply { mkdirs() }
        File(existing, "keep.txt").writeText("Keep")
        val nonempty = runCatching { NativeSevenZip.extract(File(fixtures, "plain-lzma-solid.7z").path, existing.path, null, {}, { false }) }
        expect(nonempty.exceptionOrNull() is IOException, "Nonempty destination rejected")
        expect(File(existing, "keep.txt").readText() == "Keep", "Failure preserves unowned destination")
        val link = File(temporary, "linked")
        Files.createSymbolicLink(link.toPath(), existing.toPath())
        val symlink = runCatching { NativeSevenZip.extract(File(fixtures, "plain-lzma-solid.7z").path, link.path, null, {}, { false }) }
        expect(symlink.exceptionOrNull() is IOException, "Symlink destination rejected")
        expect(File(existing, "keep.txt").readText() == "Keep", "Symlink rejection preserves target")
        println("NativeSevenZip production Kotlin + JNI: $assertions assertions passed")
    } finally { temporary.deleteRecursively() }
}
