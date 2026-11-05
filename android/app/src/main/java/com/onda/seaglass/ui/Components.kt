package com.onda.seaglass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyHorizontalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.onda.seaglass.core.tr
import com.onda.seaglass.model.MusicItem
import com.onda.seaglass.model.Track
import com.onda.seaglass.model.formatDuration
import com.onda.seaglass.playback.PlayerController

/** What any screen can ask of the app: open a page, the player or a song's menu, or show a note. */
interface AppActions {
    fun open(route: String)
    fun back()
    fun openPlayer()
    fun showMenu(track: Track, playlistId: String? = null, playlistIndex: Int? = null)
    fun toast(text: String)
    fun addToPlaylist(track: Track)
}

val LocalApp = staticCompositionLocalOf<AppActions> { error("No app") }

/** Room for the floating mini player and tab bar at the bottom of every screen. */
val LocalBottomPadding = staticCompositionLocalOf { 0.dp }

fun MusicItem.route(): String? = when (kind) {
    MusicItem.Kind.ARTIST -> "artist/$id"
    MusicItem.Kind.ALBUM -> "album/$id"
    MusicItem.Kind.PLAYLIST -> "playlist/$id"
    else -> null
}

@Composable
fun Artwork(
    url: String?,
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(8.dp),
    placeholder: ImageVector = Icons.Rounded.MusicNote,
) {
    Box(
        modifier
            .clip(shape)
            .background(Brush.linearGradient(listOf(Color(0xFF2B2B36), Color(0xFF1A1A22)))),
        contentAlignment = Alignment.Center,
    ) {
        Icon(placeholder, null, tint = Color.White.copy(alpha = 0.3f), modifier = Modifier.fillMaxSize(0.4f))
        if (url != null) {
            AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
    }
}

/** A song in a list: tap to play, "⋮" for every action. */
@Composable
fun TrackRow(
    track: Track,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    number: Int? = null,
    showArtwork: Boolean = true,
    playlistId: String? = null,
    playlistIndex: Int? = null,
) {
    val app = LocalApp.current
    val state by PlayerController.state.collectAsStateWithLifecycle()
    val isCurrent = state.current?.videoId == track.videoId
    val accent = LocalAccent.current
    Row(
        modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(start = 16.dp, end = 4.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (number != null) {
            Box(Modifier.width(28.dp), contentAlignment = Alignment.Center) {
                if (isCurrent) Icon(Icons.Rounded.GraphicEq, null, tint = accent, modifier = Modifier.size(18.dp))
                else Text("$number", color = Secondary, fontSize = 15.sp)
            }
            Spacer(Modifier.width(10.dp))
        }
        if (showArtwork) {
            Box {
                Artwork(track.mediumArtwork, Modifier.size(50.dp), RoundedCornerShape(6.dp))
                if (isCurrent && number == null) {
                    Box(
                        Modifier.size(50.dp).clip(RoundedCornerShape(6.dp)).background(Color.Black.copy(alpha = 0.45f)),
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.Rounded.GraphicEq, null, tint = accent) }
                }
            }
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(
                track.title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 16.sp,
                color = if (isCurrent) accent else Color.White, fontWeight = FontWeight.Medium,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                DownloadBadge(track, Modifier.padding(end = 4.dp))
                Text(
                    listOfNotNull(track.subtitle, track.duration?.let(::formatDuration)).joinToString(" · "),
                    maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 13.sp, color = Secondary,
                )
            }
        }
        IconButton(onClick = { app.showMenu(track, playlistId, playlistIndex) }) {
            Icon(Icons.Rounded.MoreVert, tr("Altro"), tint = Secondary)
        }
    }
}

@Composable
fun SectionHeader(title: String, modifier: Modifier = Modifier, action: String? = null, onAction: (() -> Unit)? = null) {
    Row(
        modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = SectionTitle, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (action != null && onAction != null) {
            TextButton(onClick = onAction) { Text(action, color = LocalAccent.current) }
        }
    }
}

/** A large title, as at the top of the iPhone app's screens. */
@Composable
fun ScreenTitle(title: String, modifier: Modifier = Modifier, trailing: @Composable () -> Unit = {}) {
    Row(
        modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MaterialTheme.typography.displaySmall, modifier = Modifier.weight(1f))
        trailing()
    }
}

/** A card of a shelf: an album, a playlist, an artist (round) or a song. */
@Composable
fun ItemCard(item: MusicItem, modifier: Modifier = Modifier, width: Dp = 150.dp) {
    val app = LocalApp.current
    val round = item.kind == MusicItem.Kind.ARTIST
    Column(
        modifier
            .width(width)
            .clip(RoundedCornerShape(12.dp))
            .clickable {
                val route = item.route()
                if (route != null) app.open(route) else item.track?.let(PlayerController::playRadio)
            },
        horizontalAlignment = if (round) Alignment.CenterHorizontally else Alignment.Start,
    ) {
        Artwork(
            item.artworkUrl,
            Modifier.fillMaxWidth().aspectRatio(1f),
            if (round) CircleShape else RoundedCornerShape(10.dp),
            if (round) Icons.Rounded.Person else Icons.Rounded.MusicNote,
        )
        Spacer(Modifier.height(8.dp))
        Text(item.title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 15.sp, fontWeight = FontWeight.Medium)
        if (item.subtitle.isNotEmpty()) {
            Text(item.subtitle, maxLines = 2, overflow = TextOverflow.Ellipsis, fontSize = 13.sp, color = Secondary)
        }
    }
}

@Composable
fun ItemShelf(title: String, items: List<MusicItem>, cardWidth: Dp = 150.dp) {
    Column {
        SectionHeader(title)
        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            items(items.distinctBy { it.kind.name + it.id }, key = { it.kind.name + it.id }) { ItemCard(it, width = cardWidth) }
        }
    }
}

/** Songs four to a column, scrolling sideways (like "Scelti per te"). */
@Composable
fun TrackGridShelf(title: String, tracks: List<Track>, onPlay: (Int) -> Unit) {
    Column {
        SectionHeader(title)
        LazyHorizontalGrid(
            rows = GridCells.Fixed(4),
            modifier = Modifier.height(248.dp),
            contentPadding = PaddingValues(end = 16.dp),
        ) {
            items(tracks.size, key = { "$it" + tracks[it].videoId }) { index ->
                TrackRow(tracks[index], onClick = { onPlay(index) }, modifier = Modifier.width(320.dp))
            }
        }
    }
}

@Composable
fun Loading(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().padding(48.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = LocalAccent.current, strokeWidth = 3.dp, modifier = Modifier.size(32.dp))
    }
}

@Composable
fun Message(title: String, detail: String? = null, modifier: Modifier = Modifier, action: String? = null, onAction: (() -> Unit)? = null) {
    Column(
        modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium, color = Color.White)
        if (detail != null) Text(detail, color = Secondary, fontSize = 14.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        if (action != null && onAction != null) TextButton(onClick = onAction) { Text(action, color = LocalAccent.current) }
    }
}

/**
 * A round back button floating over a page's header: a dark tinted disc with the glass rim, which
 * reads on any artwork (Haze can't refract a page from inside the page itself).
 */
@Composable
fun GlassBackButton(modifier: Modifier = Modifier) {
    val app = LocalApp.current
    Box(
        modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.38f))
            .border(
                0.5.dp,
                Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.35f), Color.White.copy(alpha = 0.08f))),
                CircleShape,
            )
            .clickable { app.back() },
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.AutoMirrored.Rounded.ArrowBack, null, tint = Color.White)
    }
}

/** The background of the screens: tinted by the playing song's artwork, as on the iPhone. */
@Composable
fun AmbientBackground(modifier: Modifier = Modifier) {
    val color by PlayerController.artworkColor.collectAsStateWithLifecycle()
    val dynamic by com.onda.seaglass.data.Prefs.artworkColors.collectAsStateWithLifecycle()
    val tint = (if (dynamic) color else null) ?: LocalAccent.current
    val animated by androidx.compose.animation.animateColorAsState(tint, androidx.compose.animation.core.tween(800), label = "ambient")
    Box(
        modifier
            .fillMaxSize()
            .background(Background)
            .background(
                Brush.verticalGradient(
                    0f to animated.copy(alpha = 0.45f),
                    0.35f to animated.copy(alpha = 0.12f),
                    0.7f to Color.Transparent,
                ),
            ),
    )
}
