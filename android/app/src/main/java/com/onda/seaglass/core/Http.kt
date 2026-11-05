package com.onda.seaglass.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class HttpException(val status: Int) : IOException("HTTP $status")

/** One OkHttp client for the whole app (API calls, artwork and audio share its connections). */
object Http {
    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    /** Runs [request] off the main thread; the response body is read by [read]. */
    suspend fun <T> send(request: Request, read: (Response) -> T): T = withContext(Dispatchers.IO) {
        val call = client.newCall(request)
        val response = suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) = continuation.resumeWithException(e)
                override fun onResponse(call: Call, response: Response) = continuation.resume(response)
            })
        }
        response.use(read)
    }

    suspend fun text(request: Request): String = send(request) { response ->
        if (!response.isSuccessful) throw HttpException(response.code)
        response.body.string()
    }
}
