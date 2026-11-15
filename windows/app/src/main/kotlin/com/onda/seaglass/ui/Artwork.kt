package com.onda.seaglass.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.onda.seaglass.core.Http
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.jetbrains.skia.Image as SkiaImage

@Composable
fun Artwork(url: String?, size: Dp = 48.dp, corner: Dp = 6.dp) {
    var bitmap by remember(url) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(url) {
        bitmap = null
        if (url.isNullOrBlank()) return@LaunchedEffect
        bitmap = withContext(Dispatchers.IO) { loadBitmap(url) }
    }
    Box(
        Modifier
            .size(size)
            .clip(RoundedCornerShape(corner))
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)),
    ) {
        bitmap?.let {
            Image(it, contentDescription = null, modifier = Modifier.size(size), contentScale = ContentScale.Crop)
        }
    }
}

private fun loadBitmap(url: String): ImageBitmap? = runCatching {
    val request = Request.Builder().url(url).build()
    Http.client.newCall(request).execute().use { response ->
        if (!response.isSuccessful) return null
        val bytes = response.body?.bytes() ?: return null
        SkiaImage.makeFromEncoded(bytes).toComposeImageBitmap()
    }
}.getOrNull()
