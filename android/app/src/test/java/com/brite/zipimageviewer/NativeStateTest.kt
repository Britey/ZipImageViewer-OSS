package com.brite.zipimageviewer

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test

class NativeStateTest {
    private class Service {
        val changes = MutableStateFlow(0L)
        var reader: String? by NativeState<String?>(null) { changes.value += 1 }
    }
    @Test fun nativeObserverReceivesReaderBeforeAnyComposeRuntimeIsStarted() = runBlocking {
        val service = Service()
        val observed = async(start = CoroutineStart.UNDISPATCHED) {
            withTimeout(1_000) { service.changes.first { it > 0 }; service.reader }
        }
        service.reader = "native-session"
        assertEquals("native-session", observed.await())
        service.reader = "native-session"
        assertEquals("An unchanged session must not relaunch its reader", 1L, service.changes.value)
        service.reader = null
        assertEquals(2L, service.changes.value)
    }
}
