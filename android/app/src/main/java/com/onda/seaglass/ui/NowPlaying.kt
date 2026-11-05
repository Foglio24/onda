package com.onda.seaglass.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.basicMarquee
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.Lyrics
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.RepeatOne
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.Player
import coil3.compose.AsyncImage
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.Lyrics
import com.onda.seaglass.data.LyricsState
import com.onda.seaglass.data.Prefs
import com.onda.seaglass.data.Streams
import com.onda.seaglass.model.Track
import com.onda.seaglass.model.formatDuration
import com.onda.seaglass.playback.PlaybackEvents
import com.onda.seaglass.playback.PlayerController
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

private enum class Panel { ARTWORK, LYRICS, QUEUE }

/** The player, full screen: the artwork's colours behind glass controls, with lyrics and the queue. */
@Composable
fun NowPlayingScreen(startWithLyrics: Boolean, onClose: () -> Unit) {
    val state by PlayerController.state.collectAsStateWithLifecycle()
    val track = state.current ?: return
    val haze = rememberHazeState()
    var panel by remember { mutableStateOf(if (startWithLyrics) Panel.LYRICS else Panel.ARTWORK) }
    var dragOffset by remember { mutableFloatStateOf(0f) }
    val density = LocalDensity.current

    var position by remember { mutableLongStateOf(PlayerController.positionMs) }
    LaunchedEffect(state.isPlaying, track.videoId) {
        while (true) {
            position = PlayerController.positionMs
            if (!state.isPlaying) break
            delay(200)
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .offset { IntOffset(0, dragOffset.roundToInt().coerceAtLeast(0)) }
            .background(Background),
    ) {
        PlayerBackground(track, haze)
        CompositionLocalProvider(LocalHazeState provides haze) {
            BoxWithConstraints(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
                val wide = maxWidth > maxHeight && maxWidth >= 600.dp
                Column(Modifier.fillMaxSize()) {
                    TopBar(
                        onClose = onClose,
                        modifier = Modifier.pointerInput(Unit) {
                            detectVerticalDragGestures(
                                onDragEnd = {
                                    if (dragOffset > with(density) { 140.dp.toPx() }) onClose()
                                    dragOffset = 0f
                                },
                                onDragCancel = { dragOffset = 0f },
                            ) { _, amount -> dragOffset = (dragOffset + amount).coerceAtLeast(0f) }
                        },
                        track = track,
                    )
                    if (wide) {
                        Row(Modifier.fillMaxSize().padding(horizontal = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.weight(1f).fillMaxHeight().padding(vertical = 8.dp), contentAlignment = Alignment.Center) {
                                PanelContent(panel, track, position, state)
                            }
                            Spacer(Modifier.width(32.dp))
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.Center) {
                                Controls(track, position, state, panel) { panel = if (panel == it) Panel.ARTWORK else it }
                            }
                        }
                    } else {
                        Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 24.dp), contentAlignment = Alignment.Center) {
                            PanelContent(panel, track, position, state)
                        }
                        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 12.dp)) {
                            Controls(track, position, state, panel) { panel = if (panel == it) Panel.ARTWORK else it }
                        }
                    }
                }
            }
        }
    }
}

/** The artwork, blurred and enlarged behind everything (and refracted by the glass controls). */
@Composable
private fun PlayerBackground(track: Track, haze: HazeState) {
    val color by PlayerController.artworkColor.collectAsStateWithLifecycle()
    val tint = color ?: LocalAccent.current
    Box(Modifier.fillMaxSize().hazeSource(haze)) {
        AsyncImage(
            model = track.mediumArtwork,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize().scale(1.6f).blur(90.dp),
        )
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0f to tint.copy(alpha = 0.35f),
                    0.5f to Color.Black.copy(alpha = 0.35f),
                    1f to Color.Black.copy(alpha = 0.7f),
                ),
            ),
        )
    }
}

@Composable
private fun TopBar(onClose: () -> Unit, track: Track, modifier: Modifier = Modifier) {
    val app = LocalApp.current
    Row(modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        GlassSurface(Modifier.size(44.dp), corner = 22.dp) {
            IconButton(onClick = onClose, modifier = Modifier.fillMaxSize()) { Icon(Icons.Rounded.KeyboardArrowDown, null) }
        }
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            Box(Modifier.size(width = 36.dp, height = 5.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.35f)))
            Spacer(Modifier.height(6.dp))
            Text(tr("In riproduzione"), fontSize = 12.sp, color = Color.White.copy(alpha = 0.7f), fontWeight = FontWeight.SemiBold)
        }
        GlassSurface(Modifier.size(44.dp), corner = 22.dp) {
            IconButton(onClick = { app.showMenu(track) }, modifier = Modifier.fillMaxSize()) { Icon(Icons.Rounded.MoreHoriz, tr("Altro")) }
        }
    }
}

@Composable
private fun PanelContent(panel: Panel, track: Track, position: Long, state: PlayerController.State) {
    AnimatedContent(panel, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "panel") { shown ->
        when (shown) {
            Panel.ARTWORK -> {
                val scale by animateFloatAsState(if (state.isPlaying) 1f else 0.86f, label = "artwork")
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Artwork(
                        track.largeArtwork,
                        Modifier
                            .widthIn(max = 520.dp)
                            .fillMaxWidth()
                            .aspectRatio(1f)
                            .scale(scale)
                            .shadow(24.dp, RoundedCornerShape(18.dp), ambientColor = Color.Black, spotColor = Color.Black),
                        RoundedCornerShape(18.dp),
                    )
                }
            }
            Panel.LYRICS -> LyricsPanel(track, position)
            Panel.QUEUE -> QueuePanel(state)
        }
    }
}

@Composable
private fun Controls(track: Track, position: Long, state: PlayerController.State, panel: Panel, onPanel: (Panel) -> Unit) {
    val app = LocalApp.current
    val accent = LocalAccent.current
    val liked by Library.liked.collectAsStateWithLifecycle()
    val isLiked = liked.any { it.videoId == track.videoId }
    var timerDialog by remember { mutableStateOf(false) }
    val timer by PlayerController.sleepTimer.collectAsStateWithLifecycle()

    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(
                track.title, fontSize = 22.sp, fontWeight = FontWeight.Bold, maxLines = 1,
                modifier = Modifier.basicMarquee(),
            )
            Text(
                track.artist, fontSize = 17.sp, color = Color.White.copy(alpha = 0.7f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.clickable { track.artistId?.let { app.open("artist/$it") } ?: app.showMenu(track) },
            )
        }
        IconButton(onClick = { Library.toggleLike(track) }) {
            Icon(
                if (isLiked) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                tr("Mi piace"), tint = if (isLiked) accent else Color.White, modifier = Modifier.size(28.dp),
            )
        }
    }
    Spacer(Modifier.height(16.dp))
    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
        Scrubber(position, state.durationMs, track.videoId)
        Spacer(Modifier.height(12.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = PlayerController::toggleShuffle) {
                Icon(Icons.Rounded.Shuffle, tr("Casuale"), tint = if (state.shuffle) accent else Color.White.copy(alpha = 0.75f))
            }
            IconButton(onClick = PlayerController::previous, modifier = Modifier.size(64.dp)) {
                Icon(Icons.Rounded.SkipPrevious, tr("Brano precedente"), modifier = Modifier.size(44.dp))
            }
            GlassSurface(Modifier.size(80.dp), corner = 40.dp, tint = Color.White.copy(alpha = 0.10f)) {
                Box(Modifier.fillMaxSize().clickable(onClick = PlayerController::toggle), contentAlignment = Alignment.Center) {
                    if (state.isBuffering && state.isPlaying) {
                        CircularProgressIndicator(color = Color.White, strokeWidth = 3.dp, modifier = Modifier.size(36.dp))
                    } else {
                        Icon(
                            if (state.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                            tr("Riproduci o metti in pausa"), modifier = Modifier.size(48.dp),
                        )
                    }
                }
            }
            IconButton(onClick = PlayerController::next, modifier = Modifier.size(64.dp)) {
                Icon(Icons.Rounded.SkipNext, tr("Brano successivo"), modifier = Modifier.size(44.dp))
            }
            IconButton(onClick = PlayerController::cycleRepeat) {
                Icon(
                    if (state.repeatMode == Player.REPEAT_MODE_ONE) Icons.Rounded.RepeatOne else Icons.Rounded.Repeat,
                    null,
                    tint = if (state.repeatMode != Player.REPEAT_MODE_OFF) accent else Color.White.copy(alpha = 0.75f),
                )
            }
        }
    }
    Spacer(Modifier.height(18.dp))
    GlassSurface(Modifier.fillMaxWidth().height(56.dp), corner = 28.dp) {
        Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
            PanelButton(Icons.Rounded.Lyrics, tr("Testi"), panel == Panel.LYRICS) { onPanel(Panel.LYRICS) }
            PanelButton(Icons.Rounded.Bedtime, tr("Timer di spegnimento"), timer != null) { timerDialog = true }
            PanelButton(Icons.AutoMirrored.Rounded.QueueMusic, tr("Coda"), panel == Panel.QUEUE) { onPanel(Panel.QUEUE) }
        }
    }
    if (timerDialog) SleepTimerDialog { timerDialog = false }
}

@Composable
private fun PanelButton(icon: ImageVector, description: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(48.dp).clip(CircleShape).background(Color.White.copy(alpha = if (selected) 0.18f else 0f)).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, description, tint = if (selected) LocalAccent.current else Color.White, modifier = Modifier.size(24.dp))
    }
}

/** The song's progress: drag or tap to move through it; the audio format sits in the middle. */
@Composable
private fun Scrubber(position: Long, duration: Long, videoId: String) {
    var dragging by remember { mutableStateOf<Float?>(null) }
    var width by remember { mutableFloatStateOf(1f) }
    val fraction = dragging ?: if (duration > 0) (position.toFloat() / duration).coerceIn(0f, 1f) else 0f
    val height by animateDpAsState(if (dragging != null) 10.dp else 6.dp, label = "scrubber")
    Box(
        Modifier
            .fillMaxWidth()
            .height(28.dp)
            .pointerInput(duration) {
                width = size.width.toFloat()
                detectTapGestures { offset -> if (duration > 0) PlayerController.seek((offset.x / size.width * duration).toLong()) }
            }
            .pointerInput(duration) {
                detectHorizontalDragGestures(
                    onDragStart = { offset -> dragging = (offset.x / size.width).coerceIn(0f, 1f) },
                    onDragEnd = {
                        dragging?.let { if (duration > 0) PlayerController.seek((it * duration).toLong()) }
                        dragging = null
                    },
                    onDragCancel = { dragging = null },
                ) { change, _ -> dragging = (change.position.x / size.width).coerceIn(0f, 1f) }
            },
        contentAlignment = Alignment.CenterStart,
    ) {
        Box(Modifier.fillMaxWidth().height(height).clip(CircleShape).background(Color.White.copy(alpha = 0.2f))) {
            Box(Modifier.fillMaxWidth(fraction).fillMaxHeight().background(Color.White.copy(alpha = 0.9f)))
        }
    }
    val shown = dragging?.let { (it * duration).toLong() } ?: position
    val label = remember(videoId, duration) { Streams.current(videoId)?.label }
    Row(Modifier.fillMaxWidth()) {
        Text(formatDuration(shown / 1000.0), fontSize = 12.sp, color = Color.White.copy(alpha = 0.6f))
        Text(
            label.orEmpty(), Modifier.weight(1f), fontSize = 11.sp, color = Color.White.copy(alpha = 0.45f),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center, fontWeight = FontWeight.SemiBold,
        )
        Text("-" + formatDuration(((duration - shown) / 1000.0).coerceAtLeast(0.0)), fontSize = 12.sp, color = Color.White.copy(alpha = 0.6f))
    }
}

@Composable
private fun LyricsPanel(track: Track, position: Long) {
    val (load, _) = rememberLoad(track.videoId) { Lyrics.lyrics(track) }
    val lyrics = (load as? Load.Done)?.value
    Box(Modifier.fillMaxSize()) {
        when (lyrics) {
            null -> Loading(Modifier.align(Alignment.Center))
            is LyricsState.Synced -> SyncedLyrics(lyrics, position)
            is LyricsState.Plain -> Text(
                lyrics.text, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, lineHeight = 30.sp,
                modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = 16.dp),
            )
            else -> Message(tr("Testo non disponibile"), tr("LRCLIB non ha il testo di questo brano."), Modifier.align(Alignment.Center))
        }
    }
}

@Composable
private fun SyncedLyrics(lyrics: LyricsState.Synced, position: Long) {
    val seconds = position / 1000.0 + 0.25
    val current = lyrics.lines.indexOfLast { it.time <= seconds }
    val list = rememberLazyListState()
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val third = with(LocalDensity.current) { (maxHeight / 3).roundToPx() }
        LaunchedEffect(current) {
            if (current >= 0) list.animateScrollToItem(current, -third)
        }
        LazyColumn(state = list, contentPadding = PaddingValues(vertical = maxHeight / 2)) {
            itemsIndexed(lyrics.lines, key = { index, _ -> index }) { index, line ->
                val active = index == current
                val alpha by animateFloatAsState(if (active) 1f else 0.35f, label = "line")
                Text(
                    line.text.ifEmpty { "♪" },
                    fontSize = 27.sp,
                    lineHeight = 34.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White.copy(alpha = alpha),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .clickable { PlayerController.seek((line.time * 1000).toLong()) }
                        .padding(vertical = 10.dp, horizontal = 4.dp),
                )
            }
        }
    }
}

@Composable
private fun QueuePanel(state: PlayerController.State) {
    val autoRadio by Prefs.autoRadio.collectAsStateWithLifecycle()
    val radioLoading by PlaybackEvents.radioLoading.collectAsStateWithLifecycle()
    val accent = LocalAccent.current
    GlassSurface(Modifier.fillMaxSize().padding(vertical = 8.dp), corner = 24.dp, tint = Color.Black.copy(alpha = 0.15f)) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.padding(start = 16.dp, end = 12.dp, top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(tr("Prossimi brani"), style = SectionTitle, modifier = Modifier.weight(1f))
                if (state.upNext.isNotEmpty()) {
                    TextButton(onClick = PlayerController::clearUpNext) { Text(tr("Svuota"), color = accent) }
                }
            }
            Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(tr("Radio automatica"), Modifier.weight(1f), fontSize = 15.sp, color = Color.White.copy(alpha = 0.85f))
                if (radioLoading) CircularProgressIndicator(Modifier.size(18.dp).padding(end = 8.dp), color = accent, strokeWidth = 2.dp)
                Switch(
                    checked = autoRadio, onCheckedChange = Prefs::setAutoRadio,
                    colors = SwitchDefaults.colors(checkedTrackColor = accent),
                )
            }
            if (state.upNext.isEmpty()) {
                Message(
                    tr("La coda è vuota"),
                    if (autoRadio) tr("Con la radio automatica arriveranno brani simili.") else tr("Aggiungi brani dal menu ··· di ogni canzone."),
                )
            } else {
                LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 12.dp)) {
                    itemsIndexed(state.upNext, key = { index, track -> "$index" + track.videoId }) { offset, track ->
                        val index = state.index + 1 + offset
                        Row(
                            Modifier.fillMaxWidth().clickable { PlayerController.skipTo(index) }.padding(start = 16.dp, end = 4.dp, top = 6.dp, bottom = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Artwork(track.mediumArtwork, Modifier.size(44.dp), RoundedCornerShape(6.dp))
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(track.title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                                Text(track.artist, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 13.sp, color = Secondary)
                            }
                            IconButton(onClick = { PlayerController.removeFromQueue(index) }) {
                                Icon(Icons.Rounded.Close, tr("Rimuovi"), tint = Secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SleepTimerDialog(onDismiss: () -> Unit) {
    val timer by PlayerController.sleepTimer.collectAsStateWithLifecycle()
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF1C1C24),
        title = { Text(tr("Timer di spegnimento")) },
        text = {
            Column {
                listOf(15, 30, 45, 60).forEach { minutes ->
                    TextButton(onClick = { PlayerController.setSleepTimer(minutes); onDismiss() }, modifier = Modifier.fillMaxWidth()) {
                        Text(tr("%lld minuti", minutes), Modifier.fillMaxWidth(), color = Color.White)
                    }
                }
                TextButton(onClick = { PlayerController.setSleepTimer(-1); onDismiss() }, modifier = Modifier.fillMaxWidth()) {
                    Text(tr("Fine del brano"), Modifier.fillMaxWidth(), color = Color.White)
                }
                if (timer != null) {
                    TextButton(onClick = { PlayerController.setSleepTimer(null); onDismiss() }, modifier = Modifier.fillMaxWidth()) {
                        Text(tr("Disattiva timer"), Modifier.fillMaxWidth(), color = Color(0xFFFF6B6B))
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(tr("Annulla")) } },
    )
}
