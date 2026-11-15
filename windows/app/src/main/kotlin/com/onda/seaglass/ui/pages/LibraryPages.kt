package com.onda.seaglass.ui.pages

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.PlaylistAdd
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.RemoveCircleOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Downloads
import com.onda.seaglass.data.InnerTube
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.LocalMusic
import com.onda.seaglass.ui.EmptyState
import com.onda.seaglass.ui.LocalPalette
import com.onda.seaglass.ui.Nav
import com.onda.seaglass.ui.PageHeader
import com.onda.seaglass.ui.PillButton
import com.onda.seaglass.ui.PlayShuffleButtons
import com.onda.seaglass.ui.RemoteImage
import com.onda.seaglass.ui.Route
import com.onda.seaglass.ui.TrackList
import kotlinx.coroutines.launch
import java.io.File
import javax.swing.JFileChooser

@Composable
private fun Title(text: String) {
    Text(text, fontSize = 34.sp, fontWeight = FontWeight.Bold, color = LocalPalette.current.text, modifier = Modifier.padding(bottom = 14.dp))
}

@Composable
fun LikedPage() {
    val liked by Library.liked.collectAsState()
    Page {
        PageHeader(tr("Brani preferiti"), null, tr("%lld brani", liked.size), liked.firstOrNull()?.largeArtwork) {
            if (liked.isNotEmpty()) {
                PlayShuffleButtons(liked, tr("Brani preferiti"))
                PillButton(tr("Scarica"), Icons.Rounded.Download) { Downloads.download(liked) }
            }
        }
        if (liked.isEmpty()) EmptyState(Icons.Rounded.Favorite, tr("Nessun brano preferito"), tr("Fai clic sul cuore di un brano per salvarlo qui."))
        else TrackList(liked, tr("Brani preferiti"))
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PlaylistsPage() {
    val palette = LocalPalette.current
    val playlists by Library.playlists.collectAsState()
    var creating by remember { mutableStateOf(false) }
    var importing by remember { mutableStateOf(false) }
    Page {
        Title(tr("Playlist"))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PillButton(tr("Nuova playlist"), Icons.Rounded.Add, prominent = true) { creating = true }
            PillButton(tr("Importa da un link"), Icons.Rounded.Link) {
                // A Premium feature, as on the iPhone.
                if (com.onda.seaglass.account.Account.unlocks()) importing = true else Nav.premium = tr("Importa playlist da link")
            }
        }
        if (playlists.isEmpty()) {
            EmptyState(Icons.AutoMirrored.Rounded.QueueMusic, tr("Nessuna playlist"))
        } else {
            FlowRow(Modifier.padding(top = 20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                playlists.forEach { playlist ->
                    Column(Modifier.width(184.dp).clip(RoundedCornerShape(10.dp)).clickable { Nav.open(Route.Playlist(playlist.id)) }.padding(8.dp)) {
                        RemoteImage(playlist.tracks.firstOrNull()?.resized(400), Modifier.size(168.dp), RoundedCornerShape(8.dp))
                        Text(playlist.name, color = palette.text, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 8.dp))
                        Text(tr("%lld brani", playlist.tracks.size), color = palette.secondary, fontSize = 12.sp)
                    }
                }
            }
        }
    }
    if (creating) NameDialog(tr("Nuova playlist"), "", tr("Crea"), onDismiss = { creating = false }) { name ->
        val created = Library.createPlaylist(name)
        creating = false
        Nav.open(Route.Playlist(created.id))
    }
    if (importing) ImportDialog { importing = false }
}

/** A YouTube Music playlist's link copied into the library. */
@Composable
private fun ImportDialog(onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var link by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(tr("Importa da un link")) },
        text = {
            Column {
                Text(tr("Incolla il link di una playlist di YouTube Music o YouTube."), fontSize = 13.sp)
                OutlinedTextField(link, { link = it; error = null }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(top = 10.dp))
                if (working) LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 10.dp))
                error?.let { Text(it, color = androidx.compose.ui.graphics.Color(0xFFFF6B6B), fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp)) }
            }
        },
        confirmButton = {
            TextButton(enabled = link.isNotBlank() && !working, onClick = {
                val id = InnerTube.playlistId(link.trim())
                if (id == null) {
                    error = tr("Link non riconosciuto")
                    return@TextButton
                }
                working = true
                scope.launch {
                    runCatching { InnerTube.playlist(id) }
                        .onSuccess { page ->
                            val created = Library.createPlaylist(page.title.ifBlank { tr("Playlist importata") }, page.tracks)
                            onDismiss()
                            Nav.open(Route.Playlist(created.id))
                        }
                        .onFailure { error = it.message ?: tr("Importazione non riuscita") }
                    working = false
                }
            }) { Text(tr("Importa")) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(tr("Annulla")) } },
    )
}

@Composable
fun NameDialog(title: String, initial: String, action: String, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var name by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { OutlinedTextField(name, { name = it }, label = { Text(tr("Nome")) }, singleLine = true) },
        confirmButton = { TextButton(enabled = name.isNotBlank(), onClick = { onConfirm(name.trim()) }) { Text(action) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(tr("Annulla")) } },
    )
}

@Composable
fun PlaylistPageView(id: String) {
    val playlists by Library.playlists.collectAsState()
    val playlist = playlists.firstOrNull { it.id == id }
    var renaming by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    if (playlist == null) {
        Page { EmptyState(Icons.AutoMirrored.Rounded.QueueMusic, tr("Playlist non trovata")) }
        return
    }
    Page {
        PageHeader(playlist.name, null, tr("%lld brani", playlist.tracks.size), playlist.tracks.firstOrNull()?.largeArtwork) {
            if (playlist.tracks.isNotEmpty()) PlayShuffleButtons(playlist.tracks, playlist.name)
            PillButton(tr("Rinomina"), Icons.Rounded.Edit) { renaming = true }
            if (playlist.tracks.isNotEmpty()) PillButton(tr("Scarica"), Icons.Rounded.Download) { Downloads.download(playlist.tracks) }
            PillButton(tr("Elimina"), Icons.Rounded.Delete) { deleting = true }
        }
        if (playlist.tracks.isEmpty()) {
            EmptyState(Icons.AutoMirrored.Rounded.PlaylistAdd, tr("Playlist vuota"), tr("Aggiungi brani dal menu ··· di un brano."))
        } else {
            TrackList(playlist.tracks, playlist.name, extraMenu = { _, index ->
                { close ->
                    if (index > 0) DropdownMenuItem(text = { Text(tr("Sposta su")) }, leadingIcon = { Icon(Icons.Rounded.KeyboardArrowUp, null) }, onClick = { close(); Library.moveTrack(index, index - 1, playlist.id) })
                    if (index < playlist.tracks.lastIndex) DropdownMenuItem(text = { Text(tr("Sposta giù")) }, leadingIcon = { Icon(Icons.Rounded.KeyboardArrowDown, null) }, onClick = { close(); Library.moveTrack(index, index + 1, playlist.id) })
                    DropdownMenuItem(text = { Text(tr("Rimuovi dalla playlist")) }, leadingIcon = { Icon(Icons.Rounded.RemoveCircleOutline, null) }, onClick = { close(); Library.removeTrack(index, playlist.id) })
                }
            })
        }
    }
    if (renaming) NameDialog(tr("Rinomina"), playlist.name, tr("Salva"), onDismiss = { renaming = false }) {
        Library.renamePlaylist(playlist.id, it)
        renaming = false
    }
    if (deleting) AlertDialog(
        onDismissRequest = { deleting = false },
        title = { Text(tr("Eliminare la playlist?")) },
        text = { Text(tr("La playlist “%@” verrà eliminata. I brani restano disponibili.", playlist.name)) },
        confirmButton = { TextButton(onClick = { deleting = false; Library.deletePlaylist(playlist.id); Nav.section(Route.Playlists) }) { Text(tr("Elimina")) } },
        dismissButton = { TextButton(onClick = { deleting = false }) { Text(tr("Annulla")) } },
    )
}

@Composable
fun DownloadsPage() {
    val palette = LocalPalette.current
    val items by Downloads.items.collectAsState()
    val done = items.values.filter { it.isComplete }.map { it.track }
    val active = items.values.filter { !it.isComplete }
    Page {
        Title(tr("Scaricati"))
        if (done.isNotEmpty()) Row(Modifier.padding(bottom = 12.dp)) { PlayShuffleButtons(done, tr("Scaricati")) }
        active.forEach { item ->
            Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                RemoteImage(item.track.resized(120), Modifier.size(40.dp), RoundedCornerShape(5.dp))
                Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                    Text(item.track.title, color = palette.text, fontSize = 14.sp, maxLines = 1)
                    if (item.state == Downloads.State.FAILED) Text(tr("Download non riuscito"), color = palette.secondary, fontSize = 12.sp)
                    else LinearProgressIndicator(progress = { item.progress }, Modifier.fillMaxWidth().padding(top = 6.dp))
                }
                if (item.state == Downloads.State.FAILED) {
                    PillButton(tr("Riprova"), Icons.Rounded.Refresh) { Downloads.download(listOf(item.track)) }
                } else {
                    PillButton(tr("Annulla")) { Downloads.cancel(listOf(item.track)) }
                }
            }
        }
        if (done.isEmpty() && active.isEmpty()) {
            EmptyState(Icons.Rounded.Download, tr("Nessun brano scaricato"), tr("I brani scaricati si ascoltano anche senza connessione."))
        } else if (done.isNotEmpty()) {
            TrackList(done, tr("Scaricati"))
            Text(tr("Spazio usato: %@", formatBytes(Downloads.bytes)), color = palette.tertiary, fontSize = 12.sp, modifier = Modifier.padding(top = 14.dp))
        }
    }
}

fun formatBytes(bytes: Long): String = when {
    bytes >= 1L shl 30 -> "%.1f GB".format(bytes / (1L shl 30).toDouble())
    bytes >= 1L shl 20 -> "%.0f MB".format(bytes / (1L shl 20).toDouble())
    else -> "%.0f KB".format(bytes / 1024.0)
}

@Composable
fun HistoryPage() {
    val history by Library.history.collectAsState()
    var clearing by remember { mutableStateOf(false) }
    Page {
        Title(tr("Cronologia"))
        if (history.isEmpty()) {
            EmptyState(Icons.Rounded.History, tr("Nessun brano ascoltato"))
        } else {
            Row(Modifier.padding(bottom = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PlayShuffleButtons(history, tr("Cronologia"))
                PillButton(tr("Cancella cronologia"), Icons.Rounded.Delete) { clearing = true }
            }
            TrackList(history, tr("Cronologia"), extraMenu = { track, _ ->
                { close -> DropdownMenuItem(text = { Text(tr("Rimuovi dalla cronologia")) }, leadingIcon = { Icon(Icons.Rounded.RemoveCircleOutline, null) }, onClick = { close(); Library.removeFromHistory(track) }) }
            })
        }
    }
    if (clearing) AlertDialog(
        onDismissRequest = { clearing = false },
        title = { Text(tr("Cancellare la cronologia?")) },
        confirmButton = { TextButton(onClick = { clearing = false; Library.clearHistory() }) { Text(tr("Cancella")) } },
        dismissButton = { TextButton(onClick = { clearing = false }) { Text(tr("Annulla")) } },
    )
}

@Composable
fun LocalSongsPage() {
    val palette = LocalPalette.current
    val songs by LocalMusic.songs.collectAsState()
    val scanning by LocalMusic.scanning.collectAsState()
    val scope = rememberCoroutineScope()
    val tracks = songs.map { it.track }
    Page {
        Title(tr("I tuoi brani"))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            if (tracks.isNotEmpty()) PlayShuffleButtons(tracks, tr("I tuoi brani"))
            PillButton(tr("Aggiungi una cartella"), Icons.Rounded.Folder) {
                chooseFolder()?.let { folder -> scope.launch { LocalMusic.addFolder(folder) } }
            }
            if (LocalMusic.folders.isNotEmpty()) PillButton(tr("Aggiorna"), Icons.Rounded.Refresh) { scope.launch { LocalMusic.rescan() } }
        }
        if (scanning) LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 12.dp))
        LocalMusic.folders.forEach { folder ->
            Row(Modifier.padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Folder, null, Modifier.size(16.dp), tint = palette.secondary)
                Text(folder, color = palette.secondary, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 8.dp))
                Text(tr("Rimuovi"), color = palette.accent, fontSize = 12.sp, modifier = Modifier.clickable { scope.launch { LocalMusic.removeFolder(folder) } })
            }
        }
        if (tracks.isEmpty() && !scanning) {
            EmptyState(Icons.Rounded.Folder, tr("Nessun brano"), tr("Scegli una cartella con la tua musica: Seaglass la legge soltanto, senza modificarla."))
        } else {
            Box(Modifier.padding(top = 14.dp)) { TrackList(tracks, tr("I tuoi brani")) }
        }
    }
}

/** Windows's folder picker. */
private fun chooseFolder(): File? {
    val chooser = JFileChooser().apply {
        fileSelectionMode = JFileChooser.DIRECTORIES_ONLY
        dialogTitle = tr("Aggiungi una cartella")
    }
    return if (chooser.showOpenDialog(null) == JFileChooser.APPROVE_OPTION) chooser.selectedFile else null
}
