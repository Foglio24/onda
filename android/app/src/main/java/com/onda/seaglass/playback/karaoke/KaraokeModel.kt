package com.onda.seaglass.playback.karaoke

import android.content.Context
import com.onda.seaglass.core.Http
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.security.MessageDigest
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

    /** The model's file, downloaded now if it isn't there; [progress] gets the share downloaded (0…1). */
    suspend fun ensure(context: Context, progress: (Double) -> Unit): File = withContext(Dispatchers.IO) {
        val file = file(context)
        if (file.length() == SIZE) return@withContext file
        file.parentFile?.mkdirs()
        val part = File(file.parentFile, "$FILE_NAME.part")
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            Http.client.newCall(Request.Builder().url(URL).build()).execute().use { response ->
                if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
                response.body.byteStream().use { input ->
                    part.outputStream().use { output ->
                        val buffer = ByteArray(256 * 1024)
                        var done = 0L
                        var reported = -1
                        while (true) {
                            coroutineContext.ensureActive()
                            val read = input.read(buffer)
                            if (read < 0) break
                            output.write(buffer, 0, read)
                            digest.update(buffer, 0, read)
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
            val sum = digest.digest().joinToString("") { "%02x".format(it) }
            if (part.length() != SIZE || sum != SHA256) throw IOException("The model's checksum doesn't match")
            if (!part.renameTo(file)) throw IOException("Couldn't keep the model")
            file
        } finally {
            part.delete()
        }
    }
}
