plugins {
    id("com.facebook.react") apply false
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.2.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21" apply false
}

// Autolinked Android libraries inherit the app's existing toolchain rather than their old defaults.
extra["compileSdkVersion"] = 36
extra["targetSdkVersion"] = 36
extra["minSdkVersion"] = 28
extra["kotlinVersion"] = "2.2.21"
extra["ndkVersion"] = "27.1.12297006"
