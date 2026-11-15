package com.onda.seaglass.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.Lyrics
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.audio.Player
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.LyricsState
import com.onda.seaglass.data.NowPlayingLyrics

/** The queue beside the page: what plays, what comes next (to reorder or remove), and what played. */
@Composable
fun QueuePanel() {
    val palette = LocalPalette.current
    val state by Player.state.collectAsState()
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(tr("Coda"), color = palette.text, fontWeight = FontWeight.Bold, fontSize = 20.sp, modifier = Modifier.weight(1f))
            if (state.upcoming.isNotEmpty()) {
                Text(tr("Svuota"), color = palette.accent, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.clickable { Player.clearUpcoming() })
            }
        }
        val current = state.current
        if (current == null) {
            Text(tr("La coda è vuota."), color = palette.secondary, fontSize = 13.sp, modifier = Modifier.padding(top = 20.dp))
            return@Column
        }
        Text(tr("In riproduzione"), color = palette.tertiary, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 14.dp, bottom = 6.dp))
        QueueRow(current.title, current.artist, current.resized(120), highlighted = true)
        if (!state.source.isNullOrBlank()) {
            Text(tr("Da: %@", state.source!!), color = palette.tertiary, fontSize = 11.sp, modifier = Modifier.padding(top = 4.dp))
        }
        Text(tr("Prossimi brani"), color = palette.tertiary, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 16.dp, bottom = 6.dp))
        state.nextMix?.let { mix -> Text(tr("AutoMix") + " · " + mix, color = palette.accent, fontSize = 12.sp, modifier = Modifier.padding(bottom = 6.dp)) }
        LazyColumn(Modifier.weight(1f)) {
            itemsIndexed(state.upcoming, key = { _, entry -> entry.id }) { offset, entry ->
                val index = state.index + 1 + offset
                QueueRow(
                    entry.track.title, entry.track.artist, entry.track.resized(120),
                    onClick = { Player.jump(index) },
                    actions = {
                        IconButton(onClick = { Player.move(index, index - 1) }, Modifier.size(26.dp), enabled = offset > 0) {
                            Icon(Icons.Rounded.KeyboardArrowUp, tr("Sposta su"), tint = palette.secondary)
                        }
                        IconButton(onClick = { Player.move(index, index + 1) }, Modifier.size(26.dp), enabled = index + 1 < state.queue.size) {
                            Icon(Icons.Rounded.KeyboardArrowDown, tr("Sposta giù"), tint = palette.secondary)
                        }
                        IconButton(onClick = { Player.removeFromQueue(entry.id) }, Modifier.size(26.dp)) {
                            Icon(Icons.Rounded.Close, tr("Rimuovi"), tint = palette.secondary)
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun QueueRow(title: String, subtitle: String, artwork: String?, highlighted: Boolean = false, onClick: (() -> Unit)? = null, actions: @Composable () -> Unit = {}) {
    val palette = LocalPalette.current
    Hoverable { hovered ->
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(7.dp))
                .background(if (hovered && onClick != null) palette.cardHover else Color.Transparent)
                .clickable(enabled = onClick != null) { onClick?.invoke() }
                .padding(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            RemoteImage(artwork, Modifier.size(40.dp), RoundedCornerShape(5.dp))
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(title, color = if (highlighted) palette.accent else palette.text, fontSize = 13.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(subtitle, color = palette.secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (hovered) Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) { actions() }
        }
    }
}

/**
 * The lyrics: synced ones follow the song, the line being sung large and bright, and a click on
 * a line goes there; plain ones are shown as they are. [compact] is the side panel, otherwise the
 * full player.
 */
@Composable
fun LyricsPanel(compact: Boolean, light: Boolean = false) {
    val palette = LocalPalette.current
    val lyrics by NowPlayingLyrics.state.collectAsState()
    val position by Player.position.collectAsState()
    val textColor = if (light) Color.White else palette.text
    val dim = if (light) Color.White.copy(alpha = 0.4f) else palette.tertiary
    Box(Modifier.fillMaxSize().padding(horizontal = if (compact) 16.dp else 8.dp)) {
        when (val current = lyrics) {
            LyricsState.Loading -> Text(tr("Caricamento del testo…"), color = dim, modifier = Modifier.align(Alignment.Center))
            LyricsState.Unavailable -> Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Rounded.Lyrics, null, Modifier.size(40.dp), tint = dim)
                Text(tr("Testo non disponibile"), color = dim, modifier = Modifier.padding(top = 10.dp))
            }
            is LyricsState.Plain -> Text(
                current.text, color = textColor, fontSize = if (compact) 15.sp else 20.sp, lineHeight = if (compact) 24.sp else 32.sp,
                modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = 20.dp),
            )
            is LyricsState.Synced -> {
                val lines = current.lines
                val active = lines.indexOfLast { it.time <= position + 0.25 }.coerceAtLeast(0)
                val list = rememberLazyListState()
                LaunchedEffect(active) {
                    // Keeps the line being sung a third of the way down.
                    list.animateScrollToItem(maxOf(0, active - 2))
                }
                LazyColumn(Modifier.fillMaxSize(), state = list, verticalArrangement = Arrangement.spacedBy(if (compact) 10.dp else 16.dp)) {
                    item { Spacer(Modifier.height(24.dp)) }
                    itemsIndexed(lines) { index, line ->
                        val color by animateColorAsState(if (index == active) textColor else dim)
                        Text(
                            line.text.ifBlank { "♪" },
                            color = color,
                            fontSize = if (compact) 18.sp else 30.sp,
                            lineHeight = if (compact) 25.sp else 40.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).clickable { Player.seek(line.time) }.padding(4.dp),
                        )
                    }
                    item { Spacer(Modifier.height(200.dp)) }
                }
            }
        }
    }
}

/** The player over the whole window: the cover and the song on one side, the lyrics on the other. */
@Composable
fun FullPlayer() {
    val state by Player.state.collectAsState()
    val track = state.current
    Box(Modifier.fillMaxSize().background(Color(0xFF0B0B0E))) {
        // The cover, blurred and dark, behind everything.
        RemoteImage(track?.resized(600), Modifier.fillMaxSize(), null)
        Box(Modifier.fillMaxSize().background(Color(0xD9000000)))
        Row(Modifier.fillMaxSize().padding(48.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.width(440.dp).fillMaxHeight(), verticalArrangement = Arrangement.Center) {
                RemoteImage(track?.largeArtwork, Modifier.size(440.dp), RoundedCornerShape(14.dp))
                Row(Modifier.padding(top = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(track?.title.orEmpty(), color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(track?.artist.orEmpty(), color = Color.White.copy(alpha = 0.7f), fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    CurrentTrackMenuButton(Color.White)
                }
                Scrubber(Modifier.fillMaxWidth().padding(top = 18.dp), light = true)
            }
            Spacer(Modifier.width(56.dp))
            Box(Modifier.weight(1f).fillMaxHeight()) { LyricsPanel(compact = false, light = true) }
        }
        IconButton(onClick = { Nav.fullPlayer = false }, Modifier.padding(16.dp).align(Alignment.TopStart)) {
            Icon(Icons.Rounded.KeyboardArrowDown, tr("Chiudi"), Modifier.size(32.dp), tint = Color.White)
        }
    }
}
