package com.onda.seaglass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.Mood
import com.onda.seaglass.data.Recommendations
import com.onda.seaglass.model.Track
import com.onda.seaglass.playback.PlayerController
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.time.LocalTime

/** The Home's picks, kept while the app is open. */
private object HomeModel {
    val quickPicks = MutableStateFlow<List<Track>>(emptyList())
    var loadedDay = -1L
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen() {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val state by PlayerController.state.collectAsStateWithLifecycle()
    val liked by Library.liked.collectAsStateWithLifecycle()
    val playlists by Library.playlists.collectAsStateWithLifecycle()
    val history by Library.history.collectAsStateWithLifecycle()
    val quickPicks by HomeModel.quickPicks.collectAsStateWithLifecycle()
    var refreshing by remember { mutableStateOf(false) }
    var busyMood by remember { mutableStateOf<String?>(null) }
    val resume = remember(state.current == null) { if (state.current == null) PlayerController.resumePoint() else null }

    LaunchedEffect(Recommendations.today, history.isEmpty()) {
        if (HomeModel.loadedDay != Recommendations.today || HomeModel.quickPicks.value.isEmpty()) {
            HomeModel.quickPicks.value = Recommendations.quickPicks(refresh = false)
            HomeModel.loadedDay = Recommendations.today
        }
    }

    val hour = LocalTime.now().hour
    val greeting = when (hour) {
        in 5..12 -> tr("Buongiorno")
        in 13..17 -> tr("Buon pomeriggio")
        else -> tr("Buonasera")
    }
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()

    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = {
            scope.launch {
                refreshing = true
                HomeModel.quickPicks.value = Recommendations.quickPicks(refresh = true)
                refreshing = false
            }
        },
        modifier = Modifier.fillMaxSize(),
    ) {
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(top = top, bottom = LocalBottomPadding.current),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            item { ScreenTitle(greeting) }
            if (resume?.track != null) {
                item {
                    Column {
                        SectionHeader(tr("Riprendi da dove eri"))
                        ResumeCard(resume) { PlayerController.resume(resume) }
                    }
                }
            }
            val shortcuts = buildList {
                if (liked.isNotEmpty()) add(Shortcut(tr("Preferiti"), liked.first().mediumArtwork, Icons.Rounded.Favorite) { app.open("liked") })
                playlists.take(4).forEach { playlist ->
                    add(Shortcut(playlist.name, playlist.tracks.firstOrNull()?.mediumArtwork, null) { app.open("local/${playlist.id}") })
                }
                if (history.isNotEmpty() && size < 6) add(Shortcut(tr("Cronologia"), null, Icons.Rounded.History) { app.open("history") })
            }
            if (shortcuts.isNotEmpty()) {
                item {
                    Column {
                        SectionHeader(tr("Accesso rapido"))
                        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            shortcuts.chunked(2).forEach { pair ->
                                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                    pair.forEach { ShortcutTile(it, Modifier.weight(1f)) }
                                    if (pair.size == 1) Spacer(Modifier.weight(1f))
                                }
                            }
                        }
                    }
                }
            }
            item {
                Column {
                    SectionHeader(tr("Mood"))
                    LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(Recommendations.moods, key = { it.queries.first() }) { mood ->
                            MoodTile(mood, busy = busyMood == mood.title) {
                                if (busyMood != null) return@MoodTile
                                busyMood = mood.title
                                scope.launch {
                                    runCatching { Recommendations.moodTracks(mood) }
                                        .onSuccess { PlayerController.play(it) }
                                        .onFailure { app.toast(it.message ?: tr("Ricerca non riuscita")) }
                                    busyMood = null
                                }
                            }
                        }
                    }
                }
            }
            if (quickPicks.isNotEmpty()) {
                item { TrackGridShelf(tr("Scelti per te"), quickPicks) { PlayerController.play(quickPicks, it) } }
            } else {
                item { Loading() }
            }
            if (history.isNotEmpty()) {
                item {
                    Column {
                        SectionHeader(tr("Ascoltati di recente"), action = tr("Mostra tutto")) { app.open("history") }
                        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            itemsIndexed(history.take(20), key = { index, track -> "$index" + track.videoId }) { _, track ->
                                TrackCard(track) { PlayerController.playRadio(track) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private data class Shortcut(val title: String, val artwork: String?, val icon: ImageVector?, val open: () -> Unit)

@Composable
private fun ShortcutTile(shortcut: Shortcut, modifier: Modifier = Modifier) {
    val accent = LocalAccent.current
    Row(
        modifier
            .height(56.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Color.White.copy(alpha = 0.08f))
            .clickable(onClick = shortcut.open),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (shortcut.icon != null) {
            Box(
                Modifier.size(56.dp).background(Brush.linearGradient(listOf(accent, accent.copy(alpha = 0.5f)))),
                contentAlignment = Alignment.Center,
            ) { Icon(shortcut.icon, null, tint = Color.White) }
        } else {
            Artwork(shortcut.artwork, Modifier.size(56.dp), RoundedCornerShape(0.dp))
        }
        Text(
            shortcut.title, Modifier.padding(horizontal = 10.dp), fontWeight = FontWeight.SemiBold, fontSize = 14.sp,
            maxLines = 2, overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun MoodTile(mood: Mood, busy: Boolean, onClick: () -> Unit) {
    val tint = Color(mood.tint)
    Box(
        Modifier
            .size(width = 140.dp, height = 84.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Brush.linearGradient(listOf(tint, tint.copy(alpha = 0.45f))))
            .clickable(onClick = onClick)
            .padding(12.dp),
    ) {
        Text(mood.title, fontWeight = FontWeight.Bold, fontSize = 17.sp, modifier = Modifier.align(Alignment.BottomStart))
        if (busy) {
            CircularProgressIndicator(Modifier.size(18.dp).align(Alignment.TopEnd), color = Color.White, strokeWidth = 2.dp)
        }
    }
}

@Composable
private fun TrackCard(track: Track, onClick: () -> Unit) {
    Column(Modifier.width(140.dp).clip(RoundedCornerShape(12.dp)).clickable(onClick = onClick)) {
        Artwork(track.largeArtwork, Modifier.size(140.dp), RoundedCornerShape(10.dp))
        Spacer(Modifier.height(8.dp))
        Text(track.title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 15.sp, fontWeight = FontWeight.Medium)
        Text(track.artist, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 13.sp, color = Secondary)
    }
}

@Composable
private fun ResumeCard(point: PlayerController.ResumePoint, onResume: () -> Unit) {
    val track = point.track ?: return
    GlassSurface(Modifier.padding(horizontal = 16.dp).fillMaxWidth().clickable(onClick = onResume), corner = 20.dp) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Artwork(track.mediumArtwork, Modifier.size(56.dp), RoundedCornerShape(10.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(track.title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(track.artist, color = Secondary, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Box(
                Modifier.size(44.dp).clip(RoundedCornerShape(22.dp)).background(LocalAccent.current),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Rounded.PlayArrow, tr("Riprendi %@", track.title), tint = Color.White) }
        }
    }
}
