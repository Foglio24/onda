package com.onda.seaglass.data

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Local library JSON (liked, playlists, history, preferences) shared with account sync. */
object LocalLibrary {
    private val file = File(System.getProperty("user.home"), "AppData/Local/Seaglass/library.json")

    @Synchronized
    fun snapshot(): JSONObject {
        if (!file.isFile) {
            return JSONObject()
                .put("liked", JSONArray())
                .put("playlists", JSONArray())
                .put("history", JSONArray())
                .put("preferences", JSONObject())
        }
        return JSONObject(file.readText())
    }

    @Synchronized
    fun mergeFromServer(body: JSONObject) {
        // Until LibraryMerge is ported: take the server body as the device's truth after a sync pull.
        file.parentFile?.mkdirs()
        file.writeText(body.toString(2))
    }

    @Synchronized
    fun save(body: JSONObject) {
        file.parentFile?.mkdirs()
        file.writeText(body.toString(2))
    }
}
