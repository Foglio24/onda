package com.onda.seaglass.spotify

import com.onda.seaglass.core.Http
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * A minimal Chrome DevTools Protocol client over one WebSocket (a page target of Edge). Commands
 * return their `result`; events go to [onEvent] on OkHttp's thread, so handlers must be quick and
 * thread-safe.
 */
class Cdp private constructor(private val socket: WebSocket, private val listener: Listener) {
    var onEvent: (method: String, params: JSONObject) -> Unit
        get() = listener.onEvent
        set(value) { listener.onEvent = value }

    suspend fun send(method: String, params: JSONObject = JSONObject(), timeoutMs: Long = 15_000): JSONObject {
        val id = listener.ids.incrementAndGet()
        val reply = CompletableDeferred<JSONObject>()
        listener.pending[id] = reply
        if (!socket.send(JSONObject().put("id", id).put("method", method).put("params", params).toString())) {
            listener.pending.remove(id)
            throw IOException("CDP: connection closed")
        }
        val message = try {
            withTimeout(timeoutMs) { reply.await() }
        } finally {
            listener.pending.remove(id)
        }
        message.optJSONObject("error")?.let { throw IOException("CDP $method: ${it.optString("message")}") }
        return message.optJSONObject("result") ?: JSONObject()
    }

    fun close() {
        socket.close(1000, null)
    }

    private class Listener : WebSocketListener() {
        val ids = AtomicInteger()
        val pending = ConcurrentHashMap<Int, CompletableDeferred<JSONObject>>()
        val opened = CompletableDeferred<Unit>()
        @Volatile var onEvent: (String, JSONObject) -> Unit = { _, _ -> }

        override fun onOpen(webSocket: WebSocket, response: Response) {
            opened.complete(Unit)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val message = runCatching { JSONObject(text) }.getOrNull() ?: return
            if (message.has("id")) {
                pending[message.optInt("id")]?.complete(message)
            } else {
                runCatching { onEvent(message.optString("method"), message.optJSONObject("params") ?: JSONObject()) }
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            val error = IOException("CDP: ${t.message}", t)
            opened.completeExceptionally(error)
            pending.values.forEach { it.completeExceptionally(error) }
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            val error = IOException("CDP: connection closed")
            pending.values.forEach { it.completeExceptionally(error) }
        }
    }

    companion object {
        /** Connects to [webSocketUrl] (a target's `webSocketDebuggerUrl`, always on 127.0.0.1). */
        suspend fun connect(webSocketUrl: String): Cdp {
            val listener = Listener()
            // No Origin header: Edge only refuses DevTools connections that send one it doesn't allow.
            // No read timeout: the page can stay quiet for long stretches while someone types a password.
            val client = Http.client.newBuilder().readTimeout(0, TimeUnit.MILLISECONDS).build()
            val socket = client.newWebSocket(Request.Builder().url(webSocketUrl).build(), listener)
            withTimeout(10_000) { listener.opened.await() }
            return Cdp(socket, listener)
        }
    }
}
