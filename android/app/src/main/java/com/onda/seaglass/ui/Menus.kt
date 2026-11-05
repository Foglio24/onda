package com.onda.seaglass.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.PlaylistAdd
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.automirrored.rounded.PlaylistPlay
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Library
import com.onda.seaglass.model.Track
import com.onda.seaglass.playback.PlayerController

/** Every action on a song, as the iPhone app's "···" menu. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TrackMenu(
    track: Track,
    playlistId: String?,
    playlistIndex: Int?,
    onDismiss: () -> Unit,
    onShare: (Track) -> Unit,
    onArtist: (Track) -> Unit,
) {
    val app = LocalApp.current
    val liked by Library.liked.collectAsStateWithLifecycle()
    val isLiked = liked.any { it.videoId == track.videoId }
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheet,
        containerColor = Color(0xF21A1A22),
        dragHandle = null,
    ) {
        Column(Modifier.windowInsetsPadding(WindowInsets.navigationBars).padding(bottom = 8.dp)) {
            Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                Artwork(track.mediumArtwork, Modifier.size(56.dp), RoundedCornerShape(8.dp))
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(track.title, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(track.subtitle, color = Secondary, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
            fun act(action: () -> Unit): () -> Unit = {
                action()
                onDismiss()
            }
            MenuItem(Icons.AutoMirrored.Rounded.PlaylistPlay, tr("Riproduci dopo"), act {
                PlayerController.playNext(track)
                app.toast(tr("In coda"))
            })
            MenuItem(Icons.AutoMirrored.Rounded.QueueMusic, tr("Aggiungi in coda"), act {
                PlayerController.addToQueue(track)
                app.toast(tr("Aggiunto alla coda"))
            })
            MenuItem(Icons.Rounded.Radio, tr("Avvia radio"), act { PlayerController.playRadio(track) })
            MenuItem(
                if (isLiked) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                tr(if (isLiked) "Togli dai preferiti" else "Aggiungi ai preferiti"),
                act {
                    Library.toggleLike(track)
                    if (!isLiked) app.toast(tr("Aggiunto ai preferiti"))
                },
            )
            MenuItem(Icons.AutoMirrored.Rounded.PlaylistAdd, tr("Aggiungi a playlist…"), act { app.addToPlaylist(track) })
            MenuItem(Icons.Rounded.Person, tr("Vai all'artista"), act { onArtist(track) })
            track.albumId?.let { albumId -> MenuItem(Icons.Rounded.Album, tr("Vai all'album"), act { app.open("album/$albumId") }) }
            MenuItem(Icons.Rounded.Share, tr("Condividi"), act { onShare(track) })
            if (playlistId != null && playlistIndex != null) {
                MenuItem(Icons.Rounded.Delete, tr("Rimuovi"), act { Library.removeTrack(playlistIndex, playlistId) }, Color(0xFFFF6B6B))
            }
        }
    }
}

@Composable
private fun MenuItem(icon: ImageVector, title: String, onClick: () -> Unit, tint: Color = Color.White) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = tint.copy(alpha = 0.9f))
        Spacer(Modifier.width(18.dp))
        Text(title, color = tint, fontSize = 16.sp)
    }
}

/** "Aggiungi a playlist": tick the playlists the song belongs in, or make a new one. */
@Composable
fun PlaylistPicker(track: Track, onDismiss: () -> Unit) {
    val playlists by Library.playlists.collectAsStateWithLifecycle()
    var creating by remember { mutableStateOf(playlists.isEmpty()) }
    if (creating) {
        NameDialog(tr("Nuova playlist"), "", tr("Crea"), onDismiss = onDismiss) { name ->
            Library.createPlaylist(name, listOf(track))
            onDismiss()
        }
        return
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF1C1C24),
        title = { Text(tr("Aggiungi a playlist")) },
        text = {
            LazyColumn(Modifier.heightIn(max = 360.dp)) {
                item {
                    Row(
                        Modifier.fillMaxWidth().clickable { creating = true }.padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.AutoMirrored.Rounded.PlaylistAdd, null, tint = LocalAccent.current)
                        Spacer(Modifier.width(14.dp))
                        Text(tr("Nuova playlist"), color = LocalAccent.current, fontSize = 16.sp)
                    }
                }
                items(playlists, key = { it.id }) { playlist ->
                    val contains = playlist.tracks.any { it.videoId == track.videoId }
                    Row(
                        Modifier.fillMaxWidth().clickable { Library.toggle(track, playlist.id) }.padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Artwork(playlist.tracks.firstOrNull()?.mediumArtwork, Modifier.size(40.dp), RoundedCornerShape(6.dp))
                        Spacer(Modifier.width(14.dp))
                        Text(playlist.name, Modifier.weight(1f), fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (contains) Icon(Icons.Rounded.Check, null, tint = LocalAccent.current)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(tr("Fine")) } },
    )
}

/** Asks for a name (new playlist, rename) or a link (import). */
@Composable
fun NameDialog(
    title: String,
    initial: String,
    confirm: String,
    label: String = tr("Nome"),
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF1C1C24),
        title = { Text(title) },
        text = {
            OutlinedTextField(value = text, onValueChange = { text = it }, label = { Text(label) }, singleLine = true)
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(text) }, enabled = text.isNotBlank()) { Text(confirm) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(tr("Annulla")) } },
    )
}
