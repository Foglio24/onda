package com.onda.seaglass.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.Lyrics
import androidx.compose.material.icons.rounded.SpeakerNotes
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.audio.Player
import com.onda.seaglass.audio.isLocal
import com.onda.seaglass.core.Prefs
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.LyricsState
import com.onda.seaglass.data.LyricsTranslator
import com.onda.seaglass.data.NowPlayingLyrics

// MARK: What's playing

/** The right panel's "In riproduzione", as Spotify's: the cover large, the song, and what comes next. */
@Composable
fun NowPlayingPanel() {
    val palette = LocalPalette.current
    val state by Player.state.collectAsState()
    val liked by Library.liked.collectAsState()
    val track = state.current
    if (track == null) {
        Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
            Text(tr("Scegli un brano da ascoltare."), color = palette.secondary, fontSize = 14.sp, textAlign = TextAlign.Center)
        }
        return
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 16.dp)) {
        RemoteImage(track.largeArtwork, Modifier.fillMaxWidth().aspectRatio(1f).clickable { Nav.fullPlayer = true }, RoundedCornerShape(8.dp))
        Row(Modifier.padding(top = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(track.title, color = palette.text, fontSize = 22.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.clickable(enabled = track.albumId != null) { track.albumId?.let { Nav.open(Route.Album(it)) } })
                Text(track.artist, color = palette.secondary, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.clickable(enabled = !track.isLocal && track.primaryArtist.isNotEmpty()) { Nav.open(Route.Artist(track.artistId, track.primaryArtist)) })
            }
            if (!track.isLocal) {
                val isLiked = liked.any { it.videoId == track.videoId }
                IconButton(onClick = { Library.toggleLike(track) }) {
                    Icon(if (isLiked) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder, tr(if (isLiked) "Rimuovi dai preferiti" else "Aggiungi ai preferiti"),
                        tint = if (isLiked) palette.accent else palette.secondary)
                }
            }
        }
        if (!track.isLocal) {
            PanelCard(Modifier.padding(top = 16.dp), onClick = { Nav.open(Route.SongInfo(track)) }) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Info, null, Modifier.size(20.dp), tint = palette.secondary)
                    Spacer(Modifier.width(10.dp))
                    Text(tr("Informazioni sul brano"), color = palette.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
        val next = state.upcoming.firstOrNull()?.track
        if (next != null) {
            PanelCard(Modifier.padding(top = 12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(tr("Prossimo in coda"), color = palette.text, fontSize = 15.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                    Text(tr("Apri coda"), color = palette.secondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clip(RoundedCornerShape(4.dp)).clickable { Nav.panel = Nav.Panel.QUEUE }.padding(4.dp))
                }
                Row(
                    Modifier.fillMaxWidth().padding(top = 10.dp).clip(RoundedCornerShape(6.dp)).clickable { Player.next() }.padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RemoteImage(next.resized(120), Modifier.size(48.dp), RoundedCornerShape(4.dp))
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(next.title, color = palette.text, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(next.artist, color = palette.secondary, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                state.nextMix?.let { mix ->
                    Row(Modifier.padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.AutoAwesome, null, Modifier.size(16.dp), tint = palette.accent)
                        Spacer(Modifier.width(6.dp))
                        Text(tr("AutoMix") + " · " + mix, color = palette.accent, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                    }
                }
            }
        }
    }
}

@Composable
private fun PanelCard(modifier: Modifier = Modifier, onClick: (() -> Unit)? = null, content: @Composable () -> Unit) {
    val palette = LocalPalette.current
    Hoverable { hovered ->
        Column(
            modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp))
                .background(if (hovered && onClick != null) palette.cardHover else palette.card.let { if (palette.dark) Color(0xFF1F1F1F) else it })
                .clickable(enabled = onClick != null) { onClick?.invoke() }
                .padding(16.dp),
        ) { content() }
    }
}

// MARK: The queue

/** The queue: what plays, what comes next (to reorder or remove), with AutoMix's plan for the next song. */
@Composable
fun QueuePanel(light: Boolean = false) {
    val palette = LocalPalette.current
    val state by Player.state.collectAsState()
    val text = if (light) Color.White else palette.text
    val dim = if (light) Color.White.copy(alpha = 0.7f) else palette.secondary
    Column(Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
        val current = state.current
        if (current == null) {
            Text(tr("La coda è vuota."), color = dim, fontSize = 14.sp, modifier = Modifier.padding(top = 20.dp, start = 4.dp))
            return@Column
        }
        Text(tr("In riproduzione"), color = text, fontSize = 15.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 4.dp, top = 4.dp, bottom = 6.dp))
        QueueRow(current.title, current.artist, current.resized(120), highlighted = true, light = light)
        Row(Modifier.padding(start = 4.dp, top = 18.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (!state.source.isNullOrBlank()) tr("Prossimi da: %@", state.source!!) else tr("Prossimi brani"),
                color = text, fontSize = 15.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
            )
            if (state.upcoming.isNotEmpty()) {
                Text(tr("Svuota"), color = dim, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(4.dp)).clickable { Player.clearUpcoming() }.padding(4.dp))
            }
        }
        state.nextMix?.let { mix ->
            Row(Modifier.padding(start = 4.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.AutoAwesome, null, Modifier.size(15.dp), tint = palette.accent)
                Spacer(Modifier.width(6.dp))
                Text(tr("AutoMix") + " · " + mix, color = palette.accent, fontSize = 13.sp)
            }
        }
        LazyColumn(Modifier.weight(1f)) {
            itemsIndexed(state.upcoming, key = { _, entry -> entry.id }) { offset, entry ->
                val index = state.index + 1 + offset
                QueueRow(
                    entry.track.title, entry.track.artist, entry.track.resized(120), light = light,
                    onClick = { Player.jump(index) },
                    actions = {
                        IconButton(onClick = { Player.move(index, index - 1) }, Modifier.size(28.dp), enabled = offset > 0) {
                            Icon(Icons.Rounded.KeyboardArrowUp, tr("Sposta su"), tint = dim)
                        }
                        IconButton(onClick = { Player.move(index, index + 1) }, Modifier.size(28.dp), enabled = index + 1 < state.queue.size) {
                            Icon(Icons.Rounded.KeyboardArrowDown, tr("Sposta giù"), tint = dim)
                        }
                        IconButton(onClick = { Player.removeFromQueue(entry.id) }, Modifier.size(28.dp)) {
                            Icon(Icons.Rounded.Close, tr("Rimuovi"), tint = dim)
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun QueueRow(
    title: String, subtitle: String, artwork: String?, highlighted: Boolean = false, light: Boolean = false,
    onClick: (() -> Unit)? = null, actions: @Composable () -> Unit = {},
) {
    val palette = LocalPalette.current
    Hoverable { hovered ->
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp))
                .background(if (hovered && onClick != null) (if (light) Color.White.copy(alpha = 0.1f) else palette.cardHover) else Color.Transparent)
                .clickable(enabled = onClick != null) { onClick?.invoke() }
                .padding(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            RemoteImage(artwork, Modifier.size(44.dp), RoundedCornerShape(4.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(title, color = if (highlighted) palette.accent else if (light) Color.White else palette.text, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(subtitle, color = if (light) Color.White.copy(alpha = 0.7f) else palette.secondary, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (hovered) Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) { actions() }
        }
    }
}

// MARK: The lyrics

/** The lyrics' translation for the song playing, as it goes. */
private sealed interface Translation {
    data object Off : Translation
    data object Working : Translation
    data class Done(val lines: List<String>) : Translation
    data class Failed(val message: String, val signIn: Boolean, val premium: Boolean) : Translation
}

@Composable
private fun rememberTranslation(id: String?, lines: List<String>?): Translation {
    val on by Prefs.lyricsTranslate.state.collectAsState()
    val target by Prefs.translationTarget.state.collectAsState()
    val result by produceState<Translation>(Translation.Off, id, lines, on, target) {
        if (!on || id == null || lines.isNullOrEmpty()) {
            value = Translation.Off
            return@produceState
        }
        value = Translation.Working
        value = try {
            Translation.Done(LyricsTranslator.translate(id, lines))
        } catch (e: LyricsTranslator.TranslationException) {
            Translation.Failed(e.message.orEmpty(), e.signIn, e.premium)
        }
    }
    return result
}

/**
 * "Traduci": the translation on or off (Premium, as on the iPhone), and the language it goes into.
 * [light] is the full player's.
 */
@Composable
fun TranslateButton(light: Boolean = false) {
    val palette = LocalPalette.current
    val on by Prefs.lyricsTranslate.state.collectAsState()
    val target by Prefs.translationTarget.state.collectAsState()
    var menu by remember { mutableStateOf(false) }
    Box {
        BarButton(Icons.Rounded.Translate, tr("Traduci"), active = on, size = 20, light = light) {
            if (!com.onda.seaglass.account.Account.unlocks()) {
                Nav.premium = tr("Traduzione dei testi")
            } else {
                menu = true
            }
        }
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem(
                text = { Text(if (on) tr("Nascondi traduzione") else tr("Mostra traduzione"), fontWeight = FontWeight.SemiBold) },
                leadingIcon = { Icon(Icons.Rounded.Translate, null) },
                onClick = {
                    menu = false
                    Prefs.lyricsTranslate.value = !on
                    // The translation goes with the lyrics: show them if they're hidden.
                    if (!on && !Nav.fullPlayer && Nav.panel != Nav.Panel.LYRICS) Nav.panel = Nav.Panel.LYRICS
                    if (!on && Nav.fullPlayer) Nav.fullPlayerSide = Nav.FullSide.LYRICS
                },
            )
            Text(tr("Traduci in"), color = palette.secondary, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
            val current = LyricsTranslator.target()
            LyricsTranslator.languages.sortedBy { LyricsTranslator.languageName(it) }.forEach { language ->
                DropdownMenuItem(
                    text = { Text(LyricsTranslator.languageName(language), color = if (language == current) palette.accent else palette.text) },
                    onClick = {
                        menu = false
                        Prefs.translationTarget.value = language
                        Prefs.lyricsTranslate.value = true
                    },
                )
            }
        }
    }
}

/**
 * The lyrics: synced ones follow the song, the line being sung large and bright, and a click on
 * a line goes there; plain ones are shown as they are. With the translation on, each line has its
 * translation under it. [compact] is the side panel, otherwise the full player.
 */
@Composable
fun LyricsPanel(compact: Boolean, light: Boolean = false) {
    val palette = LocalPalette.current
    val lyrics by NowPlayingLyrics.state.collectAsState()
    val position by Player.position.collectAsState()
    val state by Player.state.collectAsState()
    val textColor = if (light) Color.White else palette.text
    val dim = if (light) Color.White.copy(alpha = 0.45f) else palette.tertiary
    val lines: List<String>? = when (val current = lyrics) {
        is LyricsState.Synced -> current.lines.map { it.text }
        is LyricsState.Plain -> current.text.lines()
        else -> null
    }
    val translation = rememberTranslation(state.current?.videoId, lines)
    val translated = (translation as? Translation.Done)?.lines
    Column(Modifier.fillMaxSize().padding(horizontal = if (compact) 16.dp else 8.dp)) {
        if (compact) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Spacer(Modifier.weight(1f))
                TranslateButton()
            }
        }
        when (translation) {
            Translation.Working -> Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(14.dp), color = palette.accent, strokeWidth = 2.dp)
                Spacer(Modifier.width(8.dp))
                Text(tr("Traduzione…"), color = dim, fontSize = 13.sp)
            }
            is Translation.Failed -> Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(translation.message, color = if (light) Color.White.copy(alpha = 0.8f) else palette.secondary, fontSize = 13.sp, modifier = Modifier.weight(1f, fill = false))
                if (translation.signIn) {
                    Spacer(Modifier.width(8.dp))
                    Text(tr("Accedi"), color = palette.accent, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clickable { Nav.fullPlayer = false; Nav.section(Route.Account) })
                }
                if (translation.premium) {
                    Spacer(Modifier.width(8.dp))
                    Text(tr("Premium"), color = palette.accent, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clickable { Nav.premium = tr("Traduzione dei testi") })
                }
            }
            else -> Unit
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (val current = lyrics) {
                LyricsState.Loading -> Text(tr("Caricamento del testo…"), color = dim, modifier = Modifier.align(Alignment.Center))
                LyricsState.Unavailable -> Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Rounded.Lyrics, null, Modifier.size(40.dp), tint = dim)
                    Text(tr("Testo non disponibile"), color = dim, modifier = Modifier.padding(top = 10.dp))
                }
                is LyricsState.Plain -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = 20.dp)) {
                    current.text.lines().forEachIndexed { index, line ->
                        Text(line, color = textColor, fontSize = if (compact) 17.sp else 24.sp, lineHeight = if (compact) 24.sp else 32.sp, fontWeight = FontWeight.Bold)
                        translated?.getOrNull(index)?.takeIf { it.isNotBlank() }?.let {
                            Text(it, color = if (light) Color.White.copy(alpha = 0.7f) else palette.secondary, fontSize = if (compact) 14.sp else 18.sp, lineHeight = if (compact) 19.sp else 24.sp)
                        }
                        Spacer(Modifier.height(if (compact) 8.dp else 12.dp))
                    }
                }
                is LyricsState.Synced -> {
                    val lyricLines = current.lines
                    val active = lyricLines.indexOfLast { it.time <= position + 0.25 }.coerceAtLeast(0)
                    val list = rememberLazyListState()
                    LaunchedEffect(active) {
                        // Keeps the line being sung a third of the way down.
                        list.animateScrollToItem(maxOf(0, active - 2))
                    }
                    LazyColumn(Modifier.fillMaxSize(), state = list, verticalArrangement = Arrangement.spacedBy(if (compact) 12.dp else 18.dp)) {
                        item { Spacer(Modifier.height(16.dp)) }
                        itemsIndexed(lyricLines) { index, line ->
                            val past = index < active
                            val color by animateColorAsState(
                                when {
                                    index == active -> textColor
                                    past -> if (light) Color.White.copy(alpha = 0.6f) else palette.secondary
                                    else -> dim
                                },
                                tween(250),
                            )
                            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).clickable { Player.seek(line.time) }.padding(4.dp)) {
                                Text(
                                    line.text.ifBlank { "♪" },
                                    color = color,
                                    fontSize = if (compact) 20.sp else 32.sp,
                                    lineHeight = if (compact) 27.sp else 42.sp,
                                    fontWeight = FontWeight.Bold,
                                )
                                translated?.getOrNull(index)?.takeIf { it.isNotBlank() }?.let {
                                    Text(it, color = color.copy(alpha = color.alpha * 0.75f), fontSize = if (compact) 15.sp else 21.sp, lineHeight = if (compact) 20.sp else 28.sp,
                                        modifier = Modifier.padding(top = 2.dp))
                                }
                            }
                        }
                        item { Spacer(Modifier.height(200.dp)) }
                    }
                }
            }
        }
    }
}

// MARK: The full player

/**
 * The player over the whole window, as Spotify's full screen: the cover's colour behind it, the
 * cover and the song, and on the side the lyrics (with their translation) or the queue; at the
 * bottom the progress, the controls (shuffle, previous, play or pause, next, repeat) and the
 * buttons for the lyrics, the translation, the queue, Tempo, the sleep timer and the volume.
 */
@Composable
fun FullPlayer() {
    val state by Player.state.collectAsState()
    val track = state.current
    val tint by produceState<Color?>(CoverColors.cached(track?.resized(226)), track?.videoId) { value = CoverColors.of(track?.resized(226)) }
    val background by animateColorAsState(tint ?: Color(0xFF202024), tween(600))
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        // The cover, blurred, under its colour.
        RemoteImage(track?.resized(600), Modifier.fillMaxSize().blur(80.dp), null)
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(background.copy(alpha = 0.85f), Color.Black.copy(alpha = 0.92f)))))
        Column(Modifier.fillMaxSize().padding(horizontal = 32.dp, vertical = 20.dp)) {
            // Top: close, where the music comes from, the song's menu.
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { Nav.fullPlayer = false }) {
                    Icon(Icons.Rounded.KeyboardArrowDown, tr("Chiudi"), Modifier.size(32.dp), tint = Color.White)
                }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(tr("In riproduzione"), color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    state.source?.takeIf { it.isNotBlank() }?.let { Text(it, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                }
                CurrentTrackMenuButton(Color.White)
            }
            // Middle: the cover and the song; the lyrics or the queue beside them.
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().padding(vertical = 16.dp)) {
                val side = Nav.fullPlayerSide
                val showSide = side != Nav.FullSide.NONE && maxWidth > 760.dp
                val coverSize = minOf(maxHeight - 96.dp, if (showSide) maxWidth * 0.42f else maxWidth * 0.6f, 560.dp).coerceAtLeast(160.dp)
                Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = if (showSide) Arrangement.Start else Arrangement.Center) {
                    Column(Modifier.width(coverSize), horizontalAlignment = Alignment.Start) {
                        RemoteImage(track?.largeArtwork, Modifier.size(coverSize), RoundedCornerShape(10.dp))
                        Row(Modifier.padding(top = 18.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(track?.title.orEmpty(), color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(track?.artist.orEmpty(), color = Color.White.copy(alpha = 0.75f), fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.clickable(enabled = track != null && !track.isLocal && track.primaryArtist.isNotEmpty()) {
                                        track?.let { Nav.open(Route.Artist(it.artistId, it.primaryArtist)) }
                                    })
                            }
                            track?.takeIf { !it.isLocal }?.let { song ->
                                val liked by Library.liked.collectAsState()
                                val isLiked = liked.any { it.videoId == song.videoId }
                                IconButton(onClick = { Library.toggleLike(song) }) {
                                    Icon(if (isLiked) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder, tr(if (isLiked) "Rimuovi dai preferiti" else "Aggiungi ai preferiti"),
                                        Modifier.size(28.dp), tint = if (isLiked) LocalPalette.current.accent else Color.White)
                                }
                            }
                        }
                    }
                    if (showSide) {
                        Spacer(Modifier.width(48.dp))
                        Box(Modifier.weight(1f).fillMaxHeight()) {
                            if (side == Nav.FullSide.QUEUE) QueuePanel(light = true) else LyricsPanel(compact = false, light = true)
                        }
                    }
                }
            }
            // Bottom: the progress and every control.
            Scrubber(Modifier.fillMaxWidth(), light = true)
            Box(Modifier.fillMaxWidth().padding(top = 8.dp)) {
                Row(Modifier.align(Alignment.CenterStart), verticalAlignment = Alignment.CenterVertically) {
                    state.nextMix?.let { mix ->
                        Icon(Icons.Rounded.AutoAwesome, null, Modifier.size(16.dp), tint = Color.White.copy(alpha = 0.8f))
                        Spacer(Modifier.width(6.dp))
                        Text(tr("AutoMix") + " · " + mix, color = Color.White.copy(alpha = 0.8f), fontSize = 13.sp, maxLines = 1,
                            modifier = Modifier.widthIn(max = 260.dp), overflow = TextOverflow.Ellipsis)
                    }
                }
                Box(Modifier.align(Alignment.Center)) { Controls(small = false, light = true) }
                Row(Modifier.align(Alignment.CenterEnd), verticalAlignment = Alignment.CenterVertically) {
                    BarButton(Icons.Rounded.SpeakerNotes, tr("Testo"), active = Nav.fullPlayerSide == Nav.FullSide.LYRICS, size = 22, light = true) {
                        Nav.fullPlayerSide = if (Nav.fullPlayerSide == Nav.FullSide.LYRICS) Nav.FullSide.NONE else Nav.FullSide.LYRICS
                    }
                    TranslateButton(light = true)
                    BarButton(Icons.AutoMirrored.Rounded.QueueMusic, tr("Coda"), active = Nav.fullPlayerSide == Nav.FullSide.QUEUE, size = 22, light = true) {
                        Nav.fullPlayerSide = if (Nav.fullPlayerSide == Nav.FullSide.QUEUE) Nav.FullSide.NONE else Nav.FullSide.QUEUE
                    }
                    KaraokeButton(light = true)
                    TempoButton(light = true)
                    FullPlayerSleepTimer()
                    VolumeControl(width = 110.dp, light = true)
                }
            }
        }
    }
}
