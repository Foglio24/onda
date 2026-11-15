package com.onda.seaglass.ui.pages

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.automirrored.rounded.Login
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.core.Log
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.PlaylistImport
import com.onda.seaglass.data.PlaylistImportFile
import com.onda.seaglass.model.Track
import com.onda.seaglass.ui.LocalPalette
import com.onda.seaglass.ui.Nav
import com.onda.seaglass.ui.PillButton
import com.onda.seaglass.ui.RemoteImage
import com.onda.seaglass.ui.Route
import kotlinx.coroutines.launch
import java.io.File

/** Exportify: signs in to Spotify (with its own registered app) and saves any playlist, whole, as a CSV. */
private const val EXPORTIFY = "https://exportify.net/"

private fun openInBrowser(url: String) {
    runCatching { java.awt.Desktop.getDesktop().browse(java.net.URI(url)) }
}

/** A CSV or JSON file chosen with Windows's own Open dialog; null if cancelled. */
private fun choosePlaylistFile(): File? {
    val dialog = java.awt.FileDialog(null as java.awt.Frame?, tr("Importa playlist da file"), java.awt.FileDialog.LOAD)
    // Windows reads the pattern as the dialog's filter; elsewhere the filename filter does it.
    dialog.file = "*.csv;*.json"
    dialog.setFilenameFilter { _, name -> name.lowercase().let { it.endsWith(".csv") || it.endsWith(".json") } }
    dialog.isVisible = true
    val name = dialog.file ?: return null
    return File(dialog.directory, name)
}

/**
 * "Importa playlist", as on the iPhone: a link to a public playlist or album of Spotify, Apple
 * Music, YouTube or YouTube Music, or a file for Spotify playlists over 100 songs (Exportify's CSV,
 * or Playlist1.json from Spotify's account data), or the user's own Spotify account
 * ([onSpotifyAccount]: every playlist, private ones too). While it works it says what it's doing; then
 * the summary shows what's in the playlist and what to check.
 */
@Composable
fun ImportPlaylistDialog(onSpotifyAccount: () -> Unit, onDismiss: () -> Unit) {
    val palette = LocalPalette.current
    val scope = rememberCoroutineScope()
    var link by remember { mutableStateOf("") }
    var status by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var outcome by remember { mutableStateOf<PlaylistImport.Outcome?>(null) }
    // A Spotify data export holds every playlist of the account: one is chosen.
    var choices by remember { mutableStateOf<List<PlaylistImport.Source>?>(null) }

    outcome?.let { done ->
        ImportSummaryDialog(done) {
            onDismiss()
            Nav.section(Route.Playlist(done.playlist.id))
        }
        return
    }

    fun run(block: suspend ((String) -> Unit) -> PlaylistImport.Outcome) {
        error = null
        status = tr("Lettura della playlist…")
        scope.launch {
            try {
                outcome = block { message -> status = message }
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                Log.warn("Playlist import failed", e)
                error = (e as? java.io.IOException)?.message?.takeIf { it.isNotBlank() && "HTTP" !in it } ?: tr("Importazione non riuscita")
            } finally {
                status = null
            }
        }
    }

    val working = status != null
    AlertDialog(
        onDismissRequest = { if (!working) onDismiss() },
        title = { Text(tr("Importa playlist")) },
        text = {
            Column(Modifier.width(480.dp)) {
                val chooseFrom = choices
                if (chooseFrom != null && !working) {
                    Text(tr("Elementi letti"), color = palette.secondary, fontSize = 13.sp)
                    LazyColumn(Modifier.heightIn(max = 320.dp).padding(top = 8.dp)) {
                        items(chooseFrom) { source ->
                            Row(
                                Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).clickable {
                                    choices = null
                                    run { progress -> PlaylistImport.importSource(source, progress) }
                                }.padding(horizontal = 8.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(source.name ?: tr("Playlist importata"), color = palette.text, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                                Text(tr("%lld brani", source.rows.size), color = palette.secondary, fontSize = 13.sp)
                            }
                        }
                    }
                    return@Column
                }
                Text(
                    tr("Incolla il link di una playlist o di un album pubblico di Spotify, Apple Music, YouTube o YouTube Music. Se Spotify mostra solo i primi 100 brani, puoi importare una lista completa da file."),
                    fontSize = 13.sp, lineHeight = 18.sp,
                )
                OutlinedTextField(
                    link, { link = it; error = null }, singleLine = true, enabled = !working,
                    placeholder = { Text("https://open.spotify.com/playlist/…", maxLines = 1) },
                    modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
                )
                status?.let { message ->
                    Row(Modifier.padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(16.dp), color = palette.accent, strokeWidth = 2.dp)
                        Spacer(Modifier.width(10.dp))
                        Text(message, fontSize = 13.sp)
                    }
                }
                error?.let { Text(it, color = Color(0xFFFF7A7A), fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp)) }
                // Spotify's own account: every playlist, private or long, read after signing in (Edge).
                Column(Modifier.fillMaxWidth().padding(top = 16.dp).clip(RoundedCornerShape(8.dp)).background(palette.cardHover).padding(12.dp)) {
                    Text(
                        tr("Accedi a Spotify in una finestra di Microsoft Edge: Seaglass legge le tue playlist, anche private o con più di 100 brani, e cerca ogni brano su YouTube Music."),
                        fontSize = 13.sp, lineHeight = 18.sp, color = palette.text,
                    )
                    Row(Modifier.padding(top = 10.dp)) {
                        PillButton(tr("Accedi a Spotify"), Icons.AutoMirrored.Rounded.Login) { if (!working) onSpotifyAccount() }
                    }
                }
                // Long Spotify playlists: a file, made by Exportify (or Spotify's data export).
                Column(Modifier.fillMaxWidth().padding(top = 16.dp).clip(RoundedCornerShape(8.dp)).background(palette.cardHover).padding(12.dp)) {
                    Text(
                        tr("Per playlist Spotify oltre 100 brani puoi importare un CSV o il file Playlist1.json dei tuoi dati Spotify."),
                        fontSize = 13.sp, lineHeight = 18.sp, color = palette.text,
                    )
                    Text(
                        tr("Su exportify.net accedi con Spotify e scarica il CSV della playlist: contiene tutti i brani."),
                        fontSize = 12.sp, lineHeight = 17.sp, color = palette.secondary, modifier = Modifier.padding(top = 4.dp),
                    )
                    Row(Modifier.padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        PillButton(tr("Apri Exportify"), Icons.AutoMirrored.Rounded.OpenInNew) { openInBrowser(EXPORTIFY) }
                        PillButton(tr("Importa playlist da file"), Icons.Rounded.Description) {
                            if (working) return@PillButton
                            val file = choosePlaylistFile() ?: return@PillButton
                            error = null
                            val sources = try {
                                PlaylistImportFile.read(file.readBytes(), file.name)
                            } catch (e: java.io.IOException) {
                                error = e.message
                                return@PillButton
                            }
                            if (sources.size == 1) run { progress -> PlaylistImport.importSource(sources.first(), progress) } else choices = sources
                        }
                    }
                }
            }
        },
        confirmButton = {
            if (choices == null) {
                TextButton(enabled = link.isNotBlank() && !working, onClick = { run { progress -> PlaylistImport.importLink(link, progress) } }) {
                    Text(tr("Importa"))
                }
            }
        },
        dismissButton = {
            TextButton(enabled = !working, onClick = { if (choices != null) choices = null else onDismiss() }) { Text(tr("Annulla")) }
        },
    )
}

/** What the import did: the songs in the new playlist, and each one to check, with alternatives to choose. */
@Composable
internal fun ImportSummaryDialog(outcome: PlaylistImport.Outcome, onDone: () -> Unit) {
    val palette = LocalPalette.current
    val resolved = remember { mutableStateListOf<PlaylistImport.Entry>() }
    var open by remember { mutableStateOf<PlaylistImport.Entry?>(null) }
    val toCheck = outcome.toCheck
    val found = outcome.entries.size - toCheck.size + resolved.size
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text(tr("Riepilogo importazione")) },
        text = {
            Column(Modifier.width(520.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    Column {
                        Text("$found", color = palette.text, fontSize = 26.sp, fontWeight = FontWeight.Bold)
                        Text(tr("Brani nella playlist"), color = palette.secondary, fontSize = 12.sp)
                    }
                    Column {
                        Text("${toCheck.size - resolved.size}", color = if (toCheck.size > resolved.size) palette.accent else palette.text, fontSize = 26.sp, fontWeight = FontWeight.Bold)
                        Text(tr("Da controllare"), color = palette.secondary, fontSize = 12.sp)
                    }
                }
                if (outcome.mayBeTruncated) {
                    Row(Modifier.fillMaxWidth().padding(top = 12.dp).clip(RoundedCornerShape(8.dp)).background(palette.cardHover).padding(10.dp)) {
                        Icon(Icons.Rounded.WarningAmber, null, Modifier.size(18.dp), tint = palette.accent)
                        Spacer(Modifier.width(8.dp))
                        Column {
                            Text(
                                tr("Spotify potrebbe aver mostrato solo i primi 100 brani. Controlla la playlist originale; per importare una lista più lunga usa un file Spotify JSON o CSV."),
                                fontSize = 13.sp, lineHeight = 18.sp,
                            )
                            Text(tr("Apri Exportify"), color = palette.accent, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.padding(top = 6.dp).clickable { openInBrowser(EXPORTIFY) })
                        }
                    }
                }
                if (toCheck.isNotEmpty()) {
                    Text(tr("Scegli il brano che corrisponde, oppure modifica la ricerca."), color = palette.secondary, fontSize = 12.sp,
                        modifier = Modifier.padding(top = 14.dp, bottom = 4.dp))
                    LazyColumn(Modifier.heightIn(max = 340.dp)) {
                        items(toCheck) { entry ->
                            CheckRow(outcome, entry, entry in resolved, expanded = open == entry,
                                onToggle = { open = if (open == entry) null else entry },
                                onResolved = {
                                    resolved.add(entry)
                                    open = null
                                })
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDone) { Text(tr("Fine")) } },
    )
}

@Composable
private fun CheckRow(outcome: PlaylistImport.Outcome, entry: PlaylistImport.Entry, done: Boolean, expanded: Boolean, onToggle: () -> Unit, onResolved: () -> Unit) {
    val palette = LocalPalette.current
    val scope = rememberCoroutineScope()
    var suggestions by remember { mutableStateOf<List<Track>?>(null) }
    var loading by remember { mutableStateOf(false) }
    val reason = when (entry.issue) {
        PlaylistImport.Issue.NOT_FOUND -> tr("Non trovato: scegli un'alternativa")
        PlaylistImport.Issue.SEARCH_FAILED -> tr("Ricerca non riuscita: riprova")
        PlaylistImport.Issue.DUPLICATE -> tr("Già presente nella playlist")
        PlaylistImport.Issue.UNSUPPORTED -> tr("Elemento non musicale non importato")
        else -> tr("Dati del brano non disponibili")
    }
    // Only songs with a title and an artist can be looked up again.
    val searchable = !done && entry.issue in listOf(PlaylistImport.Issue.NOT_FOUND, PlaylistImport.Issue.SEARCH_FAILED)
    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp).clip(RoundedCornerShape(6.dp))
        .background(if (expanded) palette.cardHover else Color.Transparent)) {
        Row(
            Modifier.fillMaxWidth().clickable(enabled = searchable) {
                onToggle()
                if (suggestions == null && !loading) {
                    loading = true
                    scope.launch {
                        suggestions = runCatching { PlaylistImport.suggestions(entry.row) }.getOrDefault(emptyList())
                        loading = false
                    }
                }
            }.padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(entry.row.label, color = palette.text, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(if (done) tr("Aggiunto a %@", outcome.playlist.name) else reason, color = if (done) palette.accent else palette.secondary,
                    fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (done) Icon(Icons.Rounded.CheckCircle, null, Modifier.size(18.dp), tint = palette.accent)
        }
        if (expanded && searchable) {
            when {
                loading -> Box(Modifier.fillMaxWidth().padding(12.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(Modifier.size(18.dp), color = palette.accent, strokeWidth = 2.dp)
                }
                suggestions.isNullOrEmpty() -> Text(tr("Nessun risultato. Prova a modificare la ricerca."), color = palette.secondary, fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 8.dp))
                else -> suggestions.orEmpty().forEach { track ->
                    Row(
                        Modifier.fillMaxWidth().clickable { if (PlaylistImport.resolve(outcome, entry, track)) onResolved() }
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RemoteImage(track.resized(120), Modifier.size(36.dp), RoundedCornerShape(4.dp))
                        Spacer(Modifier.width(10.dp))
                        Column(Modifier.weight(1f)) {
                            Text(track.title, color = palette.text, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(track.artist, color = palette.secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Text(com.onda.seaglass.model.formatDuration(track.duration), color = palette.secondary, fontSize = 12.sp)
                    }
                }
            }
        }
    }
}
