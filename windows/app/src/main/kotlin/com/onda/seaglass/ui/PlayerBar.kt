@file:OptIn(ExperimentalComposeUiApi::class)

package com.onda.seaglass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.automirrored.rounded.VolumeDown
import androidx.compose.material.icons.automirrored.rounded.VolumeOff
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Equalizer
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Lyrics
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.RepeatOne
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import com.onda.seaglass.audio.Player
import com.onda.seaglass.audio.isLocal
import com.onda.seaglass.core.Prefs
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Library
import com.onda.seaglass.model.formatDuration

/** The bar at the bottom of the window, as the Mac app's: the song, the controls, the volume and the panels. */
@Composable
fun PlayerBar() {
    val palette = LocalPalette.current
    val state by Player.state.collectAsState()
    val liked by Library.liked.collectAsState()
    val track = state.current
    Row(
        Modifier.fillMaxWidth().height(88.dp).background(palette.bar).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // The song: a click on the cover opens the full player.
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
            if (track != null) {
                RemoteImage(track.resized(226), Modifier.size(56.dp).clickable { Nav.fullPlayer = true }, RoundedCornerShape(6.dp))
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f, fill = false)) {
                    Text(track.title, color = palette.text, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        track.artist, color = palette.secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.clickable(enabled = !track.isLocal && track.primaryArtist.isNotEmpty()) { Nav.open(Route.Artist(track.artistId, track.primaryArtist)) },
                    )
                    val note = state.error ?: state.format
                    if (note != null) Text(note, color = if (state.error != null) Color(0xFFFF6B6B) else palette.tertiary, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (!track.isLocal) {
                    val isLiked = liked.any { it.videoId == track.videoId }
                    IconButton(onClick = { Library.toggleLike(track) }) {
                        Icon(if (isLiked) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder, tr(if (isLiked) "Rimuovi dai preferiti" else "Aggiungi ai preferiti"), tint = if (isLiked) palette.accent else palette.secondary)
                    }
                }
            }
        }
        // The controls and the scrubber.
        Column(Modifier.width(520.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                BarButton(Icons.Rounded.Shuffle, tr("Casuale"), active = state.shuffle) { Player.setShuffle(!state.shuffle) }
                BarButton(Icons.Rounded.SkipPrevious, tr("Precedente"), size = 30) { Player.previous() }
                Box(
                    Modifier.size(40.dp).clip(CircleShape).background(palette.text).clickable(enabled = track != null) { Player.toggle() },
                    contentAlignment = Alignment.Center,
                ) {
                    if (state.isLoading) {
                        CircularProgressIndicator(Modifier.size(20.dp), color = palette.page, strokeWidth = 2.dp)
                    } else {
                        Icon(if (state.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, tr(if (state.isPlaying) "Pausa" else "Riproduci"), tint = palette.page)
                    }
                }
                BarButton(Icons.Rounded.SkipNext, tr("Successivo"), size = 30) { Player.next() }
                BarButton(
                    if (state.repeat == Player.Repeat.ONE) Icons.Rounded.RepeatOne else Icons.Rounded.Repeat,
                    tr("Ripeti"), active = state.repeat != Player.Repeat.OFF,
                ) { Player.cycleRepeat() }
            }
            Scrubber(Modifier.fillMaxWidth().padding(top = 4.dp))
        }
        // The panels, the equalizer, the sleep timer and the volume.
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
            BarButton(Icons.Rounded.Lyrics, tr("Testo"), active = Nav.panel == Nav.Panel.LYRICS) {
                Nav.panel = if (Nav.panel == Nav.Panel.LYRICS) Nav.Panel.NONE else Nav.Panel.LYRICS
            }
            BarButton(Icons.AutoMirrored.Rounded.QueueMusic, tr("Coda"), active = Nav.panel == Nav.Panel.QUEUE) {
                Nav.panel = if (Nav.panel == Nav.Panel.QUEUE) Nav.Panel.NONE else Nav.Panel.QUEUE
            }
            BarButton(Icons.Rounded.Equalizer, tr("Equalizzatore"), active = Nav.current == Route.Equalizer) { Nav.open(Route.Equalizer) }
            SleepTimerButton(state.sleepAt > 0 || state.sleepAtEnd)
            VolumeControl()
        }
    }
}

@Composable
fun BarButton(icon: ImageVector, label: String, active: Boolean = false, size: Int = 22, onClick: () -> Unit) {
    val palette = LocalPalette.current
    IconButton(onClick = onClick, Modifier.size(36.dp)) {
        Icon(icon, label, Modifier.size(size.dp), tint = if (active) palette.accent else palette.secondary)
    }
}

@Composable
private fun SleepTimerButton(active: Boolean) {
    var open by remember { mutableStateOf(false) }
    Box {
        BarButton(Icons.Rounded.Bedtime, tr("Timer di spegnimento"), active = active) { open = true }
        DropdownMenu(open, { open = false }) {
            listOf(0 to tr("Disattivato"), 15 to tr("15 minuti"), 30 to tr("30 minuti"), 45 to tr("45 minuti"), 60 to tr("1 ora"), -1 to tr("Fine del brano"))
                .forEach { (minutes, label) ->
                    DropdownMenuItem(text = { Text(label) }, onClick = {
                        open = false
                        Player.setSleepTimer(minutes)
                    })
                }
        }
    }
}

/** The song's progress: drag or click to move in it; the times either side. */
@Composable
fun Scrubber(modifier: Modifier = Modifier, light: Boolean = false) {
    val palette = LocalPalette.current
    val state by Player.state.collectAsState()
    val position by Player.position.collectAsState()
    var dragging by remember { mutableStateOf<Float?>(null) }
    var hovered by remember { mutableStateOf(false) }
    val duration = state.duration
    val fraction = dragging ?: if (duration > 0) (position / duration).toFloat().coerceIn(0f, 1f) else 0f
    val textColor = if (light) Color.White.copy(alpha = 0.7f) else palette.secondary
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Text(formatDuration(if (dragging != null) dragging!! * duration else position), color = textColor, fontSize = 11.sp, modifier = Modifier.width(44.dp))
        BoxWithConstraints(
            Modifier.weight(1f).height(16.dp)
                .onPointerEvent(PointerEventType.Enter) { hovered = true }
                .onPointerEvent(PointerEventType.Exit) { hovered = false }
                .pointerInput(duration) {
                    detectTapGestures { offset ->
                        if (duration > 0) Player.seek((offset.x / size.width).coerceIn(0f, 1f) * duration)
                    }
                }
                .pointerInput(duration) {
                    detectDragGestures(
                        onDragStart = { offset -> dragging = (offset.x / size.width).coerceIn(0f, 1f) },
                        onDragEnd = {
                            dragging?.let { if (duration > 0) Player.seek(it * duration) }
                            dragging = null
                        },
                        onDragCancel = { dragging = null },
                    ) { change, _ ->
                        dragging = (change.position.x / size.width).coerceIn(0f, 1f)
                        change.positionChange()
                    }
                },
            contentAlignment = Alignment.CenterStart,
        ) {
            val track = if (light) Color.White.copy(alpha = 0.25f) else palette.separator
            val fill = if (light) Color.White else if (hovered || dragging != null) palette.accent else palette.text
            Box(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)).background(track))
            Box(Modifier.fillMaxWidth(fraction).height(4.dp).clip(RoundedCornerShape(2.dp)).background(fill))
            if (hovered || dragging != null) {
                Box(Modifier.padding(start = (maxWidth * fraction - 6.dp).coerceAtLeast(0.dp)).size(12.dp).clip(CircleShape).background(fill))
            }
        }
        Text(formatDuration(duration), color = textColor, fontSize = 11.sp, modifier = Modifier.width(44.dp).padding(start = 8.dp))
    }
}

@Composable
private fun VolumeControl() {
    val palette = LocalPalette.current
    val volume by Prefs.volume.state.collectAsState()
    Row(verticalAlignment = Alignment.CenterVertically) {
        val icon = when {
            volume <= 0.001 -> Icons.AutoMirrored.Rounded.VolumeOff
            volume < 0.5 -> Icons.AutoMirrored.Rounded.VolumeDown
            else -> Icons.AutoMirrored.Rounded.VolumeUp
        }
        var before by remember { mutableStateOf(0.8) }
        BarButton(icon, tr("Volume")) {
            if (volume > 0.001) {
                before = volume
                Player.setVolume(0.0)
            } else {
                Player.setVolume(before)
            }
        }
        BoxWithConstraints(
            Modifier.width(110.dp).height(16.dp)
                .pointerInput(Unit) { detectTapGestures { Player.setVolume((it.x / size.width).toDouble()) } }
                .pointerInput(Unit) { detectDragGestures { change, _ -> Player.setVolume((change.position.x / size.width).toDouble()) } }
                // The mouse wheel moves it too.
                .onPointerEvent(PointerEventType.Scroll) { event ->
                    val delta = event.changes.firstOrNull()?.scrollDelta?.y ?: 0f
                    Player.setVolume(Prefs.volume.value - delta * 0.05)
                },
            contentAlignment = Alignment.CenterStart,
        ) {
            Box(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)).background(palette.separator))
            Box(Modifier.fillMaxWidth(volume.toFloat()).height(4.dp).clip(RoundedCornerShape(2.dp)).background(palette.text))
        }
    }
}

/** The ··· of the current song (full player). */
@Composable
fun CurrentTrackMenuButton(tint: Color) {
    val track = Player.state.collectAsState().value.current ?: return
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) { Icon(Icons.Rounded.MoreHoriz, tr("Altre opzioni"), tint = tint) }
        TrackMenu(track, open, { open = false })
    }
}

@Composable
fun FullHeightSpacer() = Spacer(Modifier.fillMaxHeight())
