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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asComposeImageBitmap
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

    /**
     * A video's thumbnail is a 4:3 picture with the 16:9 frame between black bands; shown square,
     * the bands would show too. They're cut away, leaving the frame.
     */
    private fun withoutLetterbox(image: ImageBitmap): ImageBitmap {
        val width = image.width
        val height = image.height
        if (width < 32 || height < 32 || kotlin.math.abs(width.toFloat() / height - 4f / 3f) > 0.05f) return image
        val pixels = image.toPixelMap()
        val band = ((height - width * 9 / 16) / 2).coerceAtLeast(1)
        fun dark(y: Int): Boolean {
            var sum = 0f
            var x = 0
            var count = 0
            while (x < width) {
                val pixel = pixels[x, y]
                sum += (pixel.red + pixel.green + pixel.blue) / 3
                x += 4
                count++
            }
            return sum / count < 0.06f
        }
        if (!(dark(band / 2) && dark(height - 1 - band / 2) && dark(1) && dark(height - 2))) return image
        val frame = height - band * 2
        val buffer = IntArray(width * frame)
        image.readPixels(buffer, startX = 0, startY = band, width = width, height = frame)
        val bitmap = org.jetbrains.skia.Bitmap()
        bitmap.allocN32Pixels(width, frame)
        val bytes = java.nio.ByteBuffer.allocate(buffer.size * 4).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        buffer.forEach { bytes.putInt(it) }
        bitmap.installPixels(bytes.array())
        return bitmap.asComposeImageBitmap()
    }

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
                bytes?.let { runCatching { withoutLetterbox(SkiaImage.makeFromEncoded(it).toComposeImageBitmap()) }.getOrNull() }?.also { memory[url] = it }
            }
        }
    }
}

/**
 * The colour a cover is mostly made of, darkened enough for white text over it (the full player's
 * and the pages' backgrounds, as on Spotify); null until the cover is in.
 */
object CoverColors {
    private val known = java.util.concurrent.ConcurrentHashMap<String, Color>()

    fun cached(url: String?): Color? = url?.let { known[it] }

    suspend fun of(url: String?): Color? {
        if (url == null) return null
        known[url]?.let { return it }
        val bitmap = ImageLoader.load(url) ?: return null
        val color = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
            val pixels = bitmap.toPixelMap()
            var red = 0.0
            var green = 0.0
            var blue = 0.0
            var weight = 0.0
            val step = maxOf(1, minOf(pixels.width, pixels.height) / 48)
            for (y in 0 until pixels.height step step) for (x in 0 until pixels.width step step) {
                val pixel = pixels[x, y]
                // Saturated pixels count more: a grey border shouldn't win over the picture.
                val max = maxOf(pixel.red, pixel.green, pixel.blue)
                val min = minOf(pixel.red, pixel.green, pixel.blue)
                val w = 0.15 + (max - min)
                red += pixel.red * w
                green += pixel.green * w
                blue += pixel.blue * w
                weight += w
            }
            if (weight == 0.0) return@withContext null
            var c = Color((red / weight).toFloat(), (green / weight).toFloat(), (blue / weight).toFloat())
            // Dark enough for white text on it (a luminance of 0.18 at most).
            val luminance = c.luminance()
            if (luminance > 0.18f) {
                val factor = kotlin.math.sqrt(0.18f / luminance)
                c = Color(c.red * factor, c.green * factor, c.blue * factor)
            }
            c
        } ?: return null
        known[url] = color
        return color
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
