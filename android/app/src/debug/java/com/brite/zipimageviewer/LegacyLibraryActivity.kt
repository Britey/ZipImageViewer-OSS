package com.brite.zipimageviewer

import android.content.Intent
import android.content.pm.ActivityInfo
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color

class LegacyLibraryActivity : ComponentActivity() {
    private val model by lazy { AppCoordinator.get(application) }
    override fun onStop() { model.flushProgress(); super.onStop() }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (resources.configuration.isScreenWideColorGamut) {
            window.colorMode = ActivityInfo.COLOR_MODE_WIDE_COLOR_GAMUT
        }
        setContent {
            val dark = isSystemInDarkTheme()
            MaterialTheme(colorScheme = if (dark) darkColorScheme(
                primary = Color(0xFF99DEC9), onPrimary = Color(0xFF10392F),
                secondary = Color(0xFFBDD2E8), background = Color(0xFF101519),
                secondaryContainer = Color(0xFF23483E), onSecondaryContainer = Color(0xFFD1F2E5),
                surface = Color(0xFF101519), surfaceContainer = Color(0xFF1B2429),
                surfaceContainerHigh = Color(0xFF243137)
            ) else lightColorScheme(
                primary = Color(0xFF246B57), onPrimary = Color.White,
                secondary = Color(0xFF47647D), background = Color(0xFFF7F8F3),
                secondaryContainer = Color(0xFFE0EDE5), onSecondaryContainer = Color(0xFF20382F),
                surface = Color(0xFFF7F8F3), surfaceContainer = Color(0xFFEDEFE8),
                surfaceContainerHigh = Color(0xFFE2E7DF)
            )) { ZipImageViewerApp(model) }
        }
        // The process coordinator owns ongoing work across rotation. Replaying the launch intent
        // would start another transfer (or reopen a reader the user already closed).
        if (savedInstanceState == null) receiveArchive(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receiveArchive(intent)
    }

    private fun receiveArchive(intent: Intent) {
        when (val request = IncomingArchiveIntent.parse(intent)) {
            IncomingArchiveIntent.Result.Ignore -> Unit
            is IncomingArchiveIntent.Result.Invalid -> model.showError(request.message)
            is IncomingArchiveIntent.Result.Open -> model.import(request.uri)
        }
    }
}
