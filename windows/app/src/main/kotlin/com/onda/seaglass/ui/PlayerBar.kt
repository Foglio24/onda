@file:OptIn(ExperimentalComposeUiApi::class)

package com.onda.seaglass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.ui.draw.alpha
import androidx.compose.animation.core.animateFloat
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.automirrored.rounded.VolumeDown
import androidx.compose.material.icons.automirrored.rounded.VolumeOff
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.OpenInFull
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.RepeatOne
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.SpeakerNotes
import androidx.compose.material.icons.rounded.ViewSidebar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.account.Account
import com.onda.seaglass.audio.Player
import com.onda.seaglass.audio.isLocal
import com.onda.seaglass.core.Prefs
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Library
import com.onda.seaglass.model.formatDuration

/**
 * The bar at the bottom of the window, as Spotify's: the song (its cover opens the full player)
 * with its heart, the controls over the song's progress, and the panels, Tempo, the sleep timer,
 * the volume and the full player on the right.
 */
@Composable
fun PlayerBar() {
    val palette = LocalPalette.current
    val state by Player.state.collectAsState()
    val liked by Library.liked.collectAsState()
    val track = state.current
    BoxWithConstraints(Modifier.fillMaxWidth().height(84.dp).background(palette.bar).padding(horizontal = 16.dp)) {
    // In a narrow window the controls keep their room and the song's title gives way (shortened).
    val compact = maxWidth < 1150.dp
    val controlsWidth = (maxWidth * 0.4f).coerceIn(300.dp, 640.dp)
    val icon = if (compact) 18 else 20
    Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
        // The song.
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
            if (track != null) {
                Hoverable { hovered ->
                    Box(contentAlignment = Alignment.TopEnd) {
                        RemoteImage(track.resized(226), Modifier.size(56.dp).clickable { Nav.fullPlayer = true }, RoundedCornerShape(4.dp))
                        if (hovered) {
                            Box(Modifier.padding(4.dp).size(22.dp).clip(CircleShape).background(Color(0xCC000000)).clickable { Nav.fullPlayer = true }, contentAlignment = Alignment.Center) {
                                Icon(Icons.Rounded.OpenInFull, tr("Schermo intero"), Modifier.size(13.dp), tint = Color.White)
                            }
                        }
                    }
                }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f, fill = false)) {
                    Text(
                        track.title, color = palette.text, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.clickable { Nav.fullPlayer = true },
                    )
                    Text(
                        track.artist, color = palette.secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.clickable(enabled = !track.isLocal && track.primaryArtist.isNotEmpty()) { Nav.open(Route.Artist(track.artistId, track.primaryArtist)) },
                    )
                    val note = state.error ?: state.format
                    if (note != null) Text(note, color = if (state.error != null) Color(0xFFFF7A7A) else palette.tertiary, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (!track.isLocal) {
                    val isLiked = liked.any { it.videoId == track.videoId }
                    Spacer(Modifier.width(6.dp))
                    BarButton(
                        if (isLiked) Icons.Rounded.CheckCircle else Icons.Rounded.Add,
                        tr(if (isLiked) "Salva in" else "Aggiungi ai preferiti"), active = isLiked, size = 20,
                    ) {
                        // As on Spotify: "+" saves it to Brani preferiti (with "Cambia"); the tick opens "Salva in".
                        if (isLiked) Nav.saveTo = track else toggleLikeWithMessage(track)
                    }
                }
            }
        }
        // The controls and the progress.
        Column(Modifier.width(controlsWidth).padding(horizontal = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Controls(small = true)
            Scrubber(Modifier.fillMaxWidth().padding(top = 2.dp))
        }
        // The panels, Tempo, the timer, the volume, the full player.
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
            BarButton(Icons.Rounded.ViewSidebar, tr("In riproduzione"), active = Nav.panel == Nav.Panel.NOW_PLAYING, size = icon) { Nav.togglePanel(Nav.Panel.NOW_PLAYING) }
            BarButton(Icons.Rounded.SpeakerNotes, tr("Testo"), active = Nav.panel == Nav.Panel.LYRICS, size = icon) { Nav.togglePanel(Nav.Panel.LYRICS) }
            BarButton(Icons.AutoMirrored.Rounded.QueueMusic, tr("Coda"), active = Nav.panel == Nav.Panel.QUEUE, size = icon) { Nav.togglePanel(Nav.Panel.QUEUE) }
            TempoButton(size = icon)
            SleepTimerButton(state.sleepAt > 0 || state.sleepAtEnd, size = icon)
            VolumeControl(width = if (compact) 64.dp else 96.dp, iconSize = icon)
            BarButton(Icons.Rounded.OpenInFull, tr("Schermo intero"), size = icon - 2, enabled = track != null) { Nav.fullPlayer = true }
        }
    }
    }
}

/**
 * Shuffle, previous, play or pause, next and repeat. [small] is the bar's; otherwise the full
 * player's, larger and white on the cover's colour.
 */
@Composable
fun Controls(small: Boolean, light: Boolean = false) {
    val palette = LocalPalette.current
    val state by Player.state.collectAsState()
    val hasSong = state.current != null
    val play = if (small) 34.dp else 64.dp
    val skip = if (small) 26 else 38
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(if (small) 10.dp else 22.dp)) {
        BarButton(Icons.Rounded.Shuffle, tr("Casuale"), active = state.shuffle, light = light, size = if (small) 20 else 26) { Player.setShuffle(!state.shuffle) }
        BarButton(Icons.Rounded.SkipPrevious, tr("Precedente"), light = light, size = skip, enabled = hasSong, emphasised = true) { Player.previous() }
        Hoverable { hovered ->
            val scale = if (hovered && hasSong) 1.05f else 1f
            Box(
                Modifier.size(play * scale).clip(CircleShape).background(if (light) Color.White else palette.text).clickable(enabled = hasSong) { Player.toggle() },
                contentAlignment = Alignment.Center,
            ) {
                val tint = if (light) Color.Black else palette.page
                if (state.isLoading) {
                    CircularProgressIndicator(Modifier.size(play * 0.5f), color = tint, strokeWidth = 2.dp)
                } else {
                    Icon(
                        if (state.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, tr(if (state.isPlaying) "Pausa" else "Riproduci"),
                        Modifier.size(play * 0.6f), tint = tint,
                    )
                }
            }
        }
        BarButton(Icons.Rounded.SkipNext, tr("Successivo"), light = light, size = skip, enabled = hasSong, emphasised = true) { Player.next() }
        BarButton(
            if (state.repeat == Player.Repeat.ONE) Icons.Rounded.RepeatOne else Icons.Rounded.Repeat,
            tr("Ripeti"), active = state.repeat != Player.Repeat.OFF, light = light, size = if (small) 20 else 26,
        ) { Player.cycleRepeat() }
    }
}

/**
 * A button of the bar: grey, white when hovered, in the accent when it's on (with a dot under it,
 * as Spotify marks what's on). [light] is for the full player, over the cover's colour.
 */
@Composable
fun BarButton(
    icon: ImageVector, label: String, active: Boolean = false, size: Int = 22, light: Boolean = false, enabled: Boolean = true,
    emphasised: Boolean = false, onClick: () -> Unit,
) {
    val palette = LocalPalette.current
    Hoverable { hovered ->
        Box(contentAlignment = Alignment.BottomCenter) {
            IconButton(onClick = onClick, Modifier.size((size + 16).dp), enabled = enabled) {
                val idle = when {
                    light -> Color.White.copy(alpha = if (emphasised) 0.95f else 0.75f)
                    emphasised -> palette.text
                    else -> palette.secondary
                }
                val tint = when {
                    !enabled -> if (light) Color.White.copy(alpha = 0.35f) else palette.tertiary
                    active -> palette.accent
                    hovered -> if (light) Color.White else palette.text
                    else -> idle
                }
                Icon(icon, label, Modifier.size(size.dp), tint = tint)
            }
            if (active) Box(Modifier.size(4.dp).clip(CircleShape).background(palette.accent))
        }
    }
}

@Composable
private fun SleepTimerButton(active: Boolean, light: Boolean = false, size: Int = 20) {
    var open by remember { mutableStateOf(false) }
    Box {
        BarButton(Icons.Rounded.Bedtime, tr("Timer di spegnimento"), active = active, size = size, light = light) { open = true }
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

@Composable
fun FullPlayerSleepTimer() {
    val state by Player.state.collectAsState()
    SleepTimerButton(state.sleepAt > 0 || state.sleepAtEnd, light = true)
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
    val textColor = if (light) Color.White.copy(alpha = 0.8f) else palette.secondary
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Text(formatDuration(if (dragging != null) dragging!! * duration else position), color = textColor, fontSize = 12.sp, maxLines = 1,
            modifier = Modifier.width(48.dp), textAlign = androidx.compose.ui.text.style.TextAlign.End)
        Spacer(Modifier.width(8.dp))
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
            val track = if (light) Color.White.copy(alpha = 0.3f) else if (palette.dark) Color(0xFF4D4D4D) else Color(0xFFC9C9CF)
            val fill = if (hovered || dragging != null) palette.accent else if (light) Color.White else palette.text
            Box(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)).background(track))
            Box(Modifier.fillMaxWidth(fraction).height(4.dp).clip(RoundedCornerShape(2.dp)).background(fill))
            if (hovered || dragging != null) {
                Box(Modifier.padding(start = (maxWidth * fraction - 6.dp).coerceAtLeast(0.dp)).size(12.dp).clip(CircleShape).background(if (light) Color.White else palette.text))
            }
        }
        Spacer(Modifier.width(8.dp))
        Text(formatDuration(duration), color = textColor, fontSize = 12.sp, maxLines = 1, modifier = Modifier.width(48.dp))
    }
}

/** The volume: its icon mutes and unmutes; the bar is clicked, dragged or scrolled. */
@Composable
fun VolumeControl(width: Dp, light: Boolean = false, iconSize: Int = 20) {
    val palette = LocalPalette.current
    val volume by Prefs.volume.state.collectAsState()
    var hovered by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        val icon = when {
            volume <= 0.001 -> Icons.AutoMirrored.Rounded.VolumeOff
            volume < 0.5 -> Icons.AutoMirrored.Rounded.VolumeDown
            else -> Icons.AutoMirrored.Rounded.VolumeUp
        }
        var before by remember { mutableStateOf(0.8) }
        BarButton(icon, tr("Volume"), size = iconSize, light = light) {
            if (volume > 0.001) {
                before = volume
                Player.setVolume(0.0)
            } else {
                Player.setVolume(before)
            }
        }
        BoxWithConstraints(
            Modifier.width(width).height(16.dp)
                .onPointerEvent(PointerEventType.Enter) { hovered = true }
                .onPointerEvent(PointerEventType.Exit) { hovered = false }
                .pointerInput(Unit) { detectTapGestures { Player.setVolume((it.x / size.width).toDouble()) } }
                .pointerInput(Unit) { detectDragGestures { change, _ -> Player.setVolume((change.position.x / size.width).toDouble()) } }
                // The mouse wheel moves it too.
                .onPointerEvent(PointerEventType.Scroll) { event ->
                    val delta = event.changes.firstOrNull()?.scrollDelta?.y ?: 0f
                    Player.setVolume(Prefs.volume.value - delta * 0.05)
                },
            contentAlignment = Alignment.CenterStart,
        ) {
            val track = if (light) Color.White.copy(alpha = 0.3f) else if (palette.dark) Color(0xFF4D4D4D) else Color(0xFFC9C9CF)
            val fill = if (hovered) palette.accent else if (light) Color.White else palette.text
            Box(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)).background(track))
            Box(Modifier.fillMaxWidth(volume.toFloat()).height(4.dp).clip(RoundedCornerShape(2.dp)).background(fill))
            if (hovered) Box(Modifier.padding(start = (maxWidth * volume.toFloat() - 6.dp).coerceAtLeast(0.dp)).size(12.dp).clip(CircleShape).background(if (light) Color.White else palette.text))
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

/**
 * Tempo (Premium, as on the iPhone): a DJ app's tempo fader. The song's BPM (once measured) with
 * the change in percent, the fader, − and + by 0.1 %, back to the song's own tempo, the fader's
 * range, and the key lock: on, voices keep their pitch; off, faster is higher, as on a turntable.
 */
@Composable
fun TempoButton(light: Boolean = false, size: Int = 20) {
    val tempo by Player.tempo.collectAsState()
    var open by remember { mutableStateOf(false) }
    Box {
        BarButton(Icons.Rounded.Speed, tr("Tempo"), active = tempo != 1.0, size = size, light = light) {
            if (Account.unlocks()) open = true else Nav.premium = tr("Tempo")
        }
        DropdownMenu(open, { open = false }) { TempoPanel() }
    }
}

@Composable
private fun TempoPanel() {
    val palette = LocalPalette.current
    val tempo by Player.tempo.collectAsState()
    val keyLock by Prefs.tempoKeyLock.state.collectAsState()
    val range by Prefs.tempoRange.state.collectAsState()
    val bpm by Player.songBpm.collectAsState()
    val state by Player.state.collectAsState()
    LaunchedEffect(state.current?.videoId) { Player.measureBpm() }
    val measured = bpm?.takeIf { it.first == state.current?.videoId }?.second
    Column(Modifier.width(320.dp).padding(horizontal = 18.dp, vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(tr("Tempo"), color = palette.text, fontWeight = FontWeight.Bold, fontSize = 16.sp, modifier = Modifier.weight(1f))
            var rangeMenu by remember { mutableStateOf(false) }
            Box {
                Text(
                    "±" + Math.round(range * 100) + " % ▾", color = palette.secondary, fontSize = 13.sp,
                    modifier = Modifier.clip(RoundedCornerShape(6.dp)).clickable { rangeMenu = true }.padding(6.dp),
                )
                DropdownMenu(rangeMenu, { rangeMenu = false }) {
                    Text(tr("Intervallo"), color = palette.secondary, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
                    listOf(0.08, 0.15, 0.25, 0.5).forEach { option ->
                        DropdownMenuItem(text = { Text("±" + Math.round(option * 100) + " %") }, onClick = {
                            rangeMenu = false
                            Player.setTempoRange(option)
                        })
                    }
                }
            }
        }
        // The BPM large when it's known, the change under it.
        Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.Bottom) {
            if (measured != null) {
                Text("%.1f".format(measured * tempo), color = palette.text, fontSize = 34.sp, fontWeight = FontWeight.SemiBold)
                Text(" BPM", color = palette.secondary, fontSize = 14.sp, modifier = Modifier.padding(bottom = 6.dp))
                Spacer(Modifier.weight(1f))
            }
            Text(
                "%+.1f %%".format((tempo - 1) * 100), color = if (tempo != 1.0) palette.accent else palette.secondary,
                fontSize = if (measured == null) 34.sp else 16.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(bottom = if (measured == null) 0.dp else 6.dp),
            )
        }
        ThinSlider(tempo.toFloat(), (1 - range).toFloat()..(1 + range).toFloat(), Modifier.fillMaxWidth().padding(top = 6.dp), step = 0.001f) {
            Player.setTempo(it.toDouble())
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            BarButton(Icons.Rounded.Remove, tr("Più lento"), size = 20) { Player.setTempo(tempo - 0.001) }
            BarButton(Icons.Rounded.Add, tr("Più veloce"), size = 20) { Player.setTempo(tempo + 0.001) }
            Spacer(Modifier.weight(1f))
            Text(
                tr("Reimposta"), color = if (tempo != 1.0) palette.accent else palette.tertiary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clip(RoundedCornerShape(6.dp)).clickable(enabled = tempo != 1.0) { Player.setTempo(1.0) }.padding(8.dp),
            )
        }
        Row(
            Modifier.fillMaxWidth().padding(top = 6.dp).clip(RoundedCornerShape(8.dp)).clickable { Player.setKeyLock(!keyLock) }.padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Rounded.MusicNote, null, Modifier.size(20.dp), tint = if (keyLock) palette.accent else palette.secondary)
            Spacer(Modifier.width(10.dp))
            Text(tr("Blocca tonalità"), color = palette.text, fontSize = 14.sp, modifier = Modifier.weight(1f))
            Switch(keyLock, { Player.setKeyLock(it) }, colors = SwitchDefaults.colors(checkedTrackColor = palette.accent, checkedThumbColor = palette.onAccent))
        }
        Text(
            tr("La voce resta alla sua altezza a qualsiasi tempo. Disattivato, cambia con il tempo come su un giradischi: più veloce è più acuta, più lenta è più grave."),
            color = palette.secondary, fontSize = 12.sp, lineHeight = 16.sp,
        )
        Text(
            tr("Con il tempo cambiato, AutoMix e la dissolvenza si fermano: i brani si susseguono senza mix."),
            color = palette.tertiary, fontSize = 12.sp, lineHeight = 16.sp, modifier = Modifier.padding(top = 6.dp),
        )
    }
}

/**
 * Over the player bar while a mix comes and plays, so its start is seen: "Mix tra 8 s" (pulsing)
 * in the last seconds before an AutoMix mix, then a bar filling with the mix's progress, with the
 * next song and how it comes in ("a tempo, 8 battute").
 */
@Composable
fun MixBanner() {
    val palette = LocalPalette.current
    val mix by Player.mix.collectAsState()
    // Kept while the banner folds away, so it doesn't empty first.
    var last by remember { mutableStateOf<Player.Mix?>(null) }
    if (mix != null) last = mix
    androidx.compose.animation.AnimatedVisibility(
        mix != null,
        enter = androidx.compose.animation.expandVertically() + androidx.compose.animation.fadeIn(),
        exit = androidx.compose.animation.shrinkVertically() + androidx.compose.animation.fadeOut(),
    ) {
        val shown = last ?: return@AnimatedVisibility
        val coming = shown.startsIn != null
        val progress by androidx.compose.animation.core.animateFloatAsState(shown.progress, androidx.compose.animation.core.tween(240))
        val pulse by androidx.compose.animation.core.rememberInfiniteTransition().animateFloat(
            initialValue = 0.35f, targetValue = 1f,
            animationSpec = androidx.compose.animation.core.infiniteRepeatable(androidx.compose.animation.core.tween(700), androidx.compose.animation.core.RepeatMode.Reverse),
        )
        Box(Modifier.fillMaxWidth().height(30.dp).background(palette.bar)) {
            // The mix's progress: the banner fills with the accent, a brighter line along its bottom.
            Box(Modifier.fillMaxHeight().fillMaxWidth(progress).background(palette.accent.copy(alpha = 0.22f)))
            Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(progress).height(2.dp).background(palette.accent))
            Row(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                Icon(Icons.Rounded.AutoAwesome, null, Modifier.size(16.dp).alpha(if (coming) pulse else 1f), tint = palette.accent)
                Spacer(Modifier.width(8.dp))
                val label = when {
                    coming -> tr("Mix tra %lld s", shown.startsIn ?: 0)
                    shown.beatMatched -> tr("Mix in corso")
                    else -> tr("Dissolvenza in corso")
                }
                Text(label, color = palette.accent, fontWeight = FontWeight.Bold, fontSize = 13.sp, maxLines = 1)
                val detail = listOfNotNull(shown.next?.title, shown.description).joinToString(" · ")
                if (detail.isNotEmpty()) {
                    Text(
                        "  →  $detail", color = palette.text, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                }
            }
        }
    }
}
