package com.brite.zipimageviewer.bridge

import android.app.Application
import com.brite.zipimageviewer.AppCoordinator
import com.brite.zipimageviewer.MainActivity
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

class ZipImageViewerModule(context: ReactApplicationContext) : NativeZipImageViewerSpec(context) {
    private val model = AppCoordinator.get(context.applicationContext as Application)
    private val subscriptions = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    override fun initialize() {
        super.initialize()
        subscriptions.launch {
            combine(model.changes, model.archives, model.repository.pendingDeletionBytes,
                model.repository.storageWarning) { _, _, _, _ -> model.protocol.snapshot() }.collect { snapshot ->
                // Codegen installs the event callback after module construction. Reconnect obtains
                // an authoritative snapshot; missing early listeners must never cancel native work.
                if (reactApplicationContext.hasActiveReactInstance()) runCatching { emitOnStateChanged(snapshot) }
            }
        }
    }
    override fun getSnapshot(promise: Promise) { subscriptions.launch { promise.resolve(model.protocol.snapshot()) } }
    override fun dispatch(command: String, promise: Promise) {
        subscriptions.launch {
            try { promise.resolve(model.protocol.dispatch(command, reactApplicationContext.currentActivity as? MainActivity)) }
            catch (error: Exception) { promise.reject("INVALID_COMMAND", error.message ?: "The command could not be accepted.") }
        }
    }
    override fun invalidate() { subscriptions.cancel(); super.invalidate() }
}
