package com.onda.seaglass.core

import java.io.File

/**
 * Where the app keeps its files. The library, playlists and settings go in the roaming profile
 * (%APPDATA%\Seaglass), as Windows apps do; caches and downloads, which can be large and are
 * this computer's own, in %LOCALAPPDATA%\Seaglass. Elsewhere (tests, development on Linux or
 * a Mac) both are under ~/.seaglass.
 */
object Paths {
    private val windows = System.getProperty("os.name").orEmpty().lowercase().contains("win")

    /** Overridden by tests and CI screenshots, so they never touch a real profile. */
    private val override: String? = System.getProperty("seaglass.home")

    val data: File by lazy {
        dir(override?.let { File(it, "data") }
            ?: System.getenv("APPDATA")?.takeIf { windows }?.let { File(it, "Seaglass") }
            ?: File(System.getProperty("user.home"), ".seaglass/data"))
    }

    val local: File by lazy {
        dir(override?.let { File(it, "local") }
            ?: System.getenv("LOCALAPPDATA")?.takeIf { windows }?.let { File(it, "Seaglass") }
            ?: File(System.getProperty("user.home"), ".seaglass/local"))
    }

    val cache: File by lazy { dir(File(local, "Cache")) }
    val downloads: File by lazy { dir(File(local, "Downloads")) }
    val updates: File by lazy { dir(File(local, "Updates")) }
    val logs: File by lazy { dir(File(local, "Logs")) }

    private fun dir(file: File): File = file.apply { mkdirs() }

    /** A YouTube video ID, as file names use it: anything else could leave the folder. */
    private val videoIdPattern = Regex("^[A-Za-z0-9_-]{11}$")
    fun isVideoId(text: String): Boolean = videoIdPattern.matches(text)
}
