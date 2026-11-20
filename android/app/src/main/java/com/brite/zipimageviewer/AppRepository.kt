package com.brite.zipimageviewer

import android.content.Context
import com.brite.zipimageviewer.data.ArchiveRepository
import kotlinx.coroutines.withTimeout

/** One catalog owner per process; finishing an Activity does not discard native image-work leases. */
internal object AppRepository {
    private var instance: ArchiveRepository? = null

    @Synchronized fun get(context: Context): ArchiveRepository =
        instance ?: ArchiveRepository(context.applicationContext).also { instance = it }

    /** Instrumentation starts a fresh process-equivalent library only after previous work has drained. */
    internal suspend fun resetForTests() {
        AppCoordinator.resetForTests()
        val previous = synchronized(this) { instance }
        withTimeout(30_000) { previous?.awaitIdle() }
        synchronized(this) { check(instance === previous); instance = null }
    }
}
