package com.brite.zipimageviewer.nativebridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises the NDK-built library on ART, including its real thread and UTF-16 JNI boundary. */
@RunWith(AndroidJUnit4::class)
class NativeSevenZipInstrumentedTest {
    private lateinit var root: File
    private lateinit var manifest: JSONObject
    private val assets get() = InstrumentationRegistry.getInstrumentation().context.assets

    @Before fun setUp() {
        root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "native-test-${UUID.randomUUID()}")
        check(root.mkdirs())
        manifest = JSONObject(assets.open("archive-fixtures/manifest.json").bufferedReader().use { it.readText() })
    }

    @After fun tearDown() { root.deleteRecursively() }

    private fun archive(name: String): File = File(root, name).also { file ->
        if (!file.exists()) assets.open("archive-fixtures/$name").use { source -> file.outputStream().use { output -> source.copyTo(output) } }
    }

    private fun destination(): File = File(root, "out-${UUID.randomUUID()}")
    private fun fixture(name: String): JSONObject {
        val list = manifest.getJSONArray("fixtures")
        return (0 until list.length()).map(list::getJSONObject).first { it.getString("file") == name }
    }
    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val bytes = ByteArray(64 * 1024)
            while (true) { val size = input.read(bytes); if (size < 0) break; digest.update(bytes, 0, size) }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
    private fun assertImage(root: File, name: String, expected: JSONObject) {
        val file = File(root, name)
        assertTrue(name, file.isFile)
        assertEquals("$name length", expected.getLong("size"), file.length())
        assertEquals("$name SHA256", expected.getString("sha256"), sha256(file))
    }
    private fun expectFailure(name: String, password: String?, type: Class<out Throwable> = IOException::class.java) {
        val output = destination()
        val error = runCatching { NativeSevenZip.extract(archive(name).path, output.path, password, {}, { false }) }.exceptionOrNull()
        assertTrue("$name expected ${type.simpleName}, got $error", type.isInstance(error))
        assertFalse("$name partial output removed", output.exists())
    }

    @Test fun everySupportedCodecAndEncryptionFixtureMatchesIndependentManifestHashes() {
        val list = manifest.getJSONArray("fixtures")
        for (index in 0 until list.length()) {
            val fixture = list.getJSONObject(index)
            val name = fixture.getString("file")
            if (!name.endsWith(".7z") || fixture.getString("expected") !in setOf("success", "unicodeFilename")) continue
            val input = archive(name)
            assertEquals("$name fixture hash", fixture.getString("archive_sha256"), sha256(input))
            val password = if (fixture.isNull("password")) null else fixture.getString("password")
            val output = destination()
            val names = NativeSevenZip.extract(input.path, output.path, password, {}, { false })
            val expected = fixture.optJSONObject("expected_images") ?: manifest.getJSONObject("expected_images")
            assertEquals("$name selected images", expected.keys().asSequence().toSet(), names.toSet())
            for (image in names) assertImage(output, image, expected.getJSONObject(image))
        }
    }

    @Test fun originalDatesComeFromArchiveHeadersAndMissingCreationRemainsUnknown() {
        val entries = NativeSevenZip.extractDetailed(archive("plain-lzma-solid.7z").path,
            destination().path, null, {}, { false })
        assertEquals(3, entries.size)
        entries.forEach {
            assertEquals(it.path, 1_700_000_000_000L, it.modifiedAt)
            assertNull("Missing creation time must not become extraction time", it.createdAt)
        }
    }

    @Test fun creationOnlyMetadataSurvivesAndDoesNotInventModificationTime() {
        val page = NativeSevenZip.extractDetailed(archive("creation-only.7z").path,
            destination().path, null, {}, { false }).single()
        assertEquals("panel.png", page.path)
        assertEquals(1_577_836_800_000L, page.createdAt)
        assertNull(page.modifiedAt)
    }

    @Test fun sixHundredEncryptedSolidImagesCanBeExtractedRepeatedlyWithoutMissingOrDuplicateStreams() {
        val spec = fixture("many-images-solid-encrypted.7z")
        val input = archive(spec.getString("file"))
        assertEquals(spec.getString("archive_sha256"), sha256(input))
        repeat(2) {
            val output = destination()
            val names = NativeSevenZip.extract(input.path, output.path, spec.getString("password"), {}, { false })
            assertEquals(spec.getInt("image_count"), names.size)
            val expectedNames = (0 until 600).map { "pages/page-${it.toString().padStart(4, '0')}.png" }.toSet()
            assertEquals(expectedNames, names.toSet())
            names.forEach { assertImage(output, it, spec.getJSONObject("expected_image")) }
        }
    }

    @Test fun supplementaryCharactersSurviveBothPasswordAndFilenameBoundaries() {
        val output = destination()
        val paths = NativeSevenZip.extract(archive("unicode-filename.7z").path, output.path, null, {}, { false })
        assertEquals(listOf("图像🔐.png"), paths)
        assertImage(output, paths.single(), fixture("unicode-filename.7z").getJSONObject("expected_images").getJSONObject(paths.single()))
        expectFailure("unicode-password.7z", "密码wrong", PasswordRequiredException::class.java)
        val retried = destination()
        val names = NativeSevenZip.extract(archive("unicode-password.7z").path, retried.path, "密码🔐café", {}, { false })
        val expected = manifest.getJSONObject("expected_images")
        names.forEach { assertImage(retried, it, expected.getJSONObject(it)) }
    }

    @Test fun wrongPasswordCanBeRetriedAndWhitespaceIsSignificant() {
        for (name in listOf("headers-lzma-solid.7z", "content-lzma2-solid.7z")) {
            expectFailure(name, null, PasswordRequiredException::class.java)
            expectFailure(name, "wrong", PasswordRequiredException::class.java)
            val output = destination()
            val names = NativeSevenZip.extract(archive(name).path, output.path, "test-password", {}, { false })
            assertEquals(3, names.size)
            names.forEach { assertImage(output, it, manifest.getJSONObject("expected_images").getJSONObject(it)) }
        }
        expectFailure("whitespace-password.7z", "padded password", PasswordRequiredException::class.java)
        assertEquals(3, NativeSevenZip.extract(archive("whitespace-password.7z").path, destination().path,
            "  padded password  ", {}, { false }).size)
    }

    @Test fun traversalCollisionCorruptAndEmptyArchivesRejectAndCleanUp() {
        for (name in listOf("unsafe-traversal.7z", "case-collision.7z", "no-images.7z", "truncated.7z", "plain.zip")) expectFailure(name, null)
        expectFailure("damaged-content.7z", "test-password")
        assertFalse("No traversal output created", File(root, "escape.png").exists())
    }

    @Test fun cancellationWhileDecoderHasWrittenPartialImageRemovesAllOutput() {
        val input = archive("cancellation.7z")
        val totalSize = fixture("cancellation.7z").getLong("uncompressed_size")
        repeat(2) {
            val output = destination()
            val observedPartialOutput = AtomicBoolean(false)
            val error = runCatching {
                NativeSevenZip.extract(input.path, output.path, null, {}, {
                    val written = File(output, "large.png").length()
                    if (written in 1 until totalSize) observedPartialOutput.set(true)
                    observedPartialOutput.get()
                })
            }.exceptionOrNull()
            assertTrue("Observed native output while decoding", observedPartialOutput.get())
            assertTrue("Actual decoding cancelled: $error", error is InterruptedIOException)
            assertFalse("Cancelled output removed", output.exists())
        }
    }

    @Test fun cancellationBeforeOpenPreservesUnownedDirectoryAndCallbackErrorsPropagate() {
        val output = destination().apply { mkdirs() }
        val sentinel = File(output, "keep.txt").apply { writeText("preserve") }
        val cancelled = runCatching { NativeSevenZip.extract(archive("plain-lzma-solid.7z").path,
            output.path, null, {}, { true }) }.exceptionOrNull()
        assertTrue(cancelled is InterruptedIOException)
        assertEquals("preserve", sentinel.readText())
        val callbackError = IllegalStateException("Test callback failure")
        val staged = destination()
        val error = runCatching { NativeSevenZip.extract(archive("cancellation.7z").path,
            staged.path, null, { throw callbackError }, { false }) }.exceptionOrNull()
        assertSame("Monitor exception rethrown on caller", callbackError, error)
        assertFalse(staged.exists())
    }
}
