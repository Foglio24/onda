package com.onda.seaglass.playback.karaoke

import android.content.Context
import com.onda.seaglass.core.Http
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.coroutines.coroutineContext

/**
 * The karaoke's vocal model, UVR MDX-Net "Voc_FT" as sherpa-onnx publishes it (the one the iPhone app
 * converts for Core ML): 64 MB, downloaded once, the first time karaoke is used, rather than in every
 * copy of the app. Its checksum is checked before it's kept.
 */
object KaraokeModel {
    const val URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/source-separation-models/UVR-MDX-NET-Voc_FT.onnx"
    const val SHA256 = "e411182ce2c53541fefdcc99a8f46f2fe03978eb22038b9497c1d9d95a00fad4"
    const val SIZE = 66_762_795L
    const val FILE_NAME = "UVR-MDX-NET-Voc_FT.onnx"

    fun file(context: Context): File = File(context.filesDir, "karaoke/$FILE_NAME")

    fun isReady(context: Context): Boolean = file(context).length() == SIZE

    /**
     * The model's file, downloaded now if it isn't there; [progress] gets the share downloaded (0…1).
     * A download cut off (a slow or dropped connection) is tried again from where it stopped, a few
     * times; the whole file's checksum is checked at the end.
     */
    suspend fun ensure(context: Context, progress: (Double) -> Unit): File = withContext(Dispatchers.IO) {
        val file = file(context)
        if (file.length() == SIZE) return@withContext file
        file.parentFile?.mkdirs()
        val part = File(file.parentFile, "$FILE_NAME.part")
        if (part.length() > SIZE) part.delete()
        val client = Http.client.newBuilder().readTimeout(60, TimeUnit.SECONDS).build()
        var attempt = 0
        while (part.length() < SIZE) {
            coroutineContext.ensureActive()
            val before = part.length()
            val failure = try {
                download(client, part, progress)
                null
            } catch (e: IOException) {
                e
            }
            // Cut off, or nothing more arrived: again after a moment, a few times.
            if (failure != null || part.length() <= before) {
                if (++attempt >= 5) throw failure ?: IOException("The model's download stopped")
                delay(2_000L * attempt)
            }
        }
        val sum = part.inputStream().use { input ->
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(256 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
            digest.digest().joinToString("") { "%02x".format(it) }
        }
        if (sum != SHA256) {
            part.delete()
            throw IOException("The model's checksum doesn't match")
        }
        if (!part.renameTo(file)) throw IOException("Couldn't keep the model")
        file
    }

    /** Appends the rest of the model to [part], from its length on. */
    private suspend fun download(client: OkHttpClient, part: File, progress: (Double) -> Unit) {
        val from = part.length()
        val request = Request.Builder().url(URL).apply { if (from > 0) header("Range", "bytes=$from-") }.build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
            // A server that ignores the range sends the whole file again.
            val append = from > 0 && response.code == 206
            response.body.byteStream().use { input ->
                FileOutputStream(part, append).use { output ->
                    val buffer = ByteArray(256 * 1024)
                    var done = if (append) from else 0L
                    var reported = -1
                    while (true) {
                        coroutineContext.ensureActive()
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        done += read
                        if (done > SIZE) throw IOException("The model is larger than expected")
                        val percent = (done * 100 / SIZE).toInt()
                        if (percent != reported) {
                            reported = percent
                            progress(done.toDouble() / SIZE)
                        }
                    }
                }
            }
        }
    }
}
