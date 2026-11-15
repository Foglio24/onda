package com.onda.seaglass.ui.pages

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.core.tr
import com.onda.seaglass.spotify.SpotifyBrowser
import com.onda.seaglass.spotify.SpotifyImport
import com.onda.seaglass.spotify.SpotifyPlaylist
import com.onda.seaglass.ui.LocalPalette
import com.onda.seaglass.ui.Nav
import com.onda.seaglass.ui.RemoteImage
import com.onda.seaglass.ui.Route
import kotlinx.coroutines.launch

/**
 * Imports playlists from the user's Spotify account: sign in (in an Edge window, the first time),
 * pick the playlists, and each one becomes a Seaglass playlist of the songs found on YouTube Music.
 */
@Composable
fun SpotifyImportDialog(onDismiss: () -> Unit) {
    val palette = LocalPalette.current
    val scope = rememberCoroutineScope()
    val status by SpotifyImport.status.collectAsState()
    var playlists by remember { mutableStateOf<List<SpotifyPlaylist>?>(null) }
    var selected by remember { mutableStateOf(emptySet<String>()) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var result by remember { mutableStateOf<String?>(null) }
    var summary by remember { mutableStateOf<com.onda.seaglass.data.PlaylistImport.Outcome?>(null) }

    // One playlist: the same summary as a link or a file, with the songs to check.
    summary?.let { done ->
        ImportSummaryDialog(done) {
            onDismiss()
            Nav.section(Route.Playlist(done.playlist.id))
        }
        return
    }

    fun load() {
        working = true
        error = null
        scope.launch {
            runCatching { SpotifyImport.playlists() }
                .onSuccess { playlists = it }
                .onFailure { error = it.message ?: tr("Importazione non riuscita") }
            working = false
        }
    }

    AlertDialog(
        onDismissRequest = { if (!working) onDismiss() },
        title = { Text(tr("Importa da Spotify")) },
        text = {
            Column(Modifier.fillMaxWidth()) {
                val list = playlists
                when {
                    result != null -> Text(result!!, fontSize = 13.sp)
                    working -> {
                        Text(status ?: tr("Lettura delle playlist da Spotify…"), fontSize = 13.sp)
                        LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 12.dp))
                    }
                    list == null -> Text(
                        tr("Accedi a Spotify in una finestra di Microsoft Edge: Seaglass legge le tue playlist, anche private o con più di 100 brani, e cerca ogni brano su YouTube Music."),
                        fontSize = 13.sp,
                    )
                    list.isEmpty() -> Text(tr("Nessuna playlist trovata su Spotify."), fontSize = 13.sp)
                    else -> LazyColumn(Modifier.heightIn(max = 380.dp)) {
                        items(list, key = { it.uri }) { playlist ->
                            val checked = playlist.uri in selected
                            Row(
                                Modifier.fillMaxWidth()
                                    .clickable { selected = if (checked) selected - playlist.uri else selected + playlist.uri }
                                    .padding(vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Checkbox(checked, onCheckedChange = { selected = if (it) selected + playlist.uri else selected - playlist.uri })
                                RemoteImage(playlist.imageUrl, Modifier.size(40.dp), RoundedCornerShape(4.dp))
                                Column(Modifier.padding(start = 10.dp)) {
                                    Text(playlist.name, color = palette.text, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    playlist.owner?.let { Text(it, color = palette.secondary, fontSize = 12.sp, maxLines = 1) }
                                }
                            }
                        }
                    }
                }
                error?.let { Text(it, color = Color(0xFFFF6B6B), fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp)) }
            }
        },
        confirmButton = {
            val list = playlists
            when {
                result != null -> TextButton(onClick = onDismiss) { Text(tr("Chiudi")) }
                list == null -> TextButton(enabled = !working, onClick = ::load) {
                    Text(if (error == null) tr("Accedi a Spotify") else tr("Riprova"))
                }
                else -> TextButton(enabled = !working && selected.isNotEmpty(), onClick = {
                    working = true
                    error = null
                    scope.launch {
                        runCatching { SpotifyImport.import(list.filter { it.uri in selected }) }
                            .onSuccess { outcome ->
                                val only = outcome.imports.singleOrNull()
                                if (only != null) summary = only
                                else result = tr("Importate %lld playlist. %lld brani non trovati su YouTube Music.", outcome.imports.size, outcome.missing)
                            }
                            .onFailure { error = it.message ?: tr("Importazione non riuscita") }
                        working = false
                    }
                }) { Text(tr("Importa %lld playlist", selected.size)) }
            }
        },
        dismissButton = {
            if (!working && result == null) {
                Row {
                    if (playlists != null || SpotifyBrowser.hasProfile) {
                        TextButton(onClick = {
                            scope.launch {
                                SpotifyImport.signOut()
                                playlists = null
                                selected = emptySet()
                            }
                        }) { Text(tr("Esci da Spotify")) }
                    }
                    TextButton(onClick = onDismiss) { Text(tr("Annulla")) }
                }
            }
        },
    )
}
