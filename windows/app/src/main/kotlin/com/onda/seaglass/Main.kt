package com.onda.seaglass

import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import com.onda.seaglass.account.Account
import com.onda.seaglass.account.ProtocolRegistrar
import com.onda.seaglass.ui.ClassicShell
import com.onda.seaglass.ui.theme.SeaglassTheme
import com.onda.seaglass.update.AppUpdater
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.awt.Desktop
import java.awt.desktop.OpenURIHandler

fun main(args: Array<String>) {
    ProtocolRegistrar.ensureRegistered()
    // Protocol handler callback (com.onda.player.auth:/callback?…).
    args.firstOrNull { it.startsWith("com.onda.player.auth:") }?.let { Account.handleCallback(it) }
    if (Desktop.isDesktopSupported()) {
        runCatching {
            Desktop.getDesktop().setOpenURIHandler(OpenURIHandler { event ->
                Account.handleCallback(event.uri.toString())
            })
        }
    }

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    scope.launch { Account.refresh() }
    scope.launch { AppUpdater.checkIfDue(force = true) }

    Runtime.getRuntime().addShutdownHook(Thread {
        AppUpdater.installAtQuit()
    })

    application {
        Window(
            onCloseRequest = {
                AppUpdater.installAtQuit()
                exitApplication()
            },
            title = "Seaglass",
            state = rememberWindowState(width = 1280.dp, height = 800.dp),
        ) {
            window.addWindowFocusListener(object : java.awt.event.WindowFocusListener {
                override fun windowGainedFocus(e: java.awt.event.WindowEvent?) {
                    scope.launch { AppUpdater.checkIfDue(force = false) }
                }
                override fun windowLostFocus(e: java.awt.event.WindowEvent?) = Unit
            })
            SeaglassTheme {
                ClassicShell()
            }
        }
    }
}
