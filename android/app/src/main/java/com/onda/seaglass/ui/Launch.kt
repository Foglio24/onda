package com.onda.seaglass.ui

import android.content.Intent
import android.net.Uri
import com.onda.seaglass.MainActivity

/**
 * Why the app was opened: from the notification (the player), from a YouTube Music link, or, for
 * the screenshots made by CI, on a given screen (`--es scene search --es query "daft punk"`).
 */
data class Launch(
    val openPlayer: Boolean = false,
    /** A navigation route to open: "artist/UC…", "album/MPREb…", "playlist/PL…". */
    val route: String? = null,
    /** A song to play, from a `watch?v=` link. */
    val videoId: String? = null,
    val scene: String? = null,
    val query: String? = null,
    val id: String = System.nanoTime().toString(),
) {
    companion object {
        fun from(intent: Intent?): Launch? {
            intent ?: return null
            intent.getStringExtra("scene")?.let { scene ->
                return Launch(scene = scene, query = intent.getStringExtra("query"), videoId = intent.getStringExtra("video"))
            }
            if (intent.getBooleanExtra(MainActivity.OPEN_PLAYER, false)) return Launch(openPlayer = true)
            val uri = intent.data ?: return null
            return fromLink(uri)
        }

        fun fromLink(uri: Uri): Launch? {
            uri.getQueryParameter("v")?.let { return Launch(videoId = it, openPlayer = true) }
            uri.getQueryParameter("list")?.let { return Launch(route = "playlist/$it") }
            val segments = uri.pathSegments
            return when {
                segments.size >= 2 && segments[0] == "browse" && segments[1].startsWith("MPREb") -> Launch(route = "album/${segments[1]}")
                segments.size >= 2 && segments[0] == "browse" && segments[1].startsWith("VL") -> Launch(route = "playlist/${segments[1]}")
                segments.size >= 2 && segments[0] == "channel" -> Launch(route = "artist/${segments[1]}")
                else -> null
            }
        }
    }
}
