package com.onda.seaglass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.BuildConfig
import com.onda.seaglass.account.Account
import com.onda.seaglass.account.LibrarySync
import com.onda.seaglass.data.InnerTube
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.Mood
import com.onda.seaglass.data.Recommendations
import com.onda.seaglass.model.CatalogResults
import com.onda.seaglass.model.MusicItem
import com.onda.seaglass.model.Track
import com.onda.seaglass.model.formatDuration
import com.onda.seaglass.playback.PlayerController
import com.onda.seaglass.update.AppUpdater
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.awt.Desktop
import java.net.URI

enum class Page { Home, Search, Library, Settings }

@Composable
fun ClassicShell() {
    var page by remember { mutableStateOf(Page.Home) }
    var catalog by remember { mutableStateOf<CatalogRoute>(CatalogRoute.None) }
    var queueOpen by remember { mutableStateOf(true) }
    var showLyrics by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        UpdateBanner()
        Row(Modifier.weight(1f).fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            LibraryPanel(
                width = 260.dp,
                page = page,
                onSelect = {
                    page = it
                    catalog = CatalogRoute.None
                },
            )
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surface)
                    .padding(20.dp),
            ) {
                when (val route = catalog) {
                    is CatalogRoute.Artist -> ArtistPageView(route.id, onBack = { catalog = CatalogRoute.None }, onOpen = { catalog = it })
                    is CatalogRoute.Album -> AlbumPageView(route.id, onBack = { catalog = CatalogRoute.None })
                    is CatalogRoute.Playlist -> PlaylistPageView(route.id, onBack = { catalog = CatalogRoute.None })
                    CatalogRoute.None -> when (page) {
                        Page.Home -> HomePage(onOpen = { catalog = it })
                        Page.Search -> SearchPage(onOpen = { catalog = it })
                        Page.Library -> LibraryPage()
                        Page.Settings -> SettingsPage()
                    }
                }
            }
            if (queueOpen) {
                QueuePanel(width = 300.dp, showLyrics = showLyrics, onToggleLyrics = { showLyrics = !showLyrics })
            }
        }
        PlayerBar(queueOpen = queueOpen, onToggleQueue = { queueOpen = !queueOpen })
    }
}

@Composable
private fun UpdateBanner() {
    val status by AppUpdater.status.collectAsState()
    val scope = rememberCoroutineScope()
    when (val s = status) {
        is AppUpdater.Status.Available -> Banner(
            text = "Seaglass ${s.release.version} è disponibile",
            action = "Installa",
            onAction = { scope.launch { AppUpdater.downloadAndStage(s.release) } },
        )
        is AppUpdater.Status.Downloading -> {
            Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface).padding(8.dp)) {
                Text("Download aggiornamento…", color = MaterialTheme.colorScheme.onSurface)
                LinearProgressIndicator(
                    progress = { if (s.total > 0) (s.received.toFloat() / s.total).coerceIn(0f, 1f) else 0f },
                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                )
            }
        }
        is AppUpdater.Status.Ready -> Banner(
            text = "Seaglass ${s.release.version} è pronto",
            action = "Riavvia e installa",
            onAction = { if (AppUpdater.installAndRelaunch()) kotlin.system.exitProcess(0) },
        )
        is AppUpdater.Status.Failed -> Banner(text = "Aggiornamento: ${s.message}", action = null, onAction = {})
        else -> Unit
    }
}

@Composable
private fun Banner(text: String, action: String?, onAction: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)).padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.SystemUpdate, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(8.dp))
        Text(text, Modifier.weight(1f), color = MaterialTheme.colorScheme.onBackground)
        if (action != null) TextButton(onClick = onAction) { Text(action) }
    }
}

@Composable
private fun LibraryPanel(width: Dp, page: Page, onSelect: (Page) -> Unit) {
    Column(
        Modifier.width(width).fillMaxHeight().clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface).padding(12.dp),
    ) {
        Text("Seaglass", fontWeight = FontWeight.Bold, fontSize = 22.sp, color = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.height(16.dp))
        NavItem("Home", Icons.Default.Home, page == Page.Home) { onSelect(Page.Home) }
        NavItem("Cerca", Icons.Default.Search, page == Page.Search) { onSelect(Page.Search) }
        NavItem("La tua libreria", Icons.Default.LibraryMusic, page == Page.Library) { onSelect(Page.Library) }
        NavItem("Impostazioni", Icons.Default.Settings, page == Page.Settings) { onSelect(Page.Settings) }
        Spacer(Modifier.weight(1f))
        AccountChip()
    }
}

@Composable
private fun NavItem(label: String, icon: ImageVector, selected: Boolean, onClick: () -> Unit) {
    val bg = if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.2f) else MaterialTheme.colorScheme.surface
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(bg).clickable(onClick = onClick).padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurface)
        Spacer(Modifier.width(10.dp))
        Text(label, color = MaterialTheme.colorScheme.onSurface)
    }
    Spacer(Modifier.height(4.dp))
}

@Composable
private fun AccountChip() {
    val signedIn by Account.isSignedIn.collectAsState()
    val details by Account.details.collectAsState()
    val error by Account.signInError.collectAsState()
    val sync by Account.syncState.collectAsState()
    val scope = rememberCoroutineScope()
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.AccountCircle, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    if (signedIn) (details?.displayName ?: details?.email ?: "Account") else "Accedi",
                    fontWeight = FontWeight.SemiBold,
                )
                if (signedIn && details?.premium == true) {
                    Text("Premium", color = MaterialTheme.colorScheme.primary, fontSize = 12.sp)
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        if (signedIn) {
            TextButton(onClick = {
                scope.launch {
                    Desktop.getDesktop().browse(URI(Account.signedInManageUrl()))
                }
            }) { Text("Gestisci sul sito") }
            TextButton(onClick = { scope.launch { LibrarySync.pushAndPull() } }) {
                Text(when (sync) {
                    is Account.SyncState.Syncing -> "Sincronizzo…"
                    is Account.SyncState.Failed -> "Riprova sync"
                    else -> "Sincronizza"
                })
            }
            TextButton(onClick = { Account.signOut() }) { Text("Esci") }
        } else {
            Button(onClick = { scope.launch { Account.signIn() } }) { Text("Accedi con il sito") }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp) }
    }
}

@Composable
private fun QueuePanel(width: Dp, showLyrics: Boolean, onToggleLyrics: () -> Unit) {
    val player by PlayerController.state.collectAsState()
    Column(
        Modifier.width(width).fillMaxHeight().clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface).padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.AutoMirrored.Filled.QueueMusic, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text("Coda", fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            TextButton(onClick = onToggleLyrics) { Text(if (showLyrics) "Coda" else "Testo") }
        }
        Spacer(Modifier.height(12.dp))
        if (showLyrics) {
            LyricsPanel(player.track, player.positionSec)
        } else {
            Text("Stai ascoltando", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
            Text(player.track?.title ?: "—", fontWeight = FontWeight.SemiBold)
            Text(player.track?.artist.orEmpty(), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
            Spacer(Modifier.height(16.dp))
            Text("In coda", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
            if (player.queue.isEmpty()) {
                Text("Nessun brano. Cerca qualcosa e avvia la radio.")
            } else {
                LazyColumn {
                    itemsIndexed(player.queue) { index, track ->
                        TrackListRow(track, onClick = { PlayerController.play(player.queue, index) })
                    }
                }
            }
        }
    }
}

@Composable
private fun PlayerBar(queueOpen: Boolean, onToggleQueue: () -> Unit) {
    val player by PlayerController.state.collectAsState()
    val liked by Library.liked.collectAsState()
    val isLiked = player.track?.let { t -> liked.any { it.videoId == t.videoId } } == true
    Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface)) {
        if (player.durationSec > 0) {
            LinearProgressIndicator(
                progress = { (player.positionSec / player.durationSec).toFloat().coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().height(3.dp),
            )
        }
        Row(
            Modifier.fillMaxWidth().height(80.dp).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Artwork(player.track?.mediumArtwork, size = 56.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(player.track?.title ?: "Seaglass per Windows", fontWeight = FontWeight.SemiBold)
                val sub = when {
                    player.loading -> "Caricamento…"
                    player.error != null -> player.error
                    player.track != null -> listOfNotNull(player.track?.artist, player.format).joinToString(" · ")
                    else -> "v${BuildConfig.VERSION_NAME}"
                }
                Text(sub.orEmpty(), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
            }
            player.track?.let { track ->
                IconButton(onClick = { Library.toggleLike(track) }) {
                    Icon(
                        if (isLiked) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                        contentDescription = null,
                        tint = if (isLiked) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
            TextButton(onClick = { PlayerController.toggleShuffle() }) {
                Text(if (player.shuffle) "🔀✓" else "🔀")
            }
            TextButton(onClick = { PlayerController.previous() }) { Text("⏮") }
            TextButton(onClick = { PlayerController.toggle() }) { Text(if (player.playing) "⏸" else "▶") }
            TextButton(onClick = { PlayerController.next() }) { Text("⏭") }
            TextButton(onClick = { PlayerController.toggleRepeat() }) {
                Text(if (player.repeatQueue) "🔁✓" else "🔁")
            }
            Spacer(Modifier.width(8.dp))
            Text(
                "${formatDuration(player.positionSec)} / ${formatDuration(player.durationSec.takeIf { it > 0 })}",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.width(8.dp))
            Text("Vol", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(onClick = { PlayerController.setVolume(player.volume - 0.1) }) { Text("−") }
            Text("${(player.volume * 100).toInt()}%", fontSize = 11.sp)
            TextButton(onClick = { PlayerController.setVolume(player.volume + 0.1) }) { Text("+") }
            Spacer(Modifier.width(12.dp))
            TextButton(onClick = onToggleQueue) {
                Text(if (queueOpen) "Nascondi coda" else "Coda")
            }
        }
    }
}

@Composable
private fun HomePage(onOpen: (CatalogRoute) -> Unit) {
    var picks by remember { mutableStateOf<List<Track>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    fun load(refresh: Boolean) {
        scope.launch {
            loading = true
            error = null
            runCatching { Recommendations.quickPicks(refresh) }
                .onSuccess { picks = it }
                .onFailure { error = it.message }
            loading = false
        }
    }
    LaunchedEffect(Unit) { load(false) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Home", fontSize = 28.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            TextButton(onClick = { load(true) }) { Text("Aggiorna") }
        }
        Spacer(Modifier.height(8.dp))
        Text("Scelti per te", fontWeight = FontWeight.SemiBold)
        if (loading) Text("Caricamento…", color = MaterialTheme.colorScheme.onSurfaceVariant)
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        picks.forEachIndexed { index, track ->
            TrackListRow(track) { PlayerController.play(picks, index) }
        }
        Spacer(Modifier.height(20.dp))
        Text("Umore", fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Recommendations.moods.forEach { mood ->
                MoodChip(mood) {
                    scope.launch {
                        runCatching { withContext(Dispatchers.IO) { Recommendations.moodTracks(mood) } }
                            .onSuccess { if (it.isNotEmpty()) PlayerController.play(it, 0) }
                    }
                }
            }
        }
    }
}

@Composable
private fun MoodChip(mood: Mood, onClick: () -> Unit) {
    Box(
        Modifier
            .clip(RoundedCornerShape(10.dp))
            .background(Color(mood.tint).copy(alpha = 0.35f))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Text(mood.title, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun SearchPage(onOpen: (CatalogRoute) -> Unit) {
    var query by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var songs by remember { mutableStateOf<List<Track>>(emptyList()) }
    var catalog by remember { mutableStateOf(CatalogResults()) }
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize()) {
        Text("Cerca", fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(12.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier.weight(1f),
                singleLine = true,
                placeholder = { Text("Brani, artisti…") },
            )
            Spacer(Modifier.width(8.dp))
            Button(
                enabled = query.isNotBlank() && !loading,
                onClick = {
                    scope.launch {
                        loading = true
                        error = null
                        songs = emptyList()
                        catalog = CatalogResults()
                        val q = query.trim()
                        val songResult = withContext(Dispatchers.IO) { runCatching { InnerTube.searchSongs(q) } }
                        val catalogResult = withContext(Dispatchers.IO) { runCatching { InnerTube.searchCatalog(q) } }
                        loading = false
                        songResult.onSuccess { songs = it }.onFailure { error = it.message }
                        catalogResult.onSuccess { catalog = it }
                    }
                },
            ) { Text(if (loading) "…" else "Cerca") }
        }
        Spacer(Modifier.height(12.dp))
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        LazyColumn {
            catalog.top?.let { top ->
                item {
                    Text("Risultato principale", fontWeight = FontWeight.SemiBold)
                    CatalogItemRow(top) { openCatalogItem(top, onOpen) }
                    Spacer(Modifier.height(8.dp))
                }
            }
            if (songs.isNotEmpty()) {
                item { Text("Brani", fontWeight = FontWeight.SemiBold) }
                items(songs, key = { it.videoId }) { track ->
                    TrackListRow(track) { PlayerController.playRadio(track) }
                }
            }
            if (catalog.artists.isNotEmpty()) {
                item { Text("Artisti", fontWeight = FontWeight.SemiBold) }
                items(catalog.artists, key = { it.id }) { item ->
                    CatalogItemRow(item) { openCatalogItem(item, onOpen) }
                }
            }
            if (catalog.albums.isNotEmpty()) {
                item { Text("Album", fontWeight = FontWeight.SemiBold) }
                items(catalog.albums, key = { it.id }) { item ->
                    CatalogItemRow(item) { openCatalogItem(item, onOpen) }
                }
            }
            if (catalog.playlists.isNotEmpty()) {
                item { Text("Playlist", fontWeight = FontWeight.SemiBold) }
                items(catalog.playlists, key = { it.id }) { item ->
                    CatalogItemRow(item) { openCatalogItem(item, onOpen) }
                }
            }
        }
    }
}

private fun openCatalogItem(item: MusicItem, onOpen: (CatalogRoute) -> Unit) {
    when (item.kind) {
        MusicItem.Kind.ARTIST -> onOpen(CatalogRoute.Artist(item.id))
        MusicItem.Kind.ALBUM -> onOpen(CatalogRoute.Album(item.id))
        MusicItem.Kind.PLAYLIST -> onOpen(CatalogRoute.Playlist(item.id))
        MusicItem.Kind.SONG -> item.track?.let { PlayerController.playRadio(it) }
        else -> Unit
    }
}

@Composable
private fun LibraryPage() {
    val liked by Library.liked.collectAsState()
    val history by Library.history.collectAsState()
    val playlists by Library.playlists.collectAsState()
    var section by remember { mutableStateOf(0) }
    Column(Modifier.fillMaxSize()) {
        Text("La tua libreria", fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Row {
            TextButton(onClick = { section = 0 }) { Text("Preferiti") }
            TextButton(onClick = { section = 1 }) { Text("Cronologia") }
            TextButton(onClick = { section = 2 }) { Text("Playlist") }
        }
        when (section) {
            0 -> {
                if (liked.isEmpty()) Text("Nessun preferito. Tocca ♥ sul player.")
                else LazyColumn {
                    itemsIndexed(liked) { index, track ->
                        TrackListRow(track) { PlayerController.play(liked, index) }
                    }
                }
            }
            1 -> {
                Row {
                    Text("Ascoltati di recente", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    TextButton(onClick = { Library.clearHistory() }) { Text("Svuota") }
                }
                if (history.isEmpty()) Text("Ancora nessun ascolto.")
                else LazyColumn {
                    itemsIndexed(history) { index, track ->
                        TrackListRow(track) { PlayerController.play(history, index) }
                    }
                }
            }
            else -> {
                var newName by remember { mutableStateOf("") }
                var importLink by remember { mutableStateOf("") }
                var importError by remember { mutableStateOf<String?>(null) }
                val importScope = rememberCoroutineScope()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = newName,
                        onValueChange = { newName = it },
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                        placeholder = { Text("Nuova playlist") },
                    )
                    Spacer(Modifier.width(8.dp))
                    Button(enabled = newName.isNotBlank(), onClick = {
                        Library.createPlaylist(newName.trim())
                        newName = ""
                    }) { Text("Crea") }
                }
                Spacer(Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = importLink,
                        onValueChange = { importLink = it },
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                        placeholder = { Text("Link playlist YouTube Music") },
                    )
                    Spacer(Modifier.width(8.dp))
                    Button(enabled = importLink.isNotBlank(), onClick = {
                        importScope.launch {
                            importError = null
                            val id = InnerTube.playlistId(importLink) ?: importLink.trim()
                            runCatching { withContext(Dispatchers.IO) { InnerTube.playlist(id) } }
                                .onSuccess { page ->
                                    Library.createPlaylist(page.title.ifBlank { "Playlist" }, page.tracks)
                                    importLink = ""
                                }
                                .onFailure { importError = it.message }
                        }
                    }) { Text("Importa") }
                }
                importError?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp) }
                Spacer(Modifier.height(8.dp))
                if (playlists.isEmpty()) Text("Nessuna playlist. Creane una o sincronizza l’account.")
                else LazyColumn {
                    items(playlists, key = { it.id }) { playlist ->
                        Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f).clickable {
                                if (playlist.tracks.isNotEmpty()) PlayerController.play(playlist.tracks, 0)
                            }) {
                                Text(playlist.name, fontWeight = FontWeight.SemiBold)
                                Text("${playlist.tracks.size} brani", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
                            }
                            TextButton(onClick = { Library.deletePlaylist(playlist.id) }) { Text("Elimina") }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsPage() {
    val scope = rememberCoroutineScope()
    val status by AppUpdater.status.collectAsState()
    Column(Modifier.verticalScroll(rememberScrollState())) {
        Text("Impostazioni", fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(16.dp))
        Text("Aggiornamenti", fontWeight = FontWeight.SemiBold)
        Text(
            "Canale separato: solo windows-v* dal ramo windows, mai Latest. Download automatico, SHA-256, installa al riavvio.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(8.dp))
        Button(onClick = { scope.launch { AppUpdater.check(userInitiated = true) } }) {
            Text("Cerca aggiornamenti")
        }
        Text("Stato: ${status::class.simpleName} · v${BuildConfig.VERSION_NAME}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(24.dp))
        Text("Account", fontWeight = FontWeight.SemiBold)
        Text("Gestito su ${Account.manageUrl}", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
