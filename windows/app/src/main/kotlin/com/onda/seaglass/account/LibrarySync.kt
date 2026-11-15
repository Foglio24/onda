package com.onda.seaglass.account

import com.onda.seaglass.BuildConfig
import com.onda.seaglass.core.Http
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.LocalLibrary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.UUID

/**
 * Pushes and pulls the library record (liked, playlists, history, preferences) against
 * `PUT/GET /v1/sync/library/library`, with the same revision / operationId rules as on iPhone.
 * Full three-way merge (`LibraryMerge`) lands next; for now a 409 retries once with the server record.
 */
object LibrarySync {
    private val origin = BuildConfig.ACCOUNT_ORIGIN.trimEnd('/')

    suspend fun pushAndPull() = withContext(Dispatchers.IO) {
        val token = SecureStore.readToken() ?: return@withContext
        Account.setSyncState(Account.SyncState.Syncing)
        try {
            val get = runCatching {
                JSONObject(Http.text(Http.jsonRequest("$origin/v1/sync/library/library", bearer = token)))
            }.getOrNull()
            val serverRevision = get?.optLong("revision") ?: 0L
            get?.optJSONObject("body")?.let { Library.applyServerBody(it) }
            val body = LocalLibrary.snapshot()
            val payload = JSONObject()
                .put("revision", serverRevision)
                .put("operationId", UUID.randomUUID().toString())
                .put("body", body)
            try {
                Http.text(
                    Http.jsonRequest(
                        "$origin/v1/sync/library/library",
                        method = "PUT",
                        json = payload.toString(),
                        bearer = token,
                    )
                )
            } catch (e: Exception) {
                if (e.message?.contains("409") == true) {
                    val again = JSONObject(Http.text(Http.jsonRequest("$origin/v1/sync/library/library", bearer = token)))
                    again.optJSONObject("body")?.let { Library.applyServerBody(it) }
                } else {
                    throw e
                }
            }
            Library.reload()
            Account.setSyncState(Account.SyncState.Idle)
        } catch (e: Exception) {
            Account.setSyncState(Account.SyncState.Failed(e.message ?: e.toString()))
        }
    }
}
