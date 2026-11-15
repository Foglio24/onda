package com.onda.seaglass.update

import com.onda.seaglass.BuildConfig
import com.onda.seaglass.core.Http
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.json.JSONArray
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.URI
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/**
 * Automatic updates like on the Mac: look for a newer `windows-vX.Y.Z` release on GitHub (never
 * "Latest" — that stays the iPhone app), download its zip, check size and SHA-256, stage the new
 * app beside this one, then install on restart or when Seaglass quits normally.
 */
object AppUpdater {
    data class Release(
        val version: String,
        val notes: String,
        val pageUrl: String,
        val zipUrl: String?,
        val size: Long?,
        val digest: String?,
    )

    sealed class Status {
        data object Idle : Status()
        data object Checking : Status()
        data object UpToDate : Status()
        data class Available(val release: Release) : Status()
        data class Downloading(val received: Long, val total: Long) : Status()
        data object Verifying : Status()
        data class Ready(val stagedDir: File, val release: Release) : Status()
        data class Failed(val message: String) : Status()
    }

    private const val RELEASES = "https://api.github.com/repos/${BuildConfig.REPOSITORY}/releases?per_page=40"

    private val _status = MutableStateFlow<Status>(Status.Idle)
    val status: StateFlow<Status> = _status.asStateFlow()

    private var lastCheckMs = 0L
    private var stagedInstall: File? = null

    /** Hourly when the window comes forward (as on Mac). */
    suspend fun checkIfDue(force: Boolean = false) {
        val now = System.currentTimeMillis()
        if (!force && lastCheckMs > 0 && now - lastCheckMs < 3_600_000L) return
        check(userInitiated = force)
    }

    suspend fun check(userInitiated: Boolean = false) = withContext(Dispatchers.IO) {
        lastCheckMs = System.currentTimeMillis()
        _status.value = Status.Checking
        try {
            val release = latest() ?: run {
                _status.value = Status.UpToDate
                return@withContext
            }
            if (!isNewer(release.version, BuildConfig.VERSION_NAME)) {
                _status.value = Status.UpToDate
                return@withContext
            }
            _status.value = Status.Available(release)
            // Like Mac's default "Installa in automatico": download without waiting for a click.
            downloadAndStage(release)
        } catch (e: Exception) {
            _status.value = Status.Failed(e.message ?: e.toString())
        }
    }

    suspend fun downloadAndStage(release: Release) = withContext(Dispatchers.IO) {
        val url = release.zipUrl ?: run {
            _status.value = Status.Failed("Questa versione non ha un file Windows da scaricare.")
            return@withContext
        }
        if (!isReleaseAsset(url)) {
            _status.value = Status.Failed("Questo aggiornamento non è valido: non è stato installato.")
            return@withContext
        }
        val expectedSize = release.size ?: 0L
        val expectedDigest = release.digest?.lowercase()?.removePrefix("sha256:")
        if (expectedSize <= 0 || expectedDigest.isNullOrBlank()) {
            _status.value = Status.Failed("Questo aggiornamento non è valido: non è stato installato.")
            return@withContext
        }
        try {
            _status.value = Status.Downloading(0, expectedSize)
            val updates = updatesDir()
            updates.mkdirs()
            val zip = File(updates, "Seaglass-${release.version}-windows.zip")
            download(url, zip) { received, total ->
                _status.value = Status.Downloading(received, total)
            }
            _status.value = Status.Verifying
            if (zip.length() != expectedSize) error("size mismatch")
            val actual = sha256(zip)
            if (actual != expectedDigest) error("digest mismatch")
            val staged = File(updates, "staged-${release.version}")
            staged.deleteRecursively()
            staged.mkdirs()
            unzip(zip, staged)
            zip.delete()
            // The zip must contain Seaglass.exe (or a single folder that does).
            val appRoot = findAppRoot(staged) ?: error("Seaglass.exe missing in update")
            stagedInstall = appRoot
            _status.value = Status.Ready(appRoot, release)
        } catch (e: Exception) {
            _status.value = Status.Failed(e.message ?: e.toString())
        }
    }

    /**
     * Puts the staged app in place of this one and relaunches (Mac's restartToInstall).
     * Uses a small cmd helper so this process can exit first.
     */
    fun installAndRelaunch(): Boolean {
        val staged = stagedInstall ?: return false
        val installDir = installDirectory() ?: return false
        val helper = File(updatesDir(), "apply-update.cmd")
        val exe = File(installDir, "Seaglass.exe").absolutePath
        val stagedPath = staged.absolutePath
        val installPath = installDir.absolutePath
        helper.writeText(
            """
            @echo off
            rem Wait for Seaglass to quit, then replace files and relaunch.
            :wait
            timeout /t 2 /nobreak >nul
            tasklist /FI "IMAGENAME eq Seaglass.exe" | find /I "Seaglass.exe" >nul && goto wait
            xcopy /E /Y /I "$stagedPath\*" "$installPath\"
            start "" "$exe"
            rmdir /S /Q "$stagedPath"
            del "%~f0"
            """.trimIndent()
        )
        ProcessBuilder("cmd", "/c", "start", "", helper.absolutePath)
            .directory(updatesDir())
            .start()
        return true
    }

    /** An update that's ready goes in as Seaglass quits (no relaunch). */
    fun installAtQuit() {
        val staged = stagedInstall ?: return
        val installDir = installDirectory() ?: return
        runCatching {
            staged.walkTopDown().forEach { source ->
                if (source.isFile) {
                    val relative = source.relativeTo(staged)
                    val target = File(installDir, relative.path)
                    target.parentFile?.mkdirs()
                    Files.copy(source.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
                }
            }
        }
    }

    fun latest(): Release? {
        val request = Request.Builder()
            .url(RELEASES)
            .header("Accept", "application/vnd.github+json")
            .build()
        val releases = JSONArray(Http.text(request))
        return (0 until releases.length()).asSequence()
            .map { releases.getJSONObject(it) }
            .filter { it.optString("tag_name").startsWith("windows-v") && !it.optBoolean("draft") }
            .map { release ->
                val assets = release.optJSONArray("assets") ?: JSONArray()
                val zips = (0 until assets.length()).map { assets.getJSONObject(it) }
                    .filter {
                        val name = it.optString("name").lowercase()
                        name.endsWith(".zip") && name.contains("windows")
                    }
                val zip = zips.firstOrNull()
                val digest = zip?.optString("digest")?.takeIf { it.isNotBlank() }
                Release(
                    version = release.optString("tag_name").removePrefix("windows-v"),
                    notes = release.optString("body"),
                    pageUrl = release.optString("html_url"),
                    zipUrl = zip?.optString("browser_download_url"),
                    size = zip?.optLong("size"),
                    digest = digest,
                )
            }
            .maxWithOrNull { a, b -> compareVersions(a.version, b.version) }
    }

    fun isNewer(a: String, b: String) = compareVersions(a, b) > 0

    fun compareVersions(a: String, b: String): Int {
        val x = a.split('.').map { it.toIntOrNull() ?: 0 }
        val y = b.split('.').map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) {
            val d = x.getOrElse(i) { 0 } - y.getOrElse(i) { 0 }
            if (d != 0) return d
        }
        return 0
    }

    private fun isReleaseAsset(url: String): Boolean {
        val uri = runCatching { URI(url) }.getOrNull() ?: return false
        return uri.scheme == "https" &&
            uri.host == "github.com" &&
            uri.path.startsWith("/${BuildConfig.REPOSITORY}/releases/download/")
    }

    private fun download(url: String, to: File, onProgress: (Long, Long) -> Unit) {
        val request = Request.Builder().url(url).build()
        Http.client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("HTTP ${response.code}")
            val body = response.body ?: error("empty body")
            val total = body.contentLength().takeIf { it > 0 } ?: 0L
            to.parentFile?.mkdirs()
            FileOutputStream(to).use { out ->
                body.byteStream().use { input ->
                    val buffer = ByteArray(1 shl 16)
                    var received = 0L
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        received += n
                        onProgress(received, if (total > 0) total else received)
                    }
                }
            }
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(1 shl 20)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun unzip(zip: File, into: File) {
        val root = into.canonicalFile
        ZipInputStream(FileInputStream(zip)).use { zis ->
            while (true) {
                val entry = zis.nextEntry ?: break
                // Reject zip-slip: every entry must stay under the staging folder.
                val out = File(into, entry.name).canonicalFile
                if (!out.path.startsWith(root.path + File.separator) && out != root) {
                    error("invalid update archive")
                }
                if (entry.isDirectory) {
                    out.mkdirs()
                } else {
                    out.parentFile?.mkdirs()
                    FileOutputStream(out).use { zis.copyTo(it) }
                }
                zis.closeEntry()
            }
        }
    }

    private fun findAppRoot(staged: File): File? {
        if (File(staged, "Seaglass.exe").isFile) return staged
        return staged.listFiles()?.firstOrNull { File(it, "Seaglass.exe").isFile }
    }

    private fun updatesDir(): File {
        val base = File(System.getProperty("user.home"), "AppData/Local/Seaglass/Updates")
        base.mkdirs()
        return base
    }

    /** Directory that contains Seaglass.exe when installed; null when running from a build tree. */
    private fun installDirectory(): File? {
        val exe = File(System.getProperty("java.home")).parentFile?.let { File(it, "Seaglass.exe") }
            ?: File("Seaglass.exe")
        // Compose Desktop packaged apps put the exe next to the runtime.
        val candidates = listOf(
            File(System.getProperty("compose.application.resources.dir") ?: "").parentFile,
            File(System.getProperty("user.dir") ?: ""),
            exe.parentFile,
        )
        return candidates.firstOrNull { it != null && File(it, "Seaglass.exe").isFile }
    }
}
