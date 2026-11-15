package com.onda.seaglass.ui.pages

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
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
import com.onda.seaglass.audio.Player
import com.onda.seaglass.core.Prefs
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Downloads
import com.onda.seaglass.data.InnerTube
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.Recommendations
import com.onda.seaglass.data.SongDetails
import com.onda.seaglass.model.AlbumPage
import com.onda.seaglass.model.ArtistPage
import com.onda.seaglass.model.CatalogResults
import com.onda.seaglass.model.MusicItem
import com.onda.seaglass.model.PlaylistPage
import com.onda.seaglass.model.Track
import com.onda.seaglass.model.formatDuration
import com.onda.seaglass.ui.EmptyState
import com.onda.seaglass.ui.ItemCard
import com.onda.seaglass.ui.LocalPalette
import com.onda.seaglass.ui.forWhiteText
import com.onda.seaglass.ui.Nav
import com.onda.seaglass.ui.PageHeader
import com.onda.seaglass.ui.PillButton
import com.onda.seaglass.ui.PlayShuffleButtons
import com.onda.seaglass.ui.RemoteImage
import com.onda.seaglass.ui.Route
import com.onda.seaglass.ui.SectionHeader
import com.onda.seaglass.ui.Shelf
import com.onda.seaglass.ui.TrackCard
import com.onda.seaglass.ui.TrackList
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.LocalTime

/** A page's scrolling column, with the window's margins. */
@Composable
fun Page(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp).padding(top = 16.dp, bottom = 32.dp), content = content)
}

/** What a page shows while it loads, or when it couldn't. */
sealed interface Load<out T> {
    data object Loading : Load<Nothing>
    data class Done<T>(val value: T) : Load<T>
    data class Failed(val message: String) : Load<Nothing>
}

@Composable
fun <T> load(key: Any?, block: suspend () -> T): Load<T> = produceState<Load<T>>(Load.Loading, key) {
    value = Load.Loading
    value = runCatching { block() }.fold({ Load.Done(it) }, { Load.Failed(it.message ?: tr("Errore di rete")) })
}.value

@Composable
fun <T> Loaded(state: Load<T>, content: @Composable (T) -> Unit) {
    when (state) {
        Load.Loading -> Box(Modifier.fillMaxWidth().padding(top = 120.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = LocalPalette.current.accent)
        }
        is Load.Failed -> EmptyState(Icons.Rounded.CloudOff, tr("Impossibile caricare"), state.message)
        is Load.Done -> content(state.value)
    }
}

// MARK: Home

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun HomePage() {
    val palette = LocalPalette.current
    val history by Library.history.collectAsState()
    var refresh by remember { mutableStateOf(0) }
    val picks = load(refresh) { Recommendations.quickPicks(refresh > 0) }
    val scope = rememberCoroutineScope()
    Page {
        val greeting = when (LocalTime.now().hour) {
            in 5..12 -> tr("Buongiorno")
            in 13..17 -> tr("Buon pomeriggio")
            else -> tr("Buonasera")
        }
        Text(greeting, fontSize = 34.sp, fontWeight = FontWeight.Bold, color = palette.text, modifier = Modifier.padding(bottom = 6.dp))
        if (history.isNotEmpty()) {
            SectionHeader(tr("Riprendi da dove eri"))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                history.take(6).forEachIndexed { index, track ->
                    Row(
                        Modifier.width(300.dp).height(60.dp).clip(RoundedCornerShape(8.dp)).background(palette.card)
                            .clickable { Player.play(history, index, tr("Cronologia")) },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RemoteImage(track.resized(120), Modifier.size(60.dp))
                        Text(track.title, color = palette.text, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 12.dp))
                    }
                }
            }
        }
        SectionHeader(tr("Scelti per te"), tr("Aggiorna")) { refresh++ }
        when (picks) {
            is Load.Done -> Shelf { picks.value.forEachIndexed { index, track -> TrackCard(track) { Player.play(picks.value, index, tr("Scelti per te")) } } }
            Load.Loading -> Box(Modifier.height(220.dp).fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = palette.accent) }
            is Load.Failed -> Text(picks.message, color = palette.secondary)
        }
        SectionHeader(tr("Mood"))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Recommendations.moods.forEach { mood ->
                Box(
                    Modifier.width(180.dp).height(84.dp).clip(RoundedCornerShape(8.dp)).background(Color(mood.tint).forWhiteText())
                        .clickable {
                            scope.launch {
                                runCatching { Recommendations.moodTracks(mood) }
                                    .onSuccess { Player.play(it, 0, mood.title) }
                                    .onFailure { Nav.toast(it.message ?: tr("Ricerca non riuscita")) }
                            }
                        }.padding(14.dp),
                    contentAlignment = Alignment.BottomStart,
                ) { Text(mood.title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp) }
            }
        }
        if (history.size > 6) {
            SectionHeader(tr("Ascoltati di recente"), tr("Mostra tutto")) { Nav.section(Route.History) }
            Shelf { history.take(20).forEachIndexed { index, track -> TrackCard(track) { Player.play(history, index, tr("Cronologia")) } } }
        }
    }
}

// MARK: Search

@Composable
fun SearchPage(route: Route.Search) {
    val palette = LocalPalette.current
    val query = route.query.trim()
    if (query.isEmpty()) {
        Page {
            Text(tr("Cerca"), fontSize = 34.sp, fontWeight = FontWeight.Bold, color = palette.text)
            EmptyState(Icons.Rounded.Search, tr("Cerca brani, artisti, album e playlist"), tr("Scrivi nel campo in alto a sinistra."))
        }
        return
    }
    // As you type: the search starts once the typing pauses.
    val results = load(query) {
        delay(300)
        val songs = InnerTube.searchSongs(query)
        val catalog = runCatching { InnerTube.searchCatalog(query) }.getOrDefault(CatalogResults())
        val playlists = runCatching { InnerTube.searchPlaylists(query) }.getOrDefault(emptyList())
        Triple(Recommendations.withoutLongMixes(songs), catalog, playlists)
    }
    Page {
        Text(tr("Risultati per “%@”", query), fontSize = 26.sp, fontWeight = FontWeight.Bold, color = palette.text)
        Loaded(results) { (songs, catalog, playlists) ->
            if (songs.isEmpty() && catalog.isEmpty && playlists.isEmpty()) {
                EmptyState(Icons.Rounded.Search, tr("Nessun risultato"))
                return@Loaded
            }
            catalog.top?.let { top ->
                SectionHeader(tr("Risultato principale"))
                ItemCard(top, size = 200.dp) {
                    if (top.kind == MusicItem.Kind.SONG && top.track != null) Player.play(listOf(top.track!!)) else Nav.open(top)
                }
            }
            if (songs.isNotEmpty()) {
                SectionHeader(tr("Brani"))
                TrackList(songs.take(8), query)
            }
            if (catalog.artists.isNotEmpty()) {
                SectionHeader(tr("Artisti"))
                Shelf { catalog.artists.forEach { ItemCard(it, 150.dp) { Nav.open(it) } } }
            }
            if (catalog.albums.isNotEmpty()) {
                SectionHeader(tr("Album"))
                Shelf { catalog.albums.forEach { ItemCard(it) { Nav.open(it) } } }
            }
            val allPlaylists = (catalog.playlists + playlists).distinctBy { it.id }
            if (allPlaylists.isNotEmpty()) {
                SectionHeader(tr("Playlist"))
                Shelf { allPlaylists.forEach { ItemCard(it) { Nav.open(it) } } }
            }
        }
    }
}

// MARK: Artist, album, playlist

@Composable
fun ArtistPageView(route: Route.Artist) {
    val palette = LocalPalette.current
    val page = load(route) {
        val id = route.id
        if (id != null) {
            runCatching { InnerTube.artist(id) }.getOrNull()?.let { return@load it }
        }
        val found = InnerTube.artistId(route.name) ?: throw java.io.IOException(tr("Artista non disponibile"))
        InnerTube.artist(found)
    }
    Page {
        Loaded(page) { artist: ArtistPage ->
            PageHeader(artist.name, null, null, artist.artworkUrl, round = true) {
                if (artist.topSongs.isNotEmpty()) PlayShuffleButtons(artist.topSongs, artist.name)
                artist.topSongs.firstOrNull()?.let { first -> PillButton(tr("Radio dell'artista"), Icons.Rounded.Radio) { Player.play(listOf(first), 0, artist.name) } }
            }
            if (artist.topSongs.isNotEmpty()) {
                SectionHeader(tr("Brani più ascoltati"), artist.songsPlaylistId?.let { tr("Tutti i brani") }) {
                    artist.songsPlaylistId?.let { Nav.open(Route.RemotePlaylist(it, tr("%@: tutti i brani", artist.name))) }
                }
                TrackList(artist.topSongs, artist.name)
            }
            artist.shelves.forEach { shelf ->
                SectionHeader(shelf.title)
                Shelf {
                    shelf.items.forEach { item ->
                        if (item.kind == MusicItem.Kind.SONG && item.track != null) TrackCard(item.track!!) { Player.play(listOf(item.track!!)) }
                        else ItemCard(item) { Nav.open(item) }
                    }
                }
            }
            artist.about?.takeIf { it.isNotBlank() }?.let { about ->
                SectionHeader(tr("Informazioni"))
                Text(about, color = palette.secondary, fontSize = 14.sp, lineHeight = 21.sp, maxLines = 12, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
fun AlbumPageView(id: String) {
    val page = load(id) { InnerTube.album(id) }
    Page {
        Loaded(page) { album: AlbumPage ->
            PageHeader(album.title, album.artist, listOf(album.kindAndYear, album.details).filter { it.isNotBlank() }.joinToString(" · "), album.artworkUrl) {
                PlayShuffleButtons(album.tracks, album.title)
                PillButton(tr("Scarica"), Icons.Rounded.Download) { Downloads.download(album.tracks) }
            }
            TrackList(album.tracks, album.title, numbered = true, showArtwork = false)
        }
    }
}

@Composable
fun RemotePlaylistPageView(route: Route.RemotePlaylist) {
    val page = load(route.id) { InnerTube.playlist(route.id) }
    Page {
        Loaded(page) { playlist: PlaylistPage ->
            PageHeader(playlist.title.ifBlank { route.title }, null, playlist.subtitle, playlist.artworkUrl ?: playlist.tracks.firstOrNull()?.largeArtwork) {
                PlayShuffleButtons(playlist.tracks, playlist.title)
                PillButton(tr("Salva nella libreria")) {
                    Library.createPlaylist(playlist.title.ifBlank { route.title }, playlist.tracks)
                    Nav.toast(tr("Playlist salvata"))
                }
                PillButton(tr("Scarica"), Icons.Rounded.Download) { Downloads.download(playlist.tracks) }
            }
            TrackList(playlist.tracks, playlist.title)
        }
    }
}

/** "Informazioni sul brano": the release, the label and the credits, as YouTube Music has them. */
@Composable
fun SongInfoPage(track: Track) {
    val palette = LocalPalette.current
    val details = load(track.videoId) { SongDetails.load(track.videoId) }
    Page {
        PageHeader(track.title, track.artist, track.album, track.largeArtwork) {
            PillButton(tr("Riproduci")) { Player.play(listOf(track)) }
        }
        Loaded(details) { info ->
            @Composable
            fun row(label: String, value: String?) {
                if (value.isNullOrBlank()) return
                Row(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                    Text(label, color = palette.secondary, fontSize = 14.sp, modifier = Modifier.width(220.dp))
                    Text(value, color = palette.text, fontSize = 14.sp)
                }
            }
            SectionHeader(tr("Brano"))
            row(tr("Uscita"), info.releaseDate)
            row(tr("Durata"), track.duration?.let { formatDuration(it) })
            row(tr("Riproduzioni su YouTube"), info.views?.let { "%,d".format(it) })
            row(tr("Distribuito da"), info.label)
            info.copyright?.let { Text(it, color = palette.secondary, fontSize = 13.sp, modifier = Modifier.padding(vertical = 6.dp)) }
            if (info.credits.isNotEmpty()) {
                SectionHeader(tr("Crediti"))
                info.credits.forEach { (role, names) -> row(role, names.joinToString(", ")) }
            }
            info.description?.let {
                SectionHeader(tr("Descrizione"))
                Text(it, color = palette.secondary, fontSize = 13.sp, maxLines = 14, overflow = TextOverflow.Ellipsis)
            }
        }
        Spacer(Modifier.height(20.dp))
        Text(tr("Volume uniforme") + ": " + if (Prefs.normalizeVolume.value) tr("Attivo") else tr("Disattivato"), color = palette.tertiary, fontSize = 12.sp)
    }
}
