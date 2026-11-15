package com.onda.seaglass.update

import com.onda.seaglass.BuildConfig
import com.onda.seaglass.core.Http
import com.onda.seaglass.core.Paths
import com.onda.seaglass.core.Prefs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.Request
import org.json.JSONArray
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest

/**
 * Seaglass for Windows updates itself, as the Mac app does, from its own releases only: the
 * `windows-vX.Y.Z` releases of this repository (never "Latest", which is the iPhone's). It looks
 * once at launch and then every hour, downloads the newer installer in the background and checks
 * it before running it: it must be that release's own asset, at
 * https://github.com/Foglio24/onda/releases/download/, with the size and SHA-256 the GitHub API
 * gives for it. The installer runs silently when the user restarts or quits, and opens the app again.
 */
object AppUpdater {
    private const val REPOSITORY = "Foglio24/onda"
    private const val RELEASES = "https://api.github.com/repos/$REPOSITORY/releases?per_page=40"
    private const val DOWNLOADS = "https://github.com/$REPOSITORY/releases/download/"
    const val ASSET = "Seaglass-Setup.exe"
    private const val TAG_PREFIX = "windows-v"

    sealed interface State {
        data object Idle : State
        data object Checking : State
        data object UpToDate : State
        data class Downloading(val version: String, val progress: Float) : State
        /** Downloaded and checked: installs on restart or quit. */
        data class Ready(val version: String, val notes: String, val file: File) : State
        data class Failed(val message: String) : State
    }

    data class Release(val version: String, val notes: String, val url: String, val size: Long, val sha256: String)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state
    private var job: Job? = null
    private var timer: Job? = null

    /** At launch, then hourly while the app runs (as the Mac app since 1.36.10). */
    fun start() {
        if (timer != null) return
        timer = scope.launch {
            delay(15_000)
            while (isActive) {
                if (Prefs.autoUpdate.value) check(quiet = true)
                delay(3_600_000)
            }
        }
    }

    /** Settings → Cerca aggiornamenti, or the hourly look. */
    fun check(quiet: Boolean = false) {
        if (job?.isActive == true) return
        if (_state.value is State.Ready) return
        job = scope.launch {
            if (!quiet) _state.value = State.Checking
            try {
                val release = latest()
                if (release == null || compare(release.version, BuildConfig.VERSION) <= 0) {
                    _state.value = if (quiet) State.Idle else State.UpToDate
                    return@launch
                }
                val file = download(release)
                lastRelease = release
                _state.value = State.Ready(release.version, release.notes, file)
            } catch (e: Exception) {
                _state.value = if (quiet) State.Idle else State.Failed(e.message ?: "Update failed")
            }
        }
    }

    /** The newest windows-v* release with its installer, or null. */
    suspend fun latest(): Release? {
        val text = Http.text(Request.Builder().url(RELEASES).header("Accept", "application/vnd.github+json").build())
        return parse(JSONArray(text))
    }

    fun parse(releases: JSONArray): Release? {
        var best: Release? = null
        for (i in 0 until releases.length()) {
            val release = releases.optJSONObject(i) ?: continue
            if (release.optBoolean("draft") || release.optBoolean("prerelease")) continue
            val tag = release.optString("tag_name")
            if (!tag.startsWith(TAG_PREFIX)) continue
            val version = tag.removePrefix(TAG_PREFIX)
            if (!Regex("""\d+\.\d+\.\d+""").matches(version)) continue
            val asset = (0 until (release.optJSONArray("assets")?.length() ?: 0))
                .mapNotNull { release.optJSONArray("assets")?.optJSONObject(it) }
                .firstOrNull { it.optString("name") == ASSET } ?: continue
            val url = asset.optString("browser_download_url")
            val digest = asset.optString("digest")
            // Only this repository's own downloads, and only with GitHub's checksum to compare with.
            if (!url.startsWith(DOWNLOADS + tag + "/") || !digest.startsWith("sha256:")) continue
            val candidate = Release(version, release.optString("body"), url, asset.optLong("size", -1), digest.removePrefix("sha256:").lowercase())
            if (best == null || compare(candidate.version, best.version) > 0) best = candidate
        }
        return best
    }

    /** -1, 0 or 1, comparing "1.2.10" with "1.2.9" as numbers. */
    fun compare(a: String, b: String): Int {
        val left = a.split('.').map { it.toIntOrNull() ?: 0 }
        val right = b.split('.').map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(left.size, right.size)) {
            val difference = (left.getOrElse(i) { 0 }).compareTo(right.getOrElse(i) { 0 })
            if (difference != 0) return difference
        }
        return 0
    }

    private fun download(release: Release): File {
        val target = File(Paths.updates, "Seaglass-Setup-${release.version}.exe")
        if (target.isFile && target.length() == release.size && sha256(target) == release.sha256) return target
        val partial = File(Paths.updates, target.name + ".part")
        _state.value = State.Downloading(release.version, 0f)
        Http.client.newCall(Request.Builder().url(release.url).build()).execute().use { response ->
            if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
            val body = response.body
            val total = release.size.takeIf { it > 0 } ?: body.contentLength()
            // The checksum is worked out while the file arrives: reading 130 MB again once the bar
            // was full kept "Riavvia e aggiorna" waiting for seconds after it.
            val hash = partial.outputStream().use { out ->
                copyHashing(body.byteStream(), out) { done ->
                    if (total > 0) _state.value = State.Downloading(release.version, (done.toDouble() / total).toFloat())
                }
            }
            if (release.size > 0 && partial.length() != release.size) {
                partial.delete()
                throw IOException("The update's size doesn't match")
            }
            if (hash != release.sha256) {
                partial.delete()
                throw IOException("The update's checksum doesn't match")
            }
        }
        Files.move(partial.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
        // Older installers are no longer needed.
        Paths.updates.listFiles()?.filter { it != target }?.forEach { it.delete() }
        return target
    }

    /** Copies [input] to [out], telling [progress] the bytes copied so far; returns their SHA-256. */
    fun copyHashing(input: java.io.InputStream, out: java.io.OutputStream, progress: (Long) -> Unit = {}): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var done = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            out.write(buffer, 0, count)
            digest.update(buffer, 0, count)
            done += count
            progress(done)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Runs the checked installer silently (it closes this app, installs over it keeping the
     * library, and opens it again). Returns false when there is nothing to install.
     */
    fun installNow(): Boolean {
        val ready = _state.value as? State.Ready ?: return false
        if (!System.getProperty("os.name").orEmpty().lowercase().contains("win")) return false
        // Checked once more right before running: the file is ours, unchanged since the download.
        val expected = lastRelease?.sha256 ?: return false
        if (!ready.file.isFile || sha256(ready.file) != expected) return false
        ProcessBuilder(ready.file.absolutePath, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CLOSEAPPLICATIONS", "/SEAGLASSUPDATE=1")
            .inheritIO().start()
        return true
    }

    @Volatile private var lastRelease: Release? = null
}
