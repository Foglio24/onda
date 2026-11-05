package com.onda.seaglass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.PlaylistAdd
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
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
import com.onda.seaglass.data.InnerTube
import com.onda.seaglass.data.Library
import com.onda.seaglass.model.Track
import com.onda.seaglass.playback.PlayerController
import kotlinx.coroutines.launch

private fun count(n: Int) = if (n == 1) tr("1 brano") else tr("%lld brani", n)

@Composable
fun LibraryScreen() {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val liked by Library.liked.collectAsStateWithLifecycle()
    val history by Library.history.collectAsStateWithLifecycle()
    val playlists by Library.playlists.collectAsStateWithLifecycle()
    var creating by remember { mutableStateOf(false) }
    var importing by remember { mutableStateOf(false) }
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = top, bottom = LocalBottomPadding.current)) {
        item {
            ScreenTitle(tr("Libreria")) {
                IconButton(onClick = { importing = true }) { Icon(Icons.Rounded.Link, tr("Importa playlist")) }
                IconButton(onClick = { creating = true }) { Icon(Icons.Rounded.Add, tr("Nuova playlist")) }
            }
        }
        item { LibraryRow(tr("Preferiti"), count(liked.size), Icons.Rounded.Favorite) { app.open("liked") } }
        item { LibraryRow(tr("Cronologia"), count(history.size), Icons.Rounded.History) { app.open("history") } }
        item { SectionHeader(tr("Le tue playlist")) }
        if (playlists.isEmpty()) {
            item { LibraryRow(tr("Nuova playlist"), "", Icons.AutoMirrored.Rounded.PlaylistAdd) { creating = true } }
        }
        items(playlists, key = { it.id }) { playlist ->
            Row(
                Modifier.fillMaxWidth().clickable { app.open("local/${playlist.id}") }.padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Artwork(playlist.tracks.firstOrNull()?.mediumArtwork, Modifier.size(56.dp), RoundedCornerShape(8.dp))
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(playlist.name, fontSize = 16.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(count(playlist.tracks.size), color = Secondary, fontSize = 13.sp)
                }
            }
        }
    }

    if (creating) {
        NameDialog(tr("Nuova playlist"), "", tr("Crea"), onDismiss = { creating = false }) { name ->
            val playlist = Library.createPlaylist(name)
            creating = false
            app.open("local/${playlist.id}")
        }
    }
    if (importing) {
        NameDialog(tr("Importa playlist"), "", tr("Importa"), label = tr("Link della playlist"), onDismiss = { importing = false }) { link ->
            importing = false
            val id = InnerTube.playlistId(link) ?: link.trim()
            scope.launch {
                runCatching { InnerTube.playlist(id) }
                    .onSuccess { page ->
                        val playlist = Library.createPlaylist(page.title.ifEmpty { tr("Playlist") }, page.tracks)
                        app.toast(tr("Playlist importata"))
                        app.open("local/${playlist.id}")
                    }
                    .onFailure { app.toast(it.message ?: tr("Playlist non disponibile")) }
            }
        }
    }
}

@Composable
private fun LibraryRow(title: String, detail: String, icon: ImageVector, onClick: () -> Unit) {
    val accent = LocalAccent.current
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(56.dp).clip(RoundedCornerShape(8.dp)).background(Brush.linearGradient(listOf(accent, accent.copy(alpha = 0.45f)))),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, tint = Color.White) }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 16.sp, fontWeight = FontWeight.Medium)
            if (detail.isNotEmpty()) Text(detail, color = Secondary, fontSize = 13.sp)
        }
    }
}

/** A list of songs with a title, "Riproduci" and "Casuale": favourites, history and the user's playlists. */
@Composable
private fun TrackListScreen(
    title: String,
    tracks: List<Track>,
    emptyTitle: String,
    emptyDetail: String,
    playlistId: String? = null,
    actions: @Composable () -> Unit = {},
) {
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    Box(Modifier.fillMaxSize()) {
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(top = top + 52.dp, bottom = LocalBottomPadding.current),
        ) {
            item { ScreenTitle(title, trailing = actions) }
            if (tracks.isEmpty()) {
                item { Message(emptyTitle, emptyDetail) }
            } else {
                item {
                    Text(count(tracks.size), color = Secondary, modifier = Modifier.padding(horizontal = 16.dp))
                }
                item {
                    Row(Modifier.padding(16.dp), horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(12.dp)) {
                        PillButton(tr("Riproduci"), Icons.Rounded.PlayArrow, Modifier.weight(1f), filled = true) { PlayerController.play(tracks) }
                        PillButton(tr("Casuale"), Icons.Rounded.Shuffle, Modifier.weight(1f)) { PlayerController.play(tracks, shuffle = true) }
                    }
                }
                itemsIndexed(tracks, key = { index, track -> "$index" + track.videoId }) { index, track ->
                    TrackRow(
                        track, onClick = { PlayerController.play(tracks, index) },
                        playlistId = playlistId, playlistIndex = if (playlistId != null) index else null,
                    )
                }
            }
        }
        GlassBackButton(Modifier.padding(top = top + 8.dp, start = 12.dp))
    }
}

@Composable
fun LikedScreen() {
    val liked by Library.liked.collectAsStateWithLifecycle()
    TrackListScreen(tr("Preferiti"), liked, tr("Nessun preferito"), tr("Aggiungi brani dal menu ··· di ogni canzone."))
}

@Composable
fun HistoryScreen() {
    val history by Library.history.collectAsStateWithLifecycle()
    var confirm by remember { mutableStateOf(false) }
    TrackListScreen(tr("Cronologia"), history, tr("Cronologia vuota"), tr("I brani che ascolti appariranno qui.")) {
        if (history.isNotEmpty()) TextButton(onClick = { confirm = true }) { Text(tr("Svuota"), color = LocalAccent.current) }
    }
    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            containerColor = Color(0xFF1C1C24),
            title = { Text(tr("Cancella cronologia ascolti")) },
            confirmButton = {
                TextButton(onClick = { Library.clearHistory(); confirm = false }) { Text(tr("Svuota"), color = Color(0xFFFF6B6B)) }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text(tr("Annulla")) } },
        )
    }
}

@Composable
fun LocalPlaylistScreen(id: String) {
    val app = LocalApp.current
    val playlists by Library.playlists.collectAsStateWithLifecycle()
    val playlist = playlists.firstOrNull { it.id == id }
    var menu by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    if (playlist == null) {
        Message(tr("Playlist eliminata"))
        return
    }
    TrackListScreen(
        playlist.name, playlist.tracks, tr("La playlist è vuota."), tr("Aggiungi brani dal menu ··· di ogni canzone."),
        playlistId = playlist.id,
    ) {
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Rounded.MoreVert, tr("Opzioni")) }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(
                    text = { Text(tr("Rinomina")) }, leadingIcon = { Icon(Icons.Rounded.Edit, null) },
                    onClick = { menu = false; renaming = true },
                )
                DropdownMenuItem(
                    text = { Text(tr("Elimina playlist"), color = Color(0xFFFF6B6B)) },
                    leadingIcon = { Icon(Icons.Rounded.Delete, null, tint = Color(0xFFFF6B6B)) },
                    onClick = { menu = false; deleting = true },
                )
            }
        }
    }
    if (renaming) {
        NameDialog(tr("Rinomina playlist"), playlist.name, tr("Salva"), onDismiss = { renaming = false }) {
            Library.renamePlaylist(playlist.id, it)
            renaming = false
        }
    }
    if (deleting) {
        AlertDialog(
            onDismissRequest = { deleting = false },
            containerColor = Color(0xFF1C1C24),
            title = { Text(tr("Eliminare questa playlist?")) },
            confirmButton = {
                TextButton(onClick = {
                    deleting = false
                    app.back()
                    Library.deletePlaylist(playlist.id)
                }) { Text(tr("Elimina"), color = Color(0xFFFF6B6B)) }
            },
            dismissButton = { TextButton(onClick = { deleting = false }) { Text(tr("Annulla")) } },
        )
    }
}
