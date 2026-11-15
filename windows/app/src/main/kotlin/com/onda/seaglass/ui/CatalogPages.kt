package com.onda.seaglass.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.data.InnerTube
import com.onda.seaglass.model.AlbumPage
import com.onda.seaglass.model.ArtistPage
import com.onda.seaglass.model.MusicItem
import com.onda.seaglass.model.PlaylistPage
import com.onda.seaglass.model.Track
import com.onda.seaglass.playback.PlayerController
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

sealed class CatalogRoute {
    data object None : CatalogRoute()
    data class Artist(val id: String) : CatalogRoute()
    data class Album(val id: String) : CatalogRoute()
    data class Playlist(val id: String) : CatalogRoute()
}

@Composable
fun ArtistPageView(id: String, onBack: () -> Unit, onOpen: (CatalogRoute) -> Unit) {
    var page by remember(id) { mutableStateOf<ArtistPage?>(null) }
    var error by remember(id) { mutableStateOf<String?>(null) }
    LaunchedEffect(id) {
        error = null
        page = null
        runCatching { withContext(Dispatchers.IO) { InnerTube.artist(id) } }
            .onSuccess { page = it }
            .onFailure { error = it.message }
    }
    Column(Modifier.fillMaxSize()) {
        TextButton(onClick = onBack) { Text("← Indietro") }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        page?.let { artist ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Artwork(artist.artworkUrl, size = 120.dp, corner = 12.dp)
                Spacer(Modifier.width(16.dp))
                Column {
                    Text(artist.name, fontSize = 28.sp, fontWeight = FontWeight.Bold)
                    artist.about?.take(200)?.let {
                        Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                    }
                    if (artist.topSongs.isNotEmpty()) {
                        Spacer(Modifier.height(8.dp))
                        Button(onClick = { PlayerController.play(artist.topSongs, 0) }) { Text("Riproduci") }
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
            Text("Brani in evidenza", fontWeight = FontWeight.SemiBold)
            LazyColumn {
                itemsIndexed(artist.topSongs) { index, track ->
                    TrackListRow(track) { PlayerController.play(artist.topSongs, index) }
                }
                artist.shelves.forEach { shelf ->
                    item {
                        Spacer(Modifier.height(12.dp))
                        Text(shelf.title, fontWeight = FontWeight.SemiBold)
                    }
                    items(shelf.items) { item ->
                        CatalogItemRow(item) {
                            when (item.kind) {
                                MusicItem.Kind.ARTIST -> onOpen(CatalogRoute.Artist(item.id))
                                MusicItem.Kind.ALBUM -> onOpen(CatalogRoute.Album(item.id))
                                MusicItem.Kind.PLAYLIST -> onOpen(CatalogRoute.Playlist(item.id))
                                MusicItem.Kind.SONG -> item.track?.let { PlayerController.playRadio(it) }
                                else -> Unit
                            }
                        }
                    }
                }
            }
        } ?: if (error == null) Text("Caricamento…") else Unit
    }
}

@Composable
fun AlbumPageView(id: String, onBack: () -> Unit) {
    var page by remember(id) { mutableStateOf<AlbumPage?>(null) }
    var error by remember(id) { mutableStateOf<String?>(null) }
    LaunchedEffect(id) {
        error = null
        page = null
        runCatching { withContext(Dispatchers.IO) { InnerTube.album(id) } }
            .onSuccess { page = it }
            .onFailure { error = it.message }
    }
    Column(Modifier.fillMaxSize()) {
        TextButton(onClick = onBack) { Text("← Indietro") }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        page?.let { album ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Artwork(album.artworkUrl, size = 140.dp, corner = 8.dp)
                Spacer(Modifier.width(16.dp))
                Column {
                    Text(album.title, fontSize = 26.sp, fontWeight = FontWeight.Bold)
                    Text(album.artist, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(listOf(album.kindAndYear, album.details).filter { it.isNotBlank() }.joinToString(" · "),
                        fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(8.dp))
                    Button(onClick = { PlayerController.play(album.tracks, 0) }) { Text("Riproduci") }
                }
            }
            Spacer(Modifier.height(16.dp))
            LazyColumn {
                itemsIndexed(album.tracks) { index, track ->
                    TrackListRow(track) { PlayerController.play(album.tracks, index) }
                }
            }
        } ?: if (error == null) Text("Caricamento…") else Unit
    }
}

@Composable
fun PlaylistPageView(id: String, onBack: () -> Unit) {
    var page by remember(id) { mutableStateOf<PlaylistPage?>(null) }
    var error by remember(id) { mutableStateOf<String?>(null) }
    LaunchedEffect(id) {
        error = null
        page = null
        runCatching { withContext(Dispatchers.IO) { InnerTube.playlist(id) } }
            .onSuccess { page = it }
            .onFailure { error = it.message }
    }
    Column(Modifier.fillMaxSize()) {
        TextButton(onClick = onBack) { Text("← Indietro") }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        page?.let { playlist ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Artwork(playlist.artworkUrl, size = 140.dp, corner = 8.dp)
                Spacer(Modifier.width(16.dp))
                Column {
                    Text(playlist.title, fontSize = 26.sp, fontWeight = FontWeight.Bold)
                    Text(playlist.subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                    Spacer(Modifier.height(8.dp))
                    Button(onClick = { PlayerController.play(playlist.tracks, 0) }) { Text("Riproduci") }
                }
            }
            Spacer(Modifier.height(16.dp))
            LazyColumn {
                itemsIndexed(playlist.tracks) { index, track ->
                    TrackListRow(track) { PlayerController.play(playlist.tracks, index) }
                }
            }
        } ?: if (error == null) Text("Caricamento…") else Unit
    }
}

@Composable
fun TrackListRow(track: Track, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Artwork(track.mediumArtwork, size = 44.dp)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(track.title, fontWeight = FontWeight.SemiBold)
            Text(track.artist, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
        }
    }
}

@Composable
fun CatalogItemRow(item: MusicItem, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Artwork(item.artworkUrl, size = 48.dp)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(item.title, fontWeight = FontWeight.SemiBold)
            Text(item.subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
        }
    }
}
