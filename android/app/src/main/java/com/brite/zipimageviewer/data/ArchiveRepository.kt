package com.brite.zipimageviewer.data

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.os.CancellationSignal
import android.content.res.AssetFileDescriptor
import android.text.format.Formatter
import android.util.AtomicFile
import com.brite.zipimageviewer.nativebridge.NativeSevenZip
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.channels.Channel
import net.lingala.zip4j.ZipFile
import net.lingala.zip4j.exception.ZipException
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InterruptedIOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.coroutineContext

/** All import work is private to a staging directory until the durable catalog commits. */
class ArchiveRepository(context: Context) {
    private val appContext = context.applicationContext
    private val root = File(appContext.filesDir, "archive-library")
    private val retained = File(root, "retained")
    private val temporary = File(root, "temporary")
    private val staging = File(root, "staging")
    private val catalog = AtomicFile(File(root, "catalog.json"))
    private val preferences = appContext.getSharedPreferences("archive-repository", Context.MODE_PRIVATE)
    private val mutex = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private data class ProgressCommit(val id: String, val path: String?, val finish: Boolean)
    private val commitQueue = Channel<ProgressCommit>(Channel.UNLIMITED)
    private val pendingCommits = AtomicInteger()
    private val pendingClosures = AtomicInteger()
    private val mutableArchives = MutableStateFlow<List<ArchiveRecord>>(emptyList())
    @Volatile private var catalogRecords: List<ArchiveRecord> = emptyList()
    val archives: StateFlow<List<ArchiveRecord>> = mutableArchives.asStateFlow()
    private val mutableStorageWarning = MutableStateFlow<String?>(null)
    val storageWarning: StateFlow<String?> = mutableStorageWarning.asStateFlow()
    private val leases = mutableMapOf<String, Int>()
    private val leaseLock = Any()
    private val pendingDelete = mutableMapOf<String, MutableList<File>>()
    private val mutablePendingDeletionBytes = MutableStateFlow(0L)
    val pendingDeletionBytes: StateFlow<Long> = mutablePendingDeletionBytes.asStateFlow()
    private val limits = ExtractionLimits()
    private var loaded = false
    private val repositoryToken = UUID.randomUUID().toString()
    private val stateRevision = AtomicLong()
    private var accessSequence = 0L
    var cacheBudget: Long = preferences.getLong("cache-budget", CachePolicy.DEFAULT_BUDGET).coerceAtLeast(1L)
        private set
    var maximumArchiveCount: Int? = preferences.getInt("cache-count", 0).takeIf { it > 0 }
        private set
    val cacheLimits: CacheLimits get() = CacheLimits(cacheBudget, maximumArchiveCount)

    init {
        scope.launch {
            for (commit in commitQueue) {
                try {
                    commit.path?.let { updateProgress(commit.id, it) }
                } catch (error: Exception) {
                    mutableStorageWarning.value = error.message ?: "The latest reading position could not be saved."
                } finally {
                    if (commit.finish) closeArchive(commit.id)
                    pendingCommits.decrementAndGet()
                }
            }
        }
    }

    suspend fun load() = withContext(Dispatchers.IO) { mutex.withLock { loadLocked() } }

    /** Test shutdown boundary: callers must first close their UI sessions and cancel submitted work. */
    internal suspend fun awaitIdle() {
        while (true) {
            val idle = mutex.withLock { synchronized(leaseLock) { leases.isEmpty() && pendingCommits.get() == 0 && pendingClosures.get() == 0 } }
            if (idle) return
            delay(10)
        }
    }

    /** FIFO publication survives UI detachment or React module invalidation. */
    fun queueProgress(id: String, path: String) = enqueueProgress(ProgressCommit(id, path, false))

    /** Queue the final original page identity before releasing this reader's lease, exactly once. */
    fun finishReader(id: String, lastPath: String?) = enqueueProgress(ProgressCommit(id, lastPath, true))

    private fun enqueueProgress(commit: ProgressCommit) {
        pendingCommits.incrementAndGet()
        if (commitQueue.trySend(commit).isFailure) {
            pendingCommits.decrementAndGet()
            mutableStorageWarning.value = "Reading position updates could not be queued."
            if (commit.finish) closeArchive(commit.id)
        }
    }

    private fun loadLocked() {
        if (loaded) return
        listOf(root, retained, temporary, staging).forEach { ensureDirectory(it) }
        staging.listFiles()?.forEach(::deleteRequired)
        temporary.listFiles()?.forEach(::deleteRequired)
        val records = try {
            if (catalog.baseFile.exists() || File(catalog.baseFile.path + ".bak").exists()) {
                catalog.openRead().bufferedReader().use { parseCatalog(it.readText()) }
            } else emptyList()
        } catch (error: ImportFailure) {
            throw error
        } catch (_: Exception) {
            // Individual manifests allow recovery after catalog damage without touching sources.
            retained.listFiles().orEmpty().mapNotNull { folder ->
                runCatching { decodeRecord(JSONObject(File(folder, "manifest.json").readText())) }.getOrNull()
            }
        }.filter { !it.isTemporary }.distinctBy { it.id }.map { record ->
            val available = record.available && record.pages.isNotEmpty() && record.pages.all {
                runCatching { ArchiveDiskUsage.requireRegularFile(pageFile(record, it)); true }.getOrDefault(false)
            }
            val folder = archiveDirectory(record)
            if (!available) {
                // Retain unavailable metadata, but reclaim the partial images just as iOS recovery does.
                if (folder.exists()) runCatching { deleteRequired(folder) }.onFailure {
                    pendingDelete.getOrPut(record.id) { mutableListOf() }.add(folder)
                }
                record.copy(available = false, bytes = 0)
            } else record.copy(available = true, bytes = ArchiveDiskUsage.directoryBytes(folder))
        }
        refreshPendingBytes()
        // Crash leftovers never become visible partially imported books.
        val known = records.map { it.storageDirectory }.toSet()
        retained.listFiles()?.filter { it.name !in known }?.forEach(::deleteRequired)
        accessSequence = records.maxOfOrNull { it.accessSequence } ?: 0
        val sequenced = records.sortedWith(compareBy<ArchiveRecord> { it.lastOpened }.thenBy { it.id }).map {
            if (it.accessSequence == 0L) it.copy(accessSequence = nextAccessSequence()) else it
        }
        persist(sequenced)
        publish(sequenced)
        loaded = true
        evictLocked()
    }

    /** Owned by the caller until success, terminal failure, or explicit dismissal. */
    fun newImportSession(uri: Uri, compressImages: Boolean = false) =
        ArchiveImportSession(repositoryToken, uri, compressImages, File(staging, UUID.randomUUID().toString()))

    /** Safe from onCleared/disposal; active work observes closure before publication. */
    fun closeImportSession(session: ArchiveImportSession) {
        require(session.repositoryToken == repositoryToken)
        session.closed.set(true)
        pendingClosures.incrementAndGet()
        scope.launch {
            try { mutex.withLock { cleanupSession(session) } }
            finally { pendingClosures.decrementAndGet() }
        }
    }

    private fun cleanupSession(session: ArchiveImportSession) {
        runCatching { deleteRequired(session.directory) }.onFailure { mutableStorageWarning.value = it.message }
    }

    /** One-shot convenience API. Interactive password entry should reuse an import session. */
    suspend fun importArchive(
        uri: Uri,
        password: String? = null,
        compressImages: Boolean = false,
        onProgress: (String, Float?) -> Unit = { _, _ -> },
    ): ArchiveRecord {
        val session = newImportSession(uri, compressImages)
        var acquiredId: String? = null
        try {
            try { return importSession(session, password, onProgress).also { acquiredId = it.id } }
            finally {
                session.closed.set(true)
                withContext(NonCancellable + Dispatchers.IO) { mutex.withLock { cleanupSession(session) } }
            }
        } catch (cancelled: CancellationException) {
            // Cleanup can suspend after importSession delivered its reader lease.
            // If that return is cancelled, the caller never receives ownership.
            acquiredId?.let(::closeArchive)
            throw cancelled
        }
    }

    suspend fun importSession(
        session: ArchiveImportSession,
        password: String? = null,
        onProgress: (String, Float?) -> Unit = { _, _ -> },
    ): ArchiveRecord = acquireArchive {
        mutex.withLock {
            require(session.repositoryToken == repositoryToken)
            loadLocked()
            val jobContext = coroutineContext
            fun checkActive() {
                jobContext.ensureActive()
                if (session.closed.get()) throw CancellationException("The import session was closed.")
            }
            checkActive()
            val source = File(session.directory, "source.archive")
            val images = File(session.directory, "images")
            val compressImages = session.compressImages
            var promoted: File? = null
            var committed = false
            var awaitingPassword = false
            try {
                ensureDirectory(session.directory)
                // An incorrect password may have produced some images; never mix extraction attempts.
                deleteRequired(images)
                ensureDirectory(images)
                val prepared = session.prepared ?: copySource(session, source, onProgress).also { session.prepared = it }
                checkActive()
                val sourceDigest = prepared.digest
                val sourceIdentity = java.net.URI(session.uri.normalizeScheme().toString()).normalize().toString()
                val id = MessageDigest.getInstance("SHA-256").digest("$sourceIdentity|$sourceDigest".toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
                catalogRecords.firstOrNull { it.available &&
                    ((it.sourceIdentity == sourceIdentity && it.sourceDigest == sourceDigest) ||
                        (it.sourceIdentity == null && it.id == sourceDigest)) }?.let { existing ->
                    checkActive()
                    val touched = touchLocked(existing.copy(sourceIdentity = sourceIdentity, sourceDigest = sourceDigest))
                    retainLeaseLocked(existing.id)
                    return@withLock touched
                }
                val format = detectFormat(source)
                onProgress("Extracting images", 0f)
                val extractedPages = if (format == "7z") {
                    val names = try {
                        NativeSevenZip.extractDetailed(source.absolutePath, images.absolutePath, password,
                            { onProgress("Extracting images", it.coerceIn(0f, 1f)) },
                            { session.closed.get() || !jobContext[kotlinx.coroutines.Job]!!.isActive })
                    } catch (error: com.brite.zipimageviewer.nativebridge.PasswordRequiredException) {
                        throw PasswordRequiredException(cause = error)
                    } catch (error: InterruptedIOException) {
                        checkActive()
                        throw ImportFailure("Archive extraction was interrupted.", error)
                    }
                    val policy = ArchiveOutputPolicy(images, limits)
                    names.map { entry ->
                        val path = entry.path
                        checkActive()
                        val file = ArchiveOutputPolicy.containedFile(images, path)
                        policy.reserve(path, file.length())
                        ArchiveDiskUsage.requireRegularFile(file)
                        // The native SDK flushes stdio and preserves archive modification dates.
                        // Sync without writing so publication does not race buffered image data.
                        FileOutputStream(file, true).use { it.fd.sync() }
                        PageRecord(path, path, entry.modifiedAt, entry.createdAt)
                    }
                } else extractZip(source, images, password, { checkActive() }, onProgress)
                checkActive()
                if (extractedPages.isEmpty()) throw ImportFailure("No supported images (.jpg, .jpeg, .png) were found in this archive.")
                onProgress(if (compressImages) "Preparing and compressing images" else "Preparing previews", 0f)
                val pages = ExtractedImageProcessor(appContext).prepare(images, extractedPages, compressImages,
                    { checkActive() }, { onProgress(if (compressImages) "Preparing and compressing images" else "Preparing previews", it) })
                checkActive()
                onProgress("Saving library", null)
                val restoredPath = catalogRecords.firstOrNull { it.id == id }?.currentPagePath?.takeIf { path -> pages.any { it.originalPath == path } }
                var record = ArchiveRecord(id, prepared.name, format, sortedPages(pages), System.currentTimeMillis(), restoredPath, 0,
                    accessSequence = nextAccessSequence(), storageDirectory = "$id-${UUID.randomUUID()}",
                    sourceIdentity = sourceIdentity, sourceDigest = sourceDigest)
                // Include auxiliary previews and the manifest itself in allocated-byte retention accounting.
                repeat(4) {
                    writeAtomic(File(images, "manifest.json"), encodeRecord(record).toString())
                    val allocated = ArchiveDiskUsage.directoryBytes(images)
                    record = record.copy(bytes = allocated, isTemporary = allocated > cacheBudget)
                }
                writeAtomic(File(images, "manifest.json"), encodeRecord(record).toString())
                val isTemporary = record.isTemporary
                val destination = archiveDirectory(record)
                val previousRecords = catalogRecords.filter {
                    it.id == id || (!isTemporary && it.sourceIdentity == sourceIdentity)
                }
                checkActive()
                if (!images.renameTo(destination)) throw ImportFailure("The extracted images could not be saved.")
                promoted = destination
                val retiredIds = previousRecords.map { it.id }.toSet()
                val updated = catalogRecords.filter { it.id !in retiredIds } + record
                persist(updated)
                committed = true
                retainLeaseLocked(id)
                publish(updated)
                previousRecords.forEach { old -> runCatching { deferOrDelete(old.id, archiveDirectory(old)) }.onFailure { mutableStorageWarning.value = it.message } }
                runCatching { evictLocked() }.onFailure { mutableStorageWarning.value = it.message }
                onProgress(if (isTemporary) "Ready — temporary session" else "Ready", 1f)
                record
            } catch (error: CancellationException) {
                throw error
            } catch (error: PasswordRequiredException) {
                checkActive()
                awaitingPassword = true
                throw error
            } catch (error: ImportFailure) {
                throw error
            } catch (error: IOException) {
                throw ImportFailure(error.message ?: "The archive could not be imported. Check its format and available storage.", error)
            } finally {
                if (!committed) promoted?.deleteRecursively()
                if (awaitingPassword && !session.closed.get()) {
                    runCatching { deleteRequired(images) }.onFailure { mutableStorageWarning.value = it.message }
                } else {
                    session.closed.set(true)
                    cleanupSession(session)
                }
            }
        }
    }

    private fun extractZip(
        source: File, images: File, password: String?, checkCancellation: () -> Unit,
        onProgress: (String, Float?) -> Unit,
    ): List<PageRecord> {
        try {
            ZipMetadataAdmission.check(source, limits, checkCancellation)
            ZipFile(source).use { zip ->
                if (password != null) zip.setPassword(password.toCharArray())
                val headers = zip.fileHeaders
                if (headers.size > limits.maximumEntryCount) throw ImportFailure("The archive contains too many entries.")
                val selected = headers.filter { !it.isDirectory && ArchiveOutputPolicy.isSupportedImage(it.fileName) }
                if (selected.any { it.isEncrypted } && password == null) throw PasswordRequiredException()
                val policy = ArchiveOutputPolicy(images, limits)
                val destinations = selected.map { header ->
                    checkCancellation()
                    val attributes = header.externalFileAttributes
                    if (attributes != null && attributes.size >= 4) {
                        val mode = ((attributes[3].toInt() and 255) shl 8) or (attributes[2].toInt() and 255)
                        val kind = mode and 0xf000
                        if (kind != 0 && kind != 0x8000) throw ImportFailure("Links and special files are not supported: ${header.fileName}")
                    }
                    policy.reserve(header.fileName, header.uncompressedSize)
                }
                if (policy.totalBytes > images.usableSpace - limits.minimumFreeDiskBytes) throw ImportFailure("There is not enough free storage to extract this archive.")
                var extracted = 0L
                var lastNotification = 0L
                return selected.zip(destinations).map { (header, destination) ->
                    checkCancellation()
                    ensureDirectory(destination.parentFile!!)
                    var fileBytes = 0L
                    zip.getInputStream(header).use { input ->
                        FileOutputStream(destination).use { output ->
                            val buffer = ByteArray(128 * 1024)
                            while (true) {
                                checkCancellation()
                                val read = input.read(buffer)
                                if (read < 0) break
                                fileBytes += read
                                extracted += read
                                if (fileBytes > header.uncompressedSize || fileBytes > limits.maximumFileBytes || extracted > limits.maximumTotalBytes) {
                                    throw ImportFailure("An archive entry exceeds its declared extraction size.")
                                }
                                if (images.usableSpace < limits.minimumFreeDiskBytes + read) throw ImportFailure("Storage is full while extracting images.")
                                output.write(buffer, 0, read)
                                val now = System.currentTimeMillis()
                                if (now - lastNotification > 100) {
                                    onProgress("Extracting images", (extracted.toFloat() / policy.totalBytes.coerceAtLeast(1)).coerceIn(0f, 1f))
                                    lastNotification = now
                                }
                            }
                            output.fd.sync()
                        }
                    }
                    if (fileBytes != header.uncompressedSize) throw ImportFailure("An archive entry was truncated: ${header.fileName}")
                    ArchiveDiskUsage.requireRegularFile(destination)
                    ZipEntryMetadata.page(header)
                }
            }
        } catch (error: ZipException) {
            if (error.type == ZipException.Type.WRONG_PASSWORD) throw PasswordRequiredException(cause = error)
            throw ImportFailure("The ZIP archive is damaged or uses an unsupported method. ${error.message.orEmpty()}", error)
        }
    }

    fun pageFile(archive: ArchiveRecord, page: PageRecord): File {
        validateId(archive.id)
        return ArchiveOutputPolicy.containedFile(archiveDirectory(archive), page.storedPath)
    }

    fun previewFile(archive: ArchiveRecord, page: PageRecord): File? {
        val path = page.previewPath ?: return null
        validateId(archive.id)
        val file = ArchiveOutputPolicy.containedFile(archiveDirectory(archive), path)
        if (!file.exists()) return null
        ArchiveDiskUsage.requireRegularFile(file)
        return file
    }

    /** Retain before queueing work, and release after the running decoder really returns. */
    fun retainImageWork(id: String): () -> Unit {
        synchronized(leaseLock) {
            if (leases[id] == null && catalogRecords.none { it.id == id && it.available }) {
                throw ImportFailure("The image session has already closed.")
            }
            retainLeaseLocked(id)
        }
        val released = AtomicBoolean(false)
        return { if (released.compareAndSet(false, true)) closeArchive(id) }
    }

    suspend fun openArchive(id: String): ArchiveRecord = acquireArchive {
        mutex.withLock {
            loadLocked()
            val record = catalogRecords.firstOrNull { it.id == id && it.available }
                ?: throw ImportFailure("The cached copy is unavailable. Select the original archive again.")
            if (record.pages.any { !pageFile(record, it).isFile }) throw ImportFailure("The cached copy is incomplete. Select the original archive again.")
            touchLocked(record).also { retainLeaseLocked(id) }
        }
    }

    /** withContext can discard a successful worker result if its caller was cancelled meanwhile. */
    private suspend fun acquireArchive(block: suspend () -> ArchiveRecord): ArchiveRecord {
        var acquiredId: String? = null
        try {
            return withContext(Dispatchers.IO) { block().also { acquiredId = it.id } }
        } catch (cancelled: CancellationException) {
            acquiredId?.let(::closeArchive)
            throw cancelled
        }
    }

    suspend fun updateProgress(id: String, pagePath: String) = withContext(Dispatchers.IO) {
        mutex.withLock {
            loadLocked()
            val record = catalogRecords.firstOrNull { it.id == id } ?: return@withLock
            if (record.pages.none { it.originalPath == pagePath }) return@withLock
            if (record.currentPagePath == pagePath) return@withLock
            replaceLocked(record.copy(currentPagePath = pagePath, lastOpened = System.currentTimeMillis(), accessSequence = nextAccessSequence()))
        }
    }

    suspend fun remove(id: String) = withContext(Dispatchers.IO) {
        mutex.withLock {
            loadLocked()
            val record = catalogRecords.firstOrNull { it.id == id } ?: return@withLock
            val updated = catalogRecords.filter { it.id != id }
            persist(updated)
            publish(updated)
            deferOrDelete(id, archiveDirectory(record))
        }
    }

    suspend fun clear() = withContext(Dispatchers.IO) {
        mutex.withLock {
            loadLocked()
            val old = catalogRecords
            persist(emptyList())
            publish(emptyList())
            old.forEach {
                deferOrDelete(it.id, archiveDirectory(it))
            }
        }
    }

    /** Safe to invoke directly from a UI disposal callback. */
    fun closeArchive(id: String) {
        pendingClosures.incrementAndGet()
        scope.launch {
            try { mutex.withLock { synchronized(leaseLock) {
                stateRevision.incrementAndGet()
                val remaining = ((leases[id] ?: 1) - 1).coerceAtLeast(0)
                if (remaining > 0) {
                    leases[id] = remaining
                    return@withLock
                }
                leases.remove(id)
                pendingDelete.remove(id)?.forEach { folder ->
                    if (!folder.deleteRecursively()) {
                        pendingDelete.getOrPut(id) { mutableListOf() }.add(folder)
                        mutableStorageWarning.value = "Some removed cache files still occupy storage. Cleanup will be retried on the next launch."
                    }
                }
                val record = catalogRecords.firstOrNull { it.id == id && it.isTemporary }
                if (record != null) {
                    publish(catalogRecords.filter { it.id != id })
                    val folder = archiveDirectory(record)
                    if (!folder.deleteRecursively()) {
                        pendingDelete.getOrPut(id) { mutableListOf() }.add(folder)
                        mutableStorageWarning.value = "Temporary cache cleanup failed. Storage will be retried on the next launch."
                    }
                }
                refreshPendingBytes()
                runCatching { evictLocked() }.onFailure { mutableStorageWarning.value = it.message }
            } } } finally { pendingClosures.decrementAndGet() }
        }
    }

    suspend fun setCacheBudget(bytes: Long) = withContext(Dispatchers.IO) {
        mutex.withLock {
            loadLocked()
            saveLimitsLocked(CacheLimits(bytes, maximumArchiveCount))
            evictLocked()
        }
    }

    /** Reads exact candidates without changing limits or evicting for the proposed limits. */
    suspend fun previewCacheLimits(limits: CacheLimits): CacheLimitPreview = withContext(Dispatchers.IO) {
        mutex.withLock { loadLocked(); previewLimitsLocked(limits) }
    }

    /** No deletion or preference change occurs when a displayed preview has become stale. */
    suspend fun applyCacheLimits(preview: CacheLimitPreview): CacheLimitApplyResult = withContext(Dispatchers.IO) {
        mutex.withLock {
            loadLocked()
            synchronized(leaseLock) {
            val fresh = previewLimitsLocked(preview.limits)
            if (preview.repositoryToken != repositoryToken || preview.stateRevision != stateRevision.get() ||
                preview.candidates != fresh.candidates) {
                return@withLock CacheLimitApplyResult.NeedsConfirmation(fresh)
            }
            saveLimitsLocked(preview.limits)
            evictLocked()
            CacheLimitApplyResult.Applied(cacheLimits, fresh.candidates.map { it.id })
            }
        }
    }

    private fun previewLimitsLocked(limits: CacheLimits): CacheLimitPreview {
        val byId = catalogRecords.associateBy { it.id }
        val candidates = CachePolicy.evictionCandidates(catalogRecords, limits, synchronized(leaseLock) { leases.keys.toSet() }).map { byId.getValue(it) }
        return CacheLimitPreview(limits, candidates, repositoryToken, stateRevision.get())
    }

    private fun saveLimitsLocked(limits: CacheLimits) {
        val editor = preferences.edit().putLong("cache-budget", limits.maximumBytes)
        limits.maximumArchiveCount?.let { editor.putInt("cache-count", it) } ?: editor.remove("cache-count")
        if (!editor.commit()) throw ImportFailure("Cache settings could not be saved.")
        cacheBudget = limits.maximumBytes
        maximumArchiveCount = limits.maximumArchiveCount
        stateRevision.incrementAndGet()
    }

    private fun retainLeaseLocked(id: String) {
        synchronized(leaseLock) {
            leases[id] = (leases[id] ?: 0) + 1
            stateRevision.incrementAndGet()
        }
    }

    private fun nextAccessSequence(): Long {
        if (accessSequence == Long.MAX_VALUE) throw ImportFailure("Library access sequence exceeded its supported range.")
        return ++accessSequence
    }

    private fun archiveDirectory(record: ArchiveRecord): File {
        validateStorageDirectory(record.id, record.storageDirectory)
        return File(if (record.isTemporary) temporary else retained, record.storageDirectory)
    }

    private fun validateStorageDirectory(id: String, directory: String) {
        validateId(id)
        if (directory != id && !directory.matches(Regex("${Regex.escape(id)}-[0-9a-f-]{36}"))) {
            throw ImportFailure("The cached archive has an unsafe storage directory.")
        }
    }

    private fun deferOrDelete(id: String, folder: File) = synchronized(leaseLock) {
        if (id in leases) pendingDelete.getOrPut(id) { mutableListOf() }.add(folder)
        else try { deleteRequired(folder) } catch (error: IOException) {
            pendingDelete.getOrPut(id) { mutableListOf() }.add(folder)
            refreshPendingBytes()
            throw error
        }
        refreshPendingBytes()
    }

    private fun refreshPendingBytes() {
        mutablePendingDeletionBytes.value = pendingDelete.values.flatten().distinctBy { it.path }.sumOf {
            runCatching { ArchiveDiskUsage.directoryBytes(it) }.getOrDefault(0)
        }
    }

    private fun deleteRequired(file: File) {
        if (file.exists() && !file.deleteRecursively()) {
            val message = "Cached files could not be removed and still occupy storage. Cleanup will be retried on the next launch."
            mutableStorageWarning.value = message
            throw ImportFailure(message)
        }
    }

    private fun touchLocked(record: ArchiveRecord): ArchiveRecord {
        val updated = record.copy(lastOpened = System.currentTimeMillis(), accessSequence = nextAccessSequence())
        replaceLocked(updated)
        return updated
    }

    private fun replaceLocked(record: ArchiveRecord) {
        val updated = catalogRecords.map { if (it.id == record.id) record else it }
        persist(updated)
        publish(updated)
    }

    private fun evictLocked() = synchronized(leaseLock) {
        val victims = CachePolicy.evictionCandidates(catalogRecords, cacheLimits, leases.keys).toSet()
        if (victims.isEmpty()) return@synchronized
        val removed = catalogRecords.filter { it.id in victims }
        val updated = catalogRecords.map { if (it.id in victims) it.copy(available = false, visible = false, bytes = 0) else it }
        persist(updated)
        publish(updated)
        removed.forEach { deferOrDelete(it.id, archiveDirectory(it)) }
    }

    private fun publish(records: List<ArchiveRecord>) {
        catalogRecords = boundedHistory(records)
        mutableArchives.value = catalogRecords.filter { it.visible }.sortedWith(compareByDescending<ArchiveRecord> { if (it.accessSequence > 0) it.accessSequence else it.lastOpened }.thenBy { it.id })
        stateRevision.incrementAndGet()
    }

    private fun boundedHistory(records: List<ArchiveRecord>): List<ArchiveRecord> {
        val remembered = records.filter { !it.available }.sortedByDescending { it.accessSequence }.take(100).map { it.id }.toSet()
        return records.filter { it.available || it.id in remembered }
    }

    /** Provider cancellation is cooperative; close our descriptor as well as cancelling query/open. */
    private suspend fun copySource(
        session: ArchiveImportSession, source: File, onProgress: (String, Float?) -> Unit,
    ): PreparedArchiveSource = coroutineScope {
        val signal = CancellationSignal()
        val descriptor = AtomicReference<AssetFileDescriptor?>()
        val lastActivity = AtomicLong(android.os.SystemClock.elapsedRealtime())
        val cancellation = launch(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) {
            try {
                while (true) {
                    delay(1_000)
                    if (android.os.SystemClock.elapsedRealtime() - lastActivity.get() >= 60_000) {
                        throw ImportFailure("The archive provider stopped responding for 60 seconds. Check the network connection and try again.")
                    }
                }
            } finally {
                runCatching { signal.cancel() }
                runCatching { descriptor.getAndSet(null)?.close() }
            }
        }
        try {
            onProgress("Connecting to archive provider…", null)
            val metadata = sourceMetadata(session.uri, signal)
            lastActivity.set(android.os.SystemClock.elapsedRealtime())
            coroutineContext.ensureActive()
            val digest = MessageDigest.getInstance("SHA-256")
            var copied = 0L
            var lastNotification = 0L
            val asset = appContext.contentResolver.openAssetFileDescriptor(session.uri, "r", signal)
                ?: throw ImportFailure("The selected document could not be opened.")
            descriptor.set(asset)
            lastActivity.set(android.os.SystemClock.elapsedRealtime())
            asset.use {
                coroutineContext.ensureActive()
                val expected = metadata.second?.takeIf { it > 0 } ?: asset.length.takeIf { it > 0 }
                fun notifyProgress() {
                    val bytes = Formatter.formatShortFileSize(appContext, copied)
                    val total = expected?.let { " of ${Formatter.formatShortFileSize(appContext, it)}" }.orEmpty()
                    onProgress("Copying archive — $bytes$total", expected?.let { (copied.toFloat() / it).coerceIn(0f, 1f) })
                }
                notifyProgress()
                asset.createInputStream().use { input ->
                    FileOutputStream(source).use { output ->
                        val buffer = ByteArray(256 * 1024)
                        while (true) {
                            coroutineContext.ensureActive()
                            if (session.closed.get()) throw CancellationException("The import session was closed.")
                            val read = input.read(buffer)
                            if (read > 0) lastActivity.set(android.os.SystemClock.elapsedRealtime())
                            if (read < 0) break
                            copied += read
                            if (copied > limits.maximumTotalBytes || session.directory.usableSpace < limits.minimumFreeDiskBytes + read) {
                                throw ImportFailure("The archive is too large or there is not enough free storage.")
                            }
                            output.write(buffer, 0, read)
                            digest.update(buffer, 0, read)
                            val now = android.os.SystemClock.elapsedRealtime()
                            if (now - lastNotification > 100) { notifyProgress(); lastNotification = now }
                        }
                        coroutineContext.ensureActive()
                        output.fd.sync()
                    }
                }
                notifyProgress()
            }
            PreparedArchiveSource(metadata.first, digest.digest().joinToString("") { "%02x".format(it) })
        } catch (error: SecurityException) {
            coroutineContext.ensureActive()
            throw ImportFailure("The file app did not grant access to this archive, or its permission expired. Select the archive again or try another file app.", error)
        } catch (error: java.io.FileNotFoundException) {
            coroutineContext.ensureActive()
            throw ImportFailure("The selected archive is no longer available. Reconnect to the share and select it again.", error)
        } catch (error: Exception) {
            coroutineContext.ensureActive()
            throw error
        } finally {
            runCatching { descriptor.getAndSet(null)?.close() }
            cancellation.cancel()
        }
    }

    private fun sourceMetadata(uri: Uri, signal: CancellationSignal): Pair<String, Long?> {
        var name = uri.lastPathSegment?.substringAfterLast('/') ?: "Archive"
        var size: Long? = null
        runCatching {
            appContext.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null, signal)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
                }
            }
        }
        signal.throwIfCanceled()
        return name.take(512) to size
    }

    private fun detectFormat(file: File): String {
        val header = ByteArray(6)
        val count = file.inputStream().use { it.read(header) }
        if (count >= 6 && header.contentEquals(byteArrayOf(0x37, 0x7a, 0xbc.toByte(), 0xaf.toByte(), 0x27, 0x1c))) return "7z"
        if (count >= 4 && header[0] == 0x50.toByte() && header[1] == 0x4b.toByte() &&
            ((header[2] == 3.toByte() && header[3] == 4.toByte()) || (header[2] == 5.toByte() && header[3] == 6.toByte()))) return "zip"
        throw ImportFailure("Choose a ZIP, CBZ or 7z archive.")
    }

    private fun ensureDirectory(file: File) {
        if (!file.isDirectory && !file.mkdirs()) throw ImportFailure("The app could not create its private storage folder.")
    }

    private fun persist(records: List<ArchiveRecord>) {
        val json = JSONObject().put("version", 2).put("archives", JSONArray().apply {
            boundedHistory(records).filter { !it.isTemporary }.forEach { put(encodeRecord(it)) }
        })
        writeAtomic(catalog.baseFile, json.toString())
    }

    private fun writeAtomic(file: File, text: String) {
        val atomic = AtomicFile(file)
        val output = atomic.startWrite()
        try {
            output.write(text.toByteArray(Charsets.UTF_8))
            atomic.finishWrite(output)
        } catch (error: Throwable) {
            atomic.failWrite(output)
            throw error
        }
    }

    private fun parseCatalog(text: String): List<ArchiveRecord> {
        val json = JSONObject(text)
        if (json.getInt("version") !in 1..2) throw ImportFailure("This library was created by a newer version of the app.")
        val entries = json.getJSONArray("archives")
        return (0 until entries.length()).map { decodeRecord(entries.getJSONObject(it)) }
    }

    private fun encodeRecord(record: ArchiveRecord): JSONObject = JSONObject().apply {
        put("storageDirectory", record.storageDirectory); put("id", record.id); put("title", record.title); put("format", record.format)
        put("sourceIdentity", record.sourceIdentity ?: JSONObject.NULL); put("sourceDigest", record.sourceDigest ?: JSONObject.NULL)
        put("accessSequence", record.accessSequence); put("lastOpened", record.lastOpened); put("currentPagePath", record.currentPagePath ?: JSONObject.NULL)
        put("visible", record.visible); put("bytes", record.bytes); put("available", record.available); put("temporary", record.isTemporary)
        put("pages", JSONArray().apply {
            record.pages.forEach { page -> put(JSONObject().apply {
                put("originalPath", page.originalPath); put("storedPath", page.storedPath)
                put("modifiedAt", page.modifiedAt ?: JSONObject.NULL); put("createdAt", page.createdAt ?: JSONObject.NULL)
                put("previewPath", page.previewPath ?: JSONObject.NULL); put("processingPolicy", page.processingPolicy ?: JSONObject.NULL)
            }) }
        })
    }

    private fun decodeRecord(json: JSONObject): ArchiveRecord {
        val id = json.getString("id")
        validateId(id)
        val entries = json.getJSONArray("pages")
        if (entries.length() > limits.maximumImageCount) throw ImportFailure("The cached archive has too many images.")
        val pages = (0 until entries.length()).map { i ->
            val page = entries.getJSONObject(i)
            val original = page.getString("originalPath")
            val stored = page.getString("storedPath")
            ArchiveOutputPolicy.validateRelativePath(original)
            ArchiveOutputPolicy.validateRelativePath(stored)
            PageRecord(original, stored, if (page.isNull("modifiedAt")) null else page.getLong("modifiedAt"),
                if (page.isNull("createdAt")) null else page.getLong("createdAt"),
                if (page.isNull("previewPath")) null else page.getString("previewPath").also(ArchiveOutputPolicy::validateRelativePath),
                if (page.isNull("processingPolicy")) null else page.getString("processingPolicy"))
        }
        return ArchiveRecord(id, json.getString("title"), json.getString("format"), pages, json.getLong("lastOpened"),
            if (json.isNull("currentPagePath")) null else json.getString("currentPagePath"), json.getLong("bytes").coerceAtLeast(0),
            json.optBoolean("available", true), json.optBoolean("temporary", false), json.optLong("accessSequence", 0),
            json.optString("storageDirectory", id).also { validateStorageDirectory(id, it) },
            if (json.isNull("sourceIdentity")) null else json.getString("sourceIdentity"),
            if (json.isNull("sourceDigest")) null else json.getString("sourceDigest"), json.optBoolean("visible", true))
    }

    private fun validateId(id: String) {
        if (!id.matches(Regex("[0-9a-f]{64}"))) throw ImportFailure("The cached archive has an invalid identity.")
    }
}
