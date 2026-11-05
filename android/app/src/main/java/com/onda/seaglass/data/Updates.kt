package com.onda.seaglass.data

import com.onda.seaglass.BuildConfig
import com.onda.seaglass.core.Http
import okhttp3.Request
import org.json.JSONArray

/**
 * New versions of the Android app, published on GitHub as pre-releases tagged `android-vX.Y.Z`
 * (so they never become the iPhone app's "latest" release).
 */
object Updates {
    data class Release(val version: String, val notes: String, val apkUrl: String?, val pageUrl: String)

    private const val RELEASES = "https://api.github.com/repos/Foglio24/onda/releases?per_page=30"

    /** The newest Android release, or null when GitHub has none. */
    suspend fun latest(): Release? {
        val request = Request.Builder().url(RELEASES).header("Accept", "application/vnd.github+json").build()
        val releases = JSONArray(Http.text(request))
        return (0 until releases.length()).map { releases.getJSONObject(it) }
            .filter { it.optString("tag_name").startsWith("android-v") && !it.optBoolean("draft") }
            .map { release ->
                val assets = release.optJSONArray("assets") ?: JSONArray()
                val apk = (0 until assets.length()).map { assets.getJSONObject(it) }
                    .firstOrNull { it.optString("name").endsWith(".apk") }
                Release(
                    version = release.optString("tag_name").removePrefix("android-v"),
                    notes = release.optString("body"),
                    apkUrl = apk?.optString("browser_download_url"),
                    pageUrl = release.optString("html_url"),
                )
            }
            .maxWithOrNull { a, b -> compare(a.version, b.version) }
    }

    fun isNewer(release: Release) = compare(release.version, BuildConfig.VERSION_NAME) > 0

    /** Compares "1.2.10" with "1.2.9" number by number. */
    fun compare(a: String, b: String): Int {
        val x = a.split('.').map { it.toIntOrNull() ?: 0 }
        val y = b.split('.').map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) {
            val difference = x.getOrElse(i) { 0 } - y.getOrElse(i) { 0 }
            if (difference != 0) return difference
        }
        return 0
    }
}
