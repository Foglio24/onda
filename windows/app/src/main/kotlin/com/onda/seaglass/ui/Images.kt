package com.onda.seaglass.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.layout.ContentScale
import com.onda.seaglass.core.Http
import com.onda.seaglass.core.Paths
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.jetbrains.skia.Image as SkiaImage
import java.io.File
import java.security.MessageDigest
import java.util.Collections

/**
 * Covers and photos: fetched once, kept on disk (Cache\Images) and the last few hundred in memory,
 * scaled down to what is shown. Only HTTPS addresses are fetched.
 */
object ImageLoader {
    private val memory: MutableMap<String, ImageBitmap> = Collections.synchronizedMap(object : LinkedHashMap<String, ImageBitmap>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ImageBitmap>?) = size > 300
    })
    private val limit = Semaphore(6)
    private val directory by lazy { File(Paths.cache, "Images").apply { mkdirs() } }

    fun cached(url: String): ImageBitmap? = memory[url]

    suspend fun load(url: String): ImageBitmap? {
        memory[url]?.let { return it }
        if (!url.startsWith("https://")) return null
        return withContext(Dispatchers.IO) {
            limit.withPermit {
                val name = MessageDigest.getInstance("SHA-1").digest(url.toByteArray()).joinToString("") { "%02x".format(it) }
                val file = File(directory, name)
                val bytes = if (file.isFile) file.readBytes() else runCatching {
                    Http.client.newCall(Request.Builder().url(url).build()).execute().use { response ->
                        if (!response.isSuccessful) return@use null
                        val body = response.body.bytes()
                        // A cover is a few hundred kilobytes; anything far larger isn't one.
                        if (body.size > 8_000_000) return@use null
                        body.also { runCatching { file.writeBytes(it) } }
                    }
                }.getOrNull()
                bytes?.let { runCatching { SkiaImage.makeFromEncoded(it).toComposeImageBitmap() }.getOrNull() }?.also { memory[url] = it }
            }
        }
    }
}

/** A remote image, with a note in its place until it comes (or if it never does). */
@Composable
fun RemoteImage(url: String?, modifier: Modifier = Modifier, shape: Shape? = null, contentScale: ContentScale = ContentScale.Crop) {
    val palette = LocalPalette.current
    var image by remember(url) { mutableStateOf(url?.let { ImageLoader.cached(it) }) }
    LaunchedEffect(url) {
        if (image == null && url != null) image = ImageLoader.load(url)
    }
    val clipped = if (shape != null) modifier.clip(shape) else modifier
    Box(clipped.background(palette.cardHover), contentAlignment = Alignment.Center) {
        val bitmap = image
        if (bitmap != null) {
            Image(bitmap, null, Modifier.fillMaxSize(), contentScale = contentScale)
        } else {
            Icon(Icons.Rounded.MusicNote, null, tint = palette.tertiary)
        }
    }
}
