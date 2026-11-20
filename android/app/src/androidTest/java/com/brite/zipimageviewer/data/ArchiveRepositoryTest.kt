package com.brite.zipimageviewer.data

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/** Exercises the actual Android resolver, native decoder, image validation and durable storage. */
@RunWith(AndroidJUnit4::class)
class ArchiveRepositoryTest {
    private lateinit var context: IsolatedContext
    private lateinit var repository: ArchiveRepository
    private lateinit var sources: File
    private val testAssets get() = InstrumentationRegistry.getInstrumentation().context.assets

    @Before fun setUp() {
        context = IsolatedContext(InstrumentationRegistry.getInstrumentation().targetContext)
        sources = File(context.filesDir, "test-sources").apply { mkdirs() }
        repository = ArchiveRepository(context)
    }

    @After fun tearDown() = runBlocking {
        // This suite owns only its randomly named app-private directory and preference namespace.
        context.filesDir.deleteRecursively()
        context.deleteTestPreferences()
    }

    @Test fun plainZipAndCbzMatchGoldenPagesAndNeverModifySource() = runBlocking {
        for (name in listOf("plain.zip", "plain.cbz")) {
            val source = fixture(name)
            val before = sha256(source)
            val record = repository.importArchive(Uri.fromFile(source))
            assertEquals("zip", record.format)
            assertEquals(name, record.title)
            assertEquals(3, record.pages.size)
            verifyGoldenPages(record)
            assertEquals(before, sha256(source))
            assertEquals(before, record.sourceDigest)
            repository.closeArchive(record.id)
            repository.remove(record.id)
        }
    }

    @Test fun encryptedZipAndCbzRetryWrongPasswordsWithoutRetainingPartialImages() = runBlocking {
        for (name in listOf("encrypted.zip", "encrypted.cbz")) {
            val source = fixture(name)
            val before = sha256(source)
            expectPassword { repository.importArchive(Uri.fromFile(source)) }
            expectPassword { repository.importArchive(Uri.fromFile(source), "wrong-password") }
            assertTrue(repository.archives.value.isEmpty())
            assertStagingEmpty()
            val record = repository.importArchive(Uri.fromFile(source), "test-password")
            verifyGoldenPages(record)
            assertEquals(before, sha256(source))
            repository.closeArchive(record.id)
            repository.remove(record.id)
        }
    }

    @Test fun providerPasswordRetriesUseOneDownloadEvenWhenSourceGoesOffline() = runBlocking {
        for ((name, password) in listOf("encrypted.zip" to "test-password", "unicode-password.7z" to "密码🔐café")) {
            val authority = InstrumentationRegistry.getInstrumentation().context.packageName + ".import-fixtures"
            val uri = Uri.parse("content://$authority/${UUID.randomUUID()}/$name")
            val session = repository.newImportSession(uri)
            expectPassword { repository.importSession(session) }
            val staged = File(context.filesDir, "archive-library/staging").listFiles()!!.single()
            assertTrue(File(staged, "source.archive").isFile)
            assertFalse(File(staged, "images").exists())
            context.contentResolver.call(uri, "revoke", uri.toString(), null)
            expectPassword { repository.importSession(session, "wrong") }
            assertFalse(File(staged, "images").exists())
            val record = repository.importSession(session, password)
            verifyGoldenPages(record)
            assertEquals(1, context.contentResolver.call(uri, "count", uri.toString(), null)!!.getInt("opens"))
            assertStagingEmpty()
            repository.closeArchive(record.id)
            repository.remove(record.id)
        }
    }

    @Test fun providerPermissionFailureExplainsRecoveryAndCleansStaging() = runBlocking {
        val authority = InstrumentationRegistry.getInstrumentation().context.packageName + ".import-fixtures"
        val uri = Uri.parse("content://$authority/denied/plain.zip")
        try {
            repository.importArchive(uri)
            fail("Expected permission failure")
        } catch (error: ImportFailure) {
            assertTrue(error.message!!.contains("Select the archive again or try another file app"))
        }
        assertStagingEmpty()
        assertTrue(repository.archives.value.isEmpty())
    }

    @Test fun dismissingPasswordDiscardsStagedSourceAndPreventsReuse() = runBlocking {
        val source = fixture("encrypted.zip")
        val session = repository.newImportSession(Uri.fromFile(source))
        expectPassword { repository.importSession(session) }
        repository.closeImportSession(session)
        repository.awaitIdle()
        assertStagingEmpty()
        assertTrue(source.isFile)
        try { repository.importSession(session, "test-password"); fail("Closed session cannot be reused") }
        catch (_: CancellationException) { }
    }

    @Test fun startupRemovesAbandonedPasswordSessions() = runBlocking {
        val session = repository.newImportSession(Uri.fromFile(fixture("encrypted.zip")))
        expectPassword { repository.importSession(session) }
        ArchiveRepository(context).load()
        assertStagingEmpty()
        assertTrue(repository.archives.value.isEmpty())
    }

    @Test fun cancellationWhileCopyingProviderSourceRemovesSession() = runBlocking {
        val authority = InstrumentationRegistry.getInstrumentation().context.packageName + ".import-fixtures"
        val uri = Uri.parse("content://$authority/${UUID.randomUUID()}/plain.zip")
        val session = repository.newImportSession(uri)
        lateinit var task: Deferred<ArchiveRecord>
        task = async(start = CoroutineStart.LAZY) {
            repository.importSession(session) { stage, _ -> if (stage.startsWith("Copying archive")) task.cancel() }
        }
        task.start()
        try { task.await(); fail("Expected cancellation") } catch (_: CancellationException) { }
        assertStagingEmpty()
        assertTrue(repository.archives.value.isEmpty())
    }

    @Test fun unicodeAndWhitespaceSevenZipPasswordsPreserveExactCharacters() = runBlocking {
        for ((name, password) in listOf("unicode-password.7z" to "密码🔐café", "whitespace-password.7z" to "  padded password  ")) {
            val source = fixture(name)
            expectPassword { repository.importArchive(Uri.fromFile(source), if (name.startsWith("whitespace")) password.trim() else "wrong") }
            val record = repository.importArchive(Uri.fromFile(source), password)
            assertEquals("7z", record.format)
            verifyGoldenPages(record)
            assertEquals(sha256(source), record.sourceDigest)
            assertTrue(record.pages.all { it.modifiedAt != null })
            repository.closeArchive(record.id)
        }
    }

    @Test fun freshRepositoryRestoresReadingPathAndReopensAfterSourceDeletion() = runBlocking {
        val source = fixture("plain.zip")
        val record = repository.importArchive(Uri.fromFile(source))
        val selected = record.pages.last().originalPath
        repository.updateProgress(record.id, selected)
        repository.closeArchive(record.id)
        assertTrue(source.delete())

        val reopenedRepository = ArchiveRepository(context)
        reopenedRepository.load()
        val reopened = reopenedRepository.openArchive(record.id)
        assertEquals(selected, reopened.currentPagePath)
        assertEquals(3, reopened.pages.size)
        assertTrue(reopened.pages.all { reopenedRepository.pageFile(reopened, it).isFile })
        assertFalse(source.exists())
        reopenedRepository.closeArchive(reopened.id)
    }

    @Test fun sameSourceAndDigestReusesCacheButDifferentSourceOrChangedContentCreatesSeparateRecord() = runBlocking {
        val source = fixture("plain.zip")
        val first = repository.importArchive(Uri.fromFile(source))
        repository.updateProgress(first.id, first.pages.last().originalPath)
        repository.closeArchive(first.id)
        val duplicate = File(sources, "renamed.cbz").also { source.copyTo(it) }
        val second = repository.importArchive(Uri.fromFile(source))
        assertEquals(first.id, second.id)
        assertEquals(first.pages.last().originalPath, second.currentPagePath)
        assertEquals(1, repository.archives.value.size)
        assertEquals(1, File(context.filesDir, "archive-library/retained").listFiles()!!.size)
        repository.closeArchive(second.id)
        val separate = repository.importArchive(Uri.fromFile(duplicate))
        assertNotEquals(first.id, separate.id)
        assertEquals(first.sourceDigest, separate.sourceDigest)
        assertEquals(2, repository.archives.value.size)
        repository.closeArchive(separate.id)
        createZip("plain.zip", listOf("new.png" to validPng()))
        val changed = repository.importArchive(Uri.fromFile(source))
        assertNotEquals(first.id, changed.id)
        assertEquals(first.sourceIdentity, changed.sourceIdentity)
        assertNotEquals(first.sourceDigest, changed.sourceDigest)
        assertEquals(2, repository.archives.value.size)
        assertFalse(repository.archives.value.any { it.id == first.id })
        repository.closeArchive(changed.id)
    }

    @Test fun deletionHidesBookImmediatelyButKeepsLeasedPagesUntilReaderCloses() = runBlocking {
        val record = repository.importArchive(Uri.fromFile(fixture("plain.zip")))
        val file = repository.pageFile(record, record.pages.first())
        repository.remove(record.id)
        assertTrue(repository.archives.value.isEmpty())
        assertTrue("An active reader must keep its page files", file.isFile)
        repository.closeArchive(record.id)
        waitUntil { !file.exists() }
        val fresh = ArchiveRepository(context)
        fresh.load()
        assertTrue(fresh.archives.value.isEmpty())
    }

    @Test fun oversizedImportIsTemporaryAndDoesNotEvictRetainedLibrary() = runBlocking {
        val retained = repository.importArchive(Uri.fromFile(fixture("plain.zip")))
        // Retained reader is leased, so lowering the limit cannot remove its files.
        repository.setCacheBudget(1)
        val temporary = repository.importArchive(Uri.fromFile(fixture("plain-lzma-solid.7z")))
        assertTrue(temporary.isTemporary)
        assertEquals(2, repository.archives.value.size)
        assertTrue(repository.pageFile(retained, retained.pages.first()).isFile)
        val temporaryFile = repository.pageFile(temporary, temporary.pages.first())
        repository.closeArchive(temporary.id)
        waitUntil { !temporaryFile.exists() }
        assertEquals(listOf(retained.id), repository.archives.value.map { it.id })
        repository.closeArchive(retained.id)
        waitUntil { repository.archives.value.isEmpty() }
    }

    @Test fun cacheBudgetEvictsUnleasedBookAndKeepsMostRecentReader() = runBlocking {
        val oldest = repository.importArchive(Uri.fromFile(fixture("plain.zip")))
        repository.closeArchive(oldest.id)
        val newest = repository.importArchive(Uri.fromFile(fixture("plain-lzma-solid.7z")))
        repository.setCacheBudget(newest.bytes)
        waitUntil { repository.archives.value.map { it.id } == listOf(newest.id) }
        assertFalse(repository.pageFile(oldest, oldest.pages.first()).exists())
        assertTrue(repository.pageFile(newest, newest.pages.first()).exists())
        repository.closeArchive(newest.id)
    }

    @Test fun missingCachedImagesAreReportedUnavailableAndReimportRepairsThem() = runBlocking {
        val source = fixture("plain.zip")
        val record = repository.importArchive(Uri.fromFile(source))
        repository.updateProgress(record.id, record.pages.last().originalPath)
        repository.closeArchive(record.id)
        assertTrue(repository.pageFile(record, record.pages.first()).delete())
        val fresh = ArchiveRepository(context)
        fresh.load()
        assertFalse(fresh.archives.value.single().available)
        expectImportFailure { fresh.openArchive(record.id) }
        val repaired = fresh.importArchive(Uri.fromFile(source))
        assertTrue(repaired.available)
        assertEquals(record.pages.last().originalPath, repaired.currentPagePath)
        assertTrue(repaired.pages.all { fresh.pageFile(repaired, it).isFile })
        fresh.closeArchive(repaired.id)
    }

    @Test fun cancellationRemovesStagingAndPublishesNothing() = runBlocking {
        val source = fixture("cancellation.7z")
        val before = sha256(source)
        lateinit var task: Deferred<ArchiveRecord>
        task = async(start = CoroutineStart.LAZY) {
            repository.importArchive(Uri.fromFile(source), onProgress = { stage, _ ->
                if (stage == "Extracting images") task.cancel()
            })
        }
        task.start()
        try { task.await(); fail("Import should have been cancelled") } catch (_: CancellationException) { }
        assertTrue(repository.archives.value.isEmpty())
        assertStagingEmpty()
        assertEquals(before, sha256(source))
    }

    @Test fun cancellationAtCommittedReturnReleasesTemporaryReaderLease() = runBlocking {
        repository.setCacheBudget(1)
        val source = fixture("plain.zip")
        lateinit var task: Deferred<ArchiveRecord>
        task = async(start = CoroutineStart.LAZY) {
            repository.importArchive(Uri.fromFile(source), onProgress = { stage, _ ->
                // Cancellation after the publication transaction must release the unreceived session.
                if (stage.startsWith("Ready")) task.cancel()
            })
        }
        task.start()
        try { task.await(); fail("Import should have been cancelled") } catch (_: CancellationException) { }
        waitUntil { repository.archives.value.isEmpty() && File(context.filesDir, "archive-library/temporary").listFiles().orEmpty().isEmpty() }
        assertStagingEmpty()
    }

    @Test fun cancellationAtOneShotCleanupReturnReleasesTemporaryReaderLease() = runBlocking {
        repository.setCacheBudget(1)
        val source = fixture("plain.zip")
        val dispatches = java.util.concurrent.atomic.AtomicInteger()
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        lateinit var task: Deferred<ArchiveRecord>
        val dispatcher = object : kotlinx.coroutines.CoroutineDispatcher() {
            override fun dispatch(context: kotlin.coroutines.CoroutineContext, block: Runnable) {
                // Dispatch 1 starts import; 2 receives importSession's leased record;
                // 3 returns from the one-shot wrapper's non-cancellable cleanup.
                if (dispatches.incrementAndGet() == 3) task.cancel()
                executor.execute(block)
            }
        }
        try {
            task = async(dispatcher, start = CoroutineStart.LAZY) { repository.importArchive(Uri.fromFile(source)) }
            task.start()
            try { task.await(); fail("Import should have been cancelled during cleanup return") }
            catch (_: CancellationException) { }
            assertEquals(3, dispatches.get())
            waitUntil { repository.archives.value.isEmpty() && File(context.filesDir, "archive-library/temporary").listFiles().orEmpty().isEmpty() }
            assertStagingEmpty()
        } finally { executor.shutdown() }
    }

    @Test fun maliciousZipPathsAndFilenameAliasesCannotEscapeOrPublish() = runBlocking {
        val png = validPng()
        val unsafe = listOf("../escape.png", "nested/../../escape.png", "/escape.png", "C:escape.png", "nested\\escape.png")
        for ((index, name) in unsafe.withIndex()) {
            val source = createZip("unsafe-$index.zip", listOf(name to png))
            expectImportFailure { repository.importArchive(Uri.fromFile(source)) }
            assertTrue(repository.archives.value.isEmpty())
            assertStagingEmpty()
        }
        val aliases = createZip("alias.zip", listOf("Panel.png" to png, "panel.PNG" to png))
        expectImportFailure { repository.importArchive(Uri.fromFile(aliases)) }
        assertTrue(repository.archives.value.isEmpty())
        assertFalse(File(context.filesDir, "escape.png").exists())
        assertFalse(File(context.filesDir, "archive-library/escape.png").exists())
    }

    @Test fun malformedImageRemainsNavigableAndHiddenJunkIsIgnored() = runBlocking {
        val damaged = createZip("broken.zip", listOf("page.jpg" to "Not an image".toByteArray()))
        val malformed = repository.importArchive(Uri.fromFile(damaged), compressImages = true)
        assertEquals("Not an image", repository.pageFile(malformed, malformed.pages.single()).readText())
        assertNull(malformed.pages.single().previewPath)
        assertNull(malformed.pages.single().processingPolicy)
        repository.closeArchive(malformed.id)
        assertStagingEmpty()
        val good = createZip("hidden.zip", listOf(".hidden/junk.jpg" to byteArrayOf(1), "page.png" to validPng()))
        val record = repository.importArchive(Uri.fromFile(good))
        assertEquals(listOf("page.png"), record.pages.map { it.originalPath })
        repository.closeArchive(record.id)
    }

    @Test fun clearRemovesAllCatalogEntriesAndDefersActivePageDeletion() = runBlocking {
        val first = repository.importArchive(Uri.fromFile(fixture("plain.zip")))
        val second = repository.importArchive(Uri.fromFile(fixture("plain-lzma-solid.7z")))
        repository.clear()
        assertTrue(repository.archives.value.isEmpty())
        assertTrue(repository.pageFile(first, first.pages.first()).exists())
        assertTrue(repository.pageFile(second, second.pages.first()).exists())
        repository.closeArchive(first.id)
        repository.closeArchive(second.id)
        waitUntil { !repository.pageFile(first, first.pages.first()).exists() && !repository.pageFile(second, second.pages.first()).exists() }
    }

    @Test fun countLimitPreviewListsExactVictimsWithoutDeletingAndApplyPersistsCount() = runBlocking {
        val records = importThreeArchives()
        records.forEach { repository.closeArchive(it.id) }
        awaitPreview(CacheLimits(1), records.size)
        val desired = CacheLimits(CachePolicy.DEFAULT_BUDGET, 1)
        val preview = awaitPreview(desired, 2)
        assertEquals(records.sortedWith(compareBy<ArchiveRecord> { it.lastOpened }.thenBy { it.id }).take(2).map { it.id },
            preview.candidates.map { it.id })
        assertEquals(preview.candidates.sumOf { it.bytes }, preview.reclaimedBytes)
        assertEquals(3, repository.archives.value.size)
        assertNull(repository.cacheLimits.maximumArchiveCount)
        val result = repository.applyCacheLimits(preview) as CacheLimitApplyResult.Applied
        assertEquals(preview.candidates.map { it.id }, result.removedIds)
        assertEquals(desired, result.limits)
        assertEquals(1, repository.archives.value.size)
        preview.candidates.forEach { assertFalse(repository.pageFile(it, it.pages.first()).exists()) }
        val reopened = ArchiveRepository(context)
        reopened.load()
        assertEquals(desired, reopened.cacheLimits)
        // The legacy byte-only API must not silently clear a configured count limit.
        reopened.setCacheBudget(4_000_000_000L)
        assertEquals(1, reopened.cacheLimits.maximumArchiveCount)
        val unlimited = reopened.previewCacheLimits(CacheLimits(4_000_000_000L))
        assertTrue(reopened.applyCacheLimits(unlimited) is CacheLimitApplyResult.Applied)
        assertNull(ArchiveRepository(context).cacheLimits.maximumArchiveCount)
    }

    @Test fun changedReaderLeaseRequiresFreshConfirmationAndProtectsOpenedBook() = runBlocking {
        val records = importThreeArchives()
        records.forEach { repository.closeArchive(it.id) }
        awaitPreview(CacheLimits(1), records.size)
        val preview = awaitPreview(CacheLimits(CachePolicy.DEFAULT_BUDGET, 1), 2)
        val protected = repository.openArchive(preview.candidates.first().id)
        val staleResult = repository.applyCacheLimits(preview) as CacheLimitApplyResult.NeedsConfirmation
        assertEquals(3, repository.archives.value.size)
        assertNull(repository.cacheLimits.maximumArchiveCount)
        assertFalse(staleResult.preview.candidates.any { it.id == protected.id })
        assertEquals(2, staleResult.preview.candidates.size)
        assertTrue(repository.applyCacheLimits(staleResult.preview) is CacheLimitApplyResult.Applied)
        assertEquals(listOf(protected.id), repository.archives.value.map { it.id })
        assertTrue(repository.pageFile(protected, protected.pages.first()).isFile)
        repository.closeArchive(protected.id)
    }

    @Test fun releasingLeaseAfterPreviewRequiresConfirmationBeforeNewlyEligibleDeletion() = runBlocking {
        val records = importThreeArchives()
        val desired = CacheLimits(CachePolicy.DEFAULT_BUDGET, 1)
        val preview = repository.previewCacheLimits(desired)
        assertTrue(preview.candidates.isEmpty())
        repository.closeArchive(records.first().id)
        awaitPreview(desired, 1)
        val staleResult = repository.applyCacheLimits(preview) as CacheLimitApplyResult.NeedsConfirmation
        assertEquals(listOf(records.first().id), staleResult.preview.candidates.map { it.id })
        assertEquals(3, repository.archives.value.size)
        assertTrue(repository.applyCacheLimits(staleResult.preview) is CacheLimitApplyResult.Applied)
        assertEquals(2, repository.archives.value.size) // Leased books may temporarily exceed count limit.
        records.drop(1).forEach { repository.closeArchive(it.id) }
        waitUntil { repository.archives.value.size == 1 }
    }

    @Test fun newImportAndCombinedLimitsInvalidateOldPreviewBeforeAnyDeletion() = runBlocking {
        val first = repository.importArchive(Uri.fromFile(fixture("plain.zip")))
        val second = repository.importArchive(Uri.fromFile(fixture("plain-lzma-solid.7z")))
        repository.closeArchive(first.id)
        repository.closeArchive(second.id)
        awaitPreview(CacheLimits(1), 2)
        val desired = CacheLimits(first.bytes, 2)
        val preview = awaitPreview(desired, 1)
        val newest = repository.importArchive(Uri.fromFile(fixture("plain-lzma2-nonsolid.7z")))
        val staleResult = repository.applyCacheLimits(preview) as CacheLimitApplyResult.NeedsConfirmation
        assertEquals(3, repository.archives.value.size)
        assertEquals(CacheLimits(), repository.cacheLimits)
        assertEquals(setOf(first.id, second.id), staleResult.preview.candidates.map { it.id }.toSet())
        val result = repository.applyCacheLimits(staleResult.preview) as CacheLimitApplyResult.Applied
        assertEquals(2, result.removedIds.size)
        assertEquals(listOf(newest.id), repository.archives.value.map { it.id })
        repository.closeArchive(newest.id)
    }

    @Test fun previewFromDifferentRepositoryCannotBeAppliedWithoutFreshConfirmation() = runBlocking {
        repository.load()
        val preview = repository.previewCacheLimits(CacheLimits(CachePolicy.DEFAULT_BUDGET, 5))
        val fresh = ArchiveRepository(context)
        fresh.load()
        val result = fresh.applyCacheLimits(preview) as CacheLimitApplyResult.NeedsConfirmation
        assertEquals(CacheLimits(), fresh.cacheLimits)
        assertTrue(fresh.applyCacheLimits(result.preview) is CacheLimitApplyResult.Applied)
        assertEquals(5, fresh.cacheLimits.maximumArchiveCount)
    }

    @Test fun previewsPersistWhenCompressionOffAndMissingPreviewFallsBackToDetail() = runBlocking {
        val source = fixture("plain.zip")
        val record = repository.importArchive(Uri.fromFile(source), compressImages = false)
        verifyGoldenPages(record)
        assertTrue(record.pages.all { it.previewPath != null && it.processingPolicy == null && it.originalPath == it.storedPath })
        assertTrue(record.pages.all { repository.previewFile(record, it)?.isFile == true })
        val folder = File(context.filesDir, "archive-library/retained/${record.storageDirectory}")
        assertEquals(ArchiveDiskUsage.directoryBytes(folder), record.bytes)
        assertTrue(record.bytes > record.pages.sumOf { repository.pageFile(record, it).length() })
        assertTrue(repository.previewFile(record, record.pages.first())!!.delete())
        val fresh = ArchiveRepository(context)
        fresh.load()
        val reopened = fresh.openArchive(record.id)
        assertNull(fresh.previewFile(reopened, reopened.pages.first()))
        assertTrue(reopened.available)
        fresh.closeArchive(reopened.id)
        repository.closeArchive(record.id)
    }

    @Test fun originalCreationDateSurvivesImportAndRestartWithoutInventedModificationDate() = runBlocking {
        val record = repository.importArchive(Uri.fromFile(fixture("creation-only.7z")))
        assertEquals(1577836800000L, record.pages.single().createdAt)
        assertNull(record.pages.single().modifiedAt)
        repository.closeArchive(record.id)
        val fresh = ArchiveRepository(context)
        fresh.load()
        assertEquals(1577836800000L, fresh.archives.value.single().pages.single().createdAt)
        assertNull(fresh.archives.value.single().pages.single().modifiedAt)
    }

    @Test fun queuedImageWorkKeepsRemovedPagesUntilItsIdempotentRelease() = runBlocking {
        val record = repository.importArchive(Uri.fromFile(fixture("plain.zip")))
        val release = repository.retainImageWork(record.id)
        val file = repository.pageFile(record, record.pages.first())
        repository.remove(record.id)
        repository.closeArchive(record.id)
        delay(100)
        assertTrue(file.exists())
        release(); release()
        waitUntil { !file.exists() }
    }

    @Test fun legacyCatalogMapsOriginalPathsAndUnsafePreviewCannotBeLoaded() = runBlocking {
        val record = repository.importArchive(Uri.fromFile(fixture("plain.zip")))
        repository.closeArchive(record.id)
        val catalog = File(context.filesDir, "archive-library/catalog.json")
        val json = JSONObject(catalog.readText()).put("version", 1)
        val item = json.getJSONArray("archives").getJSONObject(0)
        item.remove("accessSequence")
        val pages = item.getJSONArray("pages")
        for (i in 0 until pages.length()) { pages.getJSONObject(i).remove("previewPath"); pages.getJSONObject(i).remove("processingPolicy") }
        catalog.writeText(json.toString())
        val fresh = ArchiveRepository(context)
        fresh.load()
        assertTrue(fresh.archives.value.single().pages.all { it.previewPath == null && it.processingPolicy == null && it.originalPath == it.storedPath })
        val malicious = JSONObject(catalog.readText())
        malicious.getJSONArray("archives").getJSONObject(0).getJSONArray("pages").getJSONObject(0).put("previewPath", "../escape.jpg")
        catalog.writeText(malicious.toString())
        expectImportFailure { ArchiveRepository(context).load() }
    }

    @Test fun convertedAndUnconvertedPagesReopenWithOriginalProgressAndPersistentPreviews() = runBlocking {
        val png = testAssets.open("codec-fixtures/pattern-rgba-p3.png").use { it.readBytes() }
        val source = createZip("mixed.zip", listOf("chapter/10.png" to png, "chapter/2.jpg" to "broken image".toByteArray()))
        val sourceHash = sha256(source)
        val record = repository.importArchive(Uri.fromFile(source), compressImages = true)
        val converted = record.pages.first { it.originalPath == "chapter/10.png" }
        val original = record.pages.first { it.originalPath == "chapter/2.jpg" }
        assertEquals(ImagePreparationPolicy.PNG_POLICY, converted.processingPolicy)
        assertTrue(converted.storedPath.endsWith(".jxl"))
        assertNotNull(repository.previewFile(record, converted))
        assertEquals(original.originalPath, original.storedPath)
        assertNull(original.processingPolicy)
        assertEquals(sourceHash, sha256(source))
        repository.updateProgress(record.id, converted.originalPath)
        repository.closeArchive(record.id)
        assertTrue(source.delete())
        val fresh = ArchiveRepository(context)
        fresh.load()
        val reopened = fresh.openArchive(record.id)
        assertEquals(converted.originalPath, reopened.currentPagePath)
        assertEquals(converted, reopened.pages.first { it.originalPath == converted.originalPath })
        assertTrue(fresh.pageFile(reopened, converted).isFile)
        assertNotNull(fresh.previewFile(reopened, converted))
        fresh.closeArchive(record.id)
    }

    @Test fun removedArchiveCanBeReimportedWithoutInvalidatingPriorImageWork() = runBlocking {
        val source = fixture("plain.zip")
        val old = repository.importArchive(Uri.fromFile(source))
        val release = repository.retainImageWork(old.id)
        val oldFile = repository.pageFile(old, old.pages.first())
        repository.remove(old.id)
        repository.closeArchive(old.id)
        val fresh = repository.importArchive(Uri.fromFile(source))
        val newFile = repository.pageFile(fresh, fresh.pages.first())
        assertEquals(old.id, fresh.id)
        assertNotEquals(old.storageDirectory, fresh.storageDirectory)
        assertTrue(oldFile.isFile)
        assertTrue(newFile.isFile)
        assertTrue(repository.pendingDeletionBytes.value > 0)
        release()
        repository.closeArchive(fresh.id)
        waitUntil { !oldFile.exists() }
        assertTrue(newFile.isFile)
        assertEquals(0L, repository.pendingDeletionBytes.value)
        assertEquals(1, repository.archives.value.size)
    }

    @Test fun cancelledImagePreparationLeavesNoPublishedPartialCache() = runBlocking {
        val source = fixture("plain.zip")
        lateinit var task: Deferred<ArchiveRecord>
        task = async(start = CoroutineStart.LAZY) {
            repository.importArchive(Uri.fromFile(source), compressImages = true, onProgress = { stage, progress ->
                if (stage == "Preparing and compressing images" && progress != null && progress > 0f) task.cancel()
            })
        }
        task.start()
        try { task.await(); fail("Expected cancellation after image preparation") } catch (_: CancellationException) { }
        assertTrue(repository.archives.value.isEmpty())
        assertStagingEmpty()
        assertTrue(File(context.filesDir, "archive-library/retained").listFiles().orEmpty().isEmpty())
    }

    @Test fun queuedProgressAndFinishAreFifoAndAwaitIdleIncludesOutstandingImageWork() = runBlocking {
        val record = repository.importArchive(Uri.fromFile(fixture("plain.zip")))
        val release = repository.retainImageWork(record.id)
        repeat(20) { repository.queueProgress(record.id, record.pages[it % record.pages.size].originalPath) }
        val finalPath = record.pages.last().originalPath
        repository.finishReader(record.id, finalPath)
        assertNull(kotlinx.coroutines.withTimeoutOrNull(100) { repository.awaitIdle(); true })
        release()
        kotlinx.coroutines.withTimeout(5000) { repository.awaitIdle() }
        val fresh = ArchiveRepository(context)
        fresh.load()
        assertEquals(finalPath, fresh.archives.value.single().currentPagePath)
    }

    @Test fun automaticEvictionHidesBookButRemembersPositionAndManualRemovalForgetsIt() = runBlocking {
        val source = fixture("plain.zip")
        val old = repository.importArchive(Uri.fromFile(source))
        val saved = old.pages.last().originalPath
        repository.finishReader(old.id, saved)
        repository.awaitIdle()
        val newest = repository.importArchive(Uri.fromFile(fixture("plain-lzma-solid.7z")))
        repository.closeArchive(newest.id)
        repository.awaitIdle()
        val preview = repository.previewCacheLimits(CacheLimits(CachePolicy.DEFAULT_BUDGET, 1))
        assertEquals(listOf(old.id), preview.candidates.map { it.id })
        assertTrue(repository.applyCacheLimits(preview) is CacheLimitApplyResult.Applied)
        assertEquals(listOf(newest.id), repository.archives.value.map { it.id })
        assertFalse(repository.pageFile(old, old.pages.first()).exists())
        val fresh = ArchiveRepository(context)
        fresh.load()
        val restored = fresh.importArchive(Uri.fromFile(source))
        assertEquals(saved, restored.currentPagePath)
        fresh.closeArchive(restored.id)
        fresh.awaitIdle()
        fresh.remove(restored.id)
        val forgotten = fresh.importArchive(Uri.fromFile(source))
        assertNull(forgotten.currentPagePath)
        fresh.closeArchive(forgotten.id)
    }

    @Test fun temporaryChangedSourceVersionPreservesRetainedPreviousVersion() = runBlocking {
        val source = fixture("plain.zip")
        val old = repository.importArchive(Uri.fromFile(source))
        repository.closeArchive(old.id)
        repository.awaitIdle()
        repository.setCacheBudget(old.bytes)
        val png = testAssets.open("codec-fixtures/pattern-rgba-p3.png").use { it.readBytes() }
        createZip("plain.zip", listOf("large.png" to png))
        val temporary = repository.importArchive(Uri.fromFile(source), compressImages = false)
        assertTrue(temporary.isTemporary)
        assertNotEquals(old.id, temporary.id)
        assertEquals(setOf(old.id, temporary.id), repository.archives.value.map { it.id }.toSet())
        assertTrue(repository.pageFile(old, old.pages.first()).isFile)
        repository.closeArchive(temporary.id)
        repository.awaitIdle()
        assertEquals(listOf(old.id), repository.archives.value.map { it.id })
    }

    private suspend fun importThreeArchives(): List<ArchiveRecord> = listOf("plain.zip", "plain-lzma-solid.7z", "plain-lzma2-nonsolid.7z")
        .map { repository.importArchive(Uri.fromFile(fixture(it))) }

    private suspend fun awaitPreview(limits: CacheLimits, candidateCount: Int): CacheLimitPreview {
        repeat(100) {
            val preview = repository.previewCacheLimits(limits)
            if (preview.candidates.size == candidateCount) return preview
            delay(25)
        }
        error("Repository leases did not settle to the expected eviction preview")
    }

    private fun fixture(name: String): File = File(sources, name).also { file ->
        testAssets.open("archive-fixtures/$name").use { input -> file.outputStream().use { input.copyTo(it) } }
    }

    private fun verifyGoldenPages(record: ArchiveRecord) {
        val manifest = JSONObject(testAssets.open("archive-fixtures/manifest.json").bufferedReader().use { it.readText() })
        val golden = manifest.getJSONObject("expected_images")
        assertEquals(golden.length(), record.pages.size)
        record.pages.forEach {
            val expected = golden.getJSONObject(it.originalPath)
            val file = repository.pageFile(record, it)
            assertEquals(expected.getLong("size"), file.length())
            assertEquals(expected.getString("sha256"), sha256(file))
        }
    }

    private fun validPng(): ByteArray {
        ZipInputStream(testAssets.open("archive-fixtures/plain.zip")).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: error("Fixture PNG missing")
                if (entry.name == "panel.png") return zip.readBytes()
            }
        }
    }

    private fun createZip(name: String, files: List<Pair<String, ByteArray>>): File = File(sources, name).also { output ->
        ZipOutputStream(output.outputStream()).use { zip ->
            files.forEach { (path, content) ->
                zip.putNextEntry(ZipEntry(path)); zip.write(content); zip.closeEntry()
            }
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(8192)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private suspend fun expectPassword(block: suspend () -> Unit) {
        try { block(); fail("Expected password request") } catch (_: PasswordRequiredException) { }
    }

    private suspend fun expectImportFailure(block: suspend () -> Unit) {
        try { block(); fail("Expected import failure") } catch (_: ImportFailure) { }
    }

    private fun assertStagingEmpty() {
        assertEquals(0, File(context.filesDir, "archive-library/staging").listFiles().orEmpty().size)
    }

    private suspend fun waitUntil(predicate: () -> Boolean) {
        repeat(100) { if (predicate()) return; delay(25) }
        assertTrue("Asynchronous repository cleanup did not complete", predicate())
    }

    private class IsolatedContext(private val target: Context) : ContextWrapper(target) {
        private val token = UUID.randomUUID().toString()
        private val directory = File(target.filesDir, "repository-test-$token").apply { mkdirs() }
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = directory
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
            target.getSharedPreferences("repository-test-$token-$name", mode)
        fun deleteTestPreferences() { target.deleteSharedPreferences("repository-test-$token-archive-repository") }
    }
}
