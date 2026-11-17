package com.onda.seaglass

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.res.loadImageBitmap
import androidx.compose.ui.res.useResource
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Tray
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import com.onda.seaglass.account.Account
import com.onda.seaglass.audio.Equalizer
import com.onda.seaglass.audio.Player
import com.onda.seaglass.core.L10n
import com.onda.seaglass.core.Prefs
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Downloads
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.LocalMusic
import com.onda.seaglass.data.NowPlayingLyrics
import com.onda.seaglass.data.Recommendations
import com.onda.seaglass.ui.Nav
import com.onda.seaglass.ui.Route
import com.onda.seaglass.ui.SeaglassTheme
import com.onda.seaglass.ui.SpaceBar
import com.onda.seaglass.ui.Shell
import com.onda.seaglass.update.AppUpdater
import java.awt.Dimension
import kotlin.system.exitProcess

fun main(args: Array<String>) {
    if ("--self-test" in args) exitProcess(SelfTest.run())
    if (!WindowsIntegration.claimSingleInstance(args)) exitProcess(0)
    L10n.load(Prefs.language.value)
    Library.init()
    com.onda.seaglass.data.RecentSearches.init()
    Downloads.init()
    LocalMusic.init()
    Recommendations.init()
    Equalizer.load()
    Player.init()
    NowPlayingLyrics.init()
    Account.init()
    com.onda.seaglass.data.LastFM.init()
    AppUpdater.start()
    WindowsIntegration.startMediaKeys()
    args.firstOrNull { it.startsWith(Account.CALLBACK) }?.let(Account::handleCallback)
    // Started with Windows: only in the notification area until the user opens it.
    val background = "--background" in args
    val icon = BitmapPainter(useResource("icon.png", ::loadImageBitmap))
    val trayIcon = BitmapPainter(useResource("tray.png", ::loadImageBitmap))

    application(exitProcessOnExit = true) {
        var visible by remember { mutableStateOf(!background) }
        // -Dseaglass.window=980x640 opens it at another size (screenshots at the smallest one).
        val size = System.getProperty("seaglass.window")?.split("x")?.mapNotNull { it.toIntOrNull() }?.takeIf { it.size == 2 }
            ?.let { DpSize(it[0].dp, it[1].dp) } ?: DpSize(1280.dp, 820.dp)
        val windowState = rememberWindowState(size = size, position = WindowPosition(Alignment.Center))
        WindowsIntegration.showWindow = {
            visible = true
            windowState.isMinimized = false
        }
        val state by Player.state.collectAsState()
        val tray by Prefs.keepPlayingInTray.state.collectAsState()
        if (tray || !visible) {
            Tray(
                icon = trayIcon,
                tooltip = state.current?.let { "${it.title} – ${it.artist}" } ?: "Seaglass",
                onAction = { WindowsIntegration.showWindow() },
                menu = {
                    Item(tr("Mostra Seaglass"), onClick = { WindowsIntegration.showWindow() })
                    Separator()
                    Item(if (state.isPlaying) tr("Pausa") else tr("Riproduci"), enabled = state.current != null, onClick = { Player.toggle() })
                    Item(tr("Successivo"), enabled = state.current != null, onClick = { Player.next() })
                    Item(tr("Precedente"), enabled = state.current != null, onClick = { Player.previous() })
                    Separator()
                    Item(tr("Esci"), onClick = { WindowsIntegration.quit() })
                },
            )
        }
        Window(
            onCloseRequest = {
                // As the Mac app: closing the window keeps the music going, in the notification area.
                if (Prefs.keepPlayingInTray.value) visible = false else WindowsIntegration.quit()
            },
            visible = visible,
            title = state.current?.let { "${it.title} – ${it.artist}" } ?: "Seaglass",
            icon = icon,
            state = windowState,
            onPreviewKeyEvent = { event ->
                // The space bar plays and pauses, unless a text field has the focus (a space is a space
                // there). It is seen here, before whatever has the focus: a focused button would take it
                // as a click. Once per press: holding it down repeats the key, and the release is taken too.
                if (SpaceBar.handle(event) { Player.toggle() }) return@Window true
                if (event.type != KeyEventType.KeyDown) return@Window false
                when {
                    // On Windows the media keys are taken by the keyboard hook whatever has the focus
                    // (WindowsIntegration): handled here too, they would count twice.
                    !WindowsIntegration.isWindows && event.key == Key.MediaPlayPause -> { Player.toggle(); true }
                    !WindowsIntegration.isWindows && event.key == Key.MediaNext -> { Player.next(); true }
                    !WindowsIntegration.isWindows && event.key == Key.MediaPrevious -> { Player.previous(); true }
                    // The window's own event for the same press is dropped; if the hook missed it, it is handled here.
                    WindowsIntegration.isWindows && event.key == Key.MediaPlayPause -> { if (!WindowsIntegration.hookTookAMediaKey()) Player.toggle(); true }
                    WindowsIntegration.isWindows && event.key == Key.MediaNext -> { if (!WindowsIntegration.hookTookAMediaKey()) Player.next(); true }
                    WindowsIntegration.isWindows && event.key == Key.MediaPrevious -> { if (!WindowsIntegration.hookTookAMediaKey()) Player.previous(); true }
                    event.isCtrlPressed && event.key == Key.DirectionRight -> { Player.next(); true }
                    event.isCtrlPressed && event.key == Key.DirectionLeft -> { Player.previous(); true }
                    event.isCtrlPressed && event.key == Key.DirectionUp -> { Player.setVolume(Prefs.volume.value + 0.05); true }
                    event.isCtrlPressed && event.key == Key.DirectionDown -> { Player.setVolume(Prefs.volume.value - 0.05); true }
                    event.isCtrlPressed && event.key == Key.P -> { Player.toggle(); true }
                    event.isCtrlPressed && event.key == Key.L -> { Nav.togglePanel(Nav.Panel.LYRICS); true }
                    event.isCtrlPressed && event.key == Key.Comma -> { Nav.section(Route.Settings); true }
                    event.key == Key.Escape && Nav.fullPlayer -> { Nav.fullPlayer = false; true }
                    else -> false
                }
            },
        ) {
            LaunchedEffect(Unit) { window.minimumSize = Dimension(980, 640) }
            SeaglassTheme { Shell() }
        }
    }
}
