package com.brite.zipimageviewer

import androidx.compose.runtime.mutableStateOf
import kotlin.reflect.KProperty

/** Compose-compatible reads with synchronous native invalidation, independent of a Recomposer. */
internal class NativeState<T>(initial: T, private val changed: () -> Unit) {
    private val composed = mutableStateOf(initial)
    operator fun getValue(owner: Any?, property: KProperty<*>): T = composed.value
    operator fun setValue(owner: Any?, property: KProperty<*>, value: T) {
        if (composed.value != value) {
            composed.value = value
            changed()
        }
    }
}
