package com.onda.seaglass

import com.onda.seaglass.account.Account
import com.onda.seaglass.audio.Player
import com.onda.seaglass.core.Paths
import com.onda.seaglass.core.Prefs
import com.onda.seaglass.update.AppUpdater
import com.sun.jna.Pointer
import com.sun.jna.platform.win32.Advapi32Util
import com.sun.jna.platform.win32.Kernel32
import com.sun.jna.platform.win32.User32
import com.sun.jna.platform.win32.WinDef
import com.sun.jna.platform.win32.WinReg
import com.sun.jna.platform.win32.WinUser
import java.io.File
import java.io.RandomAccessFile
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.channels.FileLock
import javax.swing.SwingUtilities
import kotlin.system.exitProcess

/**
 * What ties Seaglass to Windows: one instance at a time (a second launch, such as the account
 * page's sign-in link, is handed to the running one), the keyboard's media keys even with the
 * window closed, and starting with Windows.
 */
object WindowsIntegration {
    val isWindows = System.getProperty("os.name").orEmpty().lowercase().contains("win")

    /** Brings the window back (set by the window). */
    @Volatile var showWindow: () -> Unit = {}

    private var lock: FileLock? = null
    private var server: ServerSocket? = null

    /**
     * True when this is the only Seaglass running. Otherwise [args] go to the one that is
     * (it shows its window, or takes the sign-in link) and this one should end.
     */
    fun claimSingleInstance(args: Array<String>): Boolean {
        val lockFile = File(Paths.local, "instance.lock")
        val portFile = File(Paths.local, "instance.port")
        val channel = RandomAccessFile(lockFile, "rw").channel
        val acquired = runCatching { channel.tryLock() }.getOrNull()
        if (acquired == null) {
            val port = portFile.readText().trim().toIntOrNull()
            if (port != null) {
                runCatching {
                    Socket(InetAddress.getLoopbackAddress(), port).use { socket ->
                        socket.getOutputStream().bufferedWriter().apply {
                            write((args.firstOrNull { it.startsWith(Account.CALLBACK) } ?: "show") + "\n")
                            flush()
                        }
                    }
                }
            }
            return false
        }
        lock = acquired
        val listener = ServerSocket(0, 4, InetAddress.getLoopbackAddress())
        server = listener
        portFile.writeText(listener.localPort.toString())
        Thread({
            while (!listener.isClosed) {
                val socket = runCatching { listener.accept() }.getOrNull() ?: continue
                val line = runCatching { socket.use { it.getInputStream().bufferedReader().readLine() } }.getOrNull() ?: continue
                // Only two messages: show the window, or the account page's sign-in link (checked there).
                SwingUtilities.invokeLater {
                    if (line.startsWith(Account.CALLBACK)) Account.handleCallback(line.take(4096))
                    showWindow()
                }
            }
        }, "seaglass-instance").apply { isDaemon = true }.start()
        return true
    }

    /** Ends the app: installs a downloaded update first when automatic updates are on. */
    fun quit() {
        if (Prefs.autoUpdate.value) runCatching { AppUpdater.installNow() }
        runCatching { Player.shutdown() }
        runCatching { server?.close() }
        runCatching { lock?.release() }
        exitProcess(0)
    }

    // MARK: Starting with Windows

    private const val RUN_KEY = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"

    /** The app's own launcher, as jpackage sets it; null when run another way (development). */
    private val launcher: String? get() = System.getProperty("jpackage.app-path")?.takeIf { File(it).isFile }

    fun setAutostart(on: Boolean) {
        if (!isWindows) return
        runCatching {
            if (on) {
                val path = launcher ?: return
                Advapi32Util.registrySetStringValue(WinReg.HKEY_CURRENT_USER, RUN_KEY, "Seaglass", "\"$path\" --background")
            } else if (Advapi32Util.registryValueExists(WinReg.HKEY_CURRENT_USER, RUN_KEY, "Seaglass")) {
                Advapi32Util.registryDeleteValue(WinReg.HKEY_CURRENT_USER, RUN_KEY, "Seaglass")
            }
        }
    }

    // MARK: Media keys

    private const val VK_MEDIA_NEXT_TRACK = 0xB0
    private const val VK_MEDIA_PREV_TRACK = 0xB1
    private const val VK_MEDIA_STOP = 0xB2
    private const val VK_MEDIA_PLAY_PAUSE = 0xB3
    @Volatile private var hookProc: WinUser.LowLevelKeyboardProc? = null

    /**
     * The keyboard's play/pause, next and previous keys, whichever window has the focus: a
     * low-level keyboard hook that only looks at those four keys and passes every key on.
     */
    fun startMediaKeys() {
        if (!isWindows || hookProc != null) return
        Thread({
            runCatching {
                val user32 = User32.INSTANCE
                val module = Kernel32.INSTANCE.GetModuleHandle(null)
                var hook: WinUser.HHOOK? = null
                val proc = WinUser.LowLevelKeyboardProc { code, wParam, info ->
                    if (code >= 0 && wParam.toInt() == WinUser.WM_KEYDOWN) {
                        when (info.vkCode) {
                            VK_MEDIA_PLAY_PAUSE -> SwingUtilities.invokeLater { Player.toggle() }
                            VK_MEDIA_NEXT_TRACK -> SwingUtilities.invokeLater { Player.next() }
                            VK_MEDIA_PREV_TRACK -> SwingUtilities.invokeLater { Player.previous() }
                            VK_MEDIA_STOP -> SwingUtilities.invokeLater { Player.pause() }
                        }
                    }
                    user32.CallNextHookEx(hook, code, wParam, WinDef.LPARAM(Pointer.nativeValue(info.pointer)))
                }
                hookProc = proc
                hook = user32.SetWindowsHookEx(WinUser.WH_KEYBOARD_LL, proc, module, 0)
                val message = WinUser.MSG()
                while (user32.GetMessage(message, null, 0, 0) > 0) {
                    user32.TranslateMessage(message)
                    user32.DispatchMessage(message)
                }
            }
        }, "seaglass-media-keys").apply { isDaemon = true }.start()
    }
}
