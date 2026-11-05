package com.onda.seaglass

import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.mutableStateOf
import com.onda.seaglass.core.L10n
import com.onda.seaglass.playback.PlayerController
import com.onda.seaglass.ui.AppRoot
import com.onda.seaglass.ui.Launch

class MainActivity : ComponentActivity() {
    /** What the app was opened for: the player, a link, or (for screenshots) a scene. */
    private val launch = mutableStateOf<Launch?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        L10n.load(this)
        PlayerController.connect()
        launch.value = Launch.from(intent)
        setContent { AppRoot(launch) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        launch.value = Launch.from(intent)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        L10n.load(this)
    }

    companion object {
        const val OPEN_PLAYER = "openPlayer"
    }
}
