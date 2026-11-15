package com.onda.seaglass.core

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/** Shared HTTP client with the same spirit as the other apps (timeouts, no tracking). */
object Http {
    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .callTimeout(90, TimeUnit.SECONDS)
        .build()

    private val jsonType = "application/json; charset=utf-8".toMediaType()

    fun text(request: Request): String {
        client.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) error("HTTP ${response.code}: ${body.take(200)}")
            return body
        }
    }

    fun jsonRequest(url: String, method: String = "GET", json: String? = null, bearer: String? = null): Request {
        val builder = Request.Builder().url(url).header("Accept", "application/json")
        if (bearer != null) builder.header("Authorization", "Bearer $bearer")
        when (method) {
            "GET" -> builder.get()
            "DELETE" -> builder.delete()
            else -> builder.method(method, (json ?: "{}").toRequestBody(jsonType))
        }
        return builder.build()
    }
}
