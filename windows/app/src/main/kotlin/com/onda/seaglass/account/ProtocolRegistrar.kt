package com.onda.seaglass.account

import java.io.File

/**
 * Registers `com.onda.player.auth` under HKCU so the account page can return the one-time code
 * the same way as on iPhone/Mac (`com.onda.player.auth:/callback?…`).
 */
object ProtocolRegistrar {
    fun ensureRegistered() {
        if (!System.getProperty("os.name").orEmpty().contains("Windows", ignoreCase = true)) return
        val exe = resolveExe() ?: return
        val command = "\"$exe\" \"%1\""
        runCatching {
            regAdd("""HKCU\Software\Classes\com.onda.player.auth""", "/ve", "/d", "URL:Seaglass Account", "/f")
            regAdd("""HKCU\Software\Classes\com.onda.player.auth""", "/v", "URL Protocol", "/d", "", "/f")
            regAdd("""HKCU\Software\Classes\com.onda.player.auth\shell\open\command""", "/ve", "/d", command, "/f")
        }
    }

    private fun resolveExe(): String? {
        val candidates = listOfNotNull(
            File(System.getProperty("compose.application.resources.dir") ?: "").parentFile?.let { File(it, "Seaglass.exe") },
            File(System.getProperty("user.dir") ?: "", "Seaglass.exe"),
            File(System.getProperty("java.home") ?: "").parentFile?.let { File(it, "Seaglass.exe") },
        )
        return candidates.firstOrNull { it.isFile }?.absolutePath
    }

    private fun regAdd(key: String, vararg args: String) {
        val cmd = mutableListOf("reg", "add", key, *args)
        ProcessBuilder(cmd)
            .redirectErrorStream(true)
            .start()
            .waitFor()
    }
}
