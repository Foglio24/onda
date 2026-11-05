package com.onda.seaglass.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.InnerTube
import com.onda.seaglass.data.Prefs
import com.onda.seaglass.model.CatalogResults
import com.onda.seaglass.model.MusicItem
import com.onda.seaglass.model.Track
import com.onda.seaglass.model.nameKey
import com.onda.seaglass.playback.PlayerController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/** The search and its results, kept while moving between tabs. */
object SearchModel {
    data class Results(val songs: List<Track>, val catalog: CatalogResults, val playlists: List<MusicItem>)

    val text = MutableStateFlow("")
    val results = MutableStateFlow<Results?>(null)
    val loading = MutableStateFlow(false)
    val error = MutableStateFlow<String?>(null)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var job: Job? = null

    fun search(query: String) {
        val trimmed = query.trim()
        text.value = query
        if (trimmed.isEmpty()) return
        Prefs.addRecentSearch(trimmed)
        job?.cancel()
        loading.value = true
        error.value = null
        job = scope.launch {
            // Songs, the catalog (artists, albums) and playlists at the same time; only songs must work.
            val songs = async { runCatching { InnerTube.searchSongs(trimmed) } }
            val catalog = async { runCatching { InnerTube.searchCatalog(trimmed) }.getOrDefault(CatalogResults()) }
            val playlists = async { runCatching { InnerTube.searchPlaylists(trimmed) }.getOrDefault(emptyList()) }
            val found = songs.await()
            found.onSuccess { results.value = Results(it, catalog.await(), playlists.await()) }
                .onFailure { error.value = it.message ?: tr("Ricerca non riuscita") }
            loading.value = false
        }
    }

    fun clear() {
        job?.cancel()
        text.value = ""
        results.value = null
        loading.value = false
        error.value = null
    }
}

@Composable
fun SearchScreen() {
    val text by SearchModel.text.collectAsStateWithLifecycle()
    val results by SearchModel.results.collectAsStateWithLifecycle()
    val loading by SearchModel.loading.collectAsStateWithLifecycle()
    val error by SearchModel.error.collectAsStateWithLifecycle()
    val recent by Prefs.recentSearches.collectAsStateWithLifecycle()
    var allSongs by remember(results) { mutableStateOf(false) }
    val focus = LocalFocusManager.current
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val app = LocalApp.current

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(top = top, bottom = LocalBottomPadding.current),
    ) {
        item { ScreenTitle(tr("Cerca")) }
        item {
            SearchField(text, onChange = { SearchModel.text.value = it }, onSearch = {
                focus.clearFocus()
                SearchModel.search(text)
            }, onClear = SearchModel::clear)
        }
        val shown = results
        when {
            loading -> item { Loading() }
            error != null -> item { Message(tr("Ricerca non riuscita"), error, action = tr("Riprova")) { SearchModel.search(text) } }
            shown == null -> {
                if (recent.isEmpty()) {
                    item { Message(tr("Cerca su YouTube Music"), tr("Scegli un brano: parte una radio di canzoni simili.")) }
                } else {
                    item { SectionHeader(tr("Ricerche recenti"), action = tr("Svuota")) { Prefs.clearRecentSearches() } }
                    items(recent.distinct(), key = { "recent$it" }) { query ->
                        Row(
                            Modifier.fillMaxWidth().clickable { SearchModel.search(query) }.padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Rounded.History, null, tint = Secondary)
                            Spacer(Modifier.width(14.dp))
                            Text(query, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
            else -> {
                val catalog = shown.catalog
                // The artist the search names comes first, as YouTube's top result.
                val named = listOfNotNull(catalog.top, catalog.artists.firstOrNull())
                    .firstOrNull { it.kind == MusicItem.Kind.ARTIST && nameKey(it.title) == nameKey(text) }
                val top = named ?: catalog.top
                if (top != null) item { TopResult(top) }
                if (shown.songs.isNotEmpty()) {
                    item { SectionHeader(tr("Brani")) }
                    val songs = if (allSongs) shown.songs else shown.songs.take(5)
                    itemsIndexed(songs, key = { index, track -> "song$index" + track.videoId }) { _, track ->
                        TrackRow(track, onClick = { PlayerController.playRadio(track) })
                    }
                    if (!allSongs && shown.songs.size > 5) {
                        item {
                            TextButton(onClick = { allSongs = true }, modifier = Modifier.padding(horizontal = 8.dp)) {
                                Text(tr("Mostra tutti i brani (%lld)", shown.songs.size), color = LocalAccent.current)
                            }
                        }
                    }
                }
                val artists = catalog.artists.filter { it.id != top?.id }
                if (artists.isNotEmpty()) item { ItemShelf(tr("Artisti"), artists, cardWidth = 120.dp) }
                if (catalog.albums.isNotEmpty()) item { ItemShelf(tr("Album"), catalog.albums.filter { it.id != top?.id }) }
                val playlists = (catalog.playlists + shown.playlists).distinctBy { it.id }.filter { it.id != top?.id }
                if (playlists.isNotEmpty()) item { ItemShelf(tr("Playlist"), playlists) }
                if (shown.songs.isEmpty() && catalog.isEmpty) item { Message(tr("Nessun brano trovato.")) }
                item { Spacer(Modifier.height(8.dp)) }
            }
        }
    }
}

@Composable
private fun SearchField(text: String, onChange: (String) -> Unit, onSearch: () -> Unit, onClear: () -> Unit) {
    GlassSurface(Modifier.padding(horizontal = 16.dp, vertical = 4.dp).fillMaxWidth().height(52.dp), corner = 26.dp) {
        Row(Modifier.fillMaxSize().padding(start = 16.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Search, null, tint = Secondary)
            Spacer(Modifier.width(10.dp))
            BasicTextField(
                value = text,
                onValueChange = onChange,
                singleLine = true,
                textStyle = TextStyle(color = Color.White, fontSize = 17.sp),
                cursorBrush = SolidColor(LocalAccent.current),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { onSearch() }),
                modifier = Modifier.weight(1f),
                decorationBox = { field ->
                    if (text.isEmpty()) Text(tr("Brani, playlist e artisti"), color = Secondary, fontSize = 17.sp)
                    field()
                },
            )
            if (text.isNotEmpty()) {
                IconButton(onClick = onClear) { Icon(Icons.Rounded.Close, tr("Svuota"), tint = Secondary) }
            }
        }
    }
}

/** YouTube Music's top result, large: an artist (round), an album or a playlist. */
@Composable
private fun TopResult(item: MusicItem) {
    val app = LocalApp.current
    val round = item.kind == MusicItem.Kind.ARTIST
    Row(
        Modifier
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .fillMaxWidth()
            .clickable { item.route()?.let(app::open) ?: item.track?.let(PlayerController::playRadio) },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Artwork(
            item.artworkUrl, Modifier.size(88.dp), if (round) CircleShape else RoundedCornerShape(10.dp),
            if (round) Icons.Rounded.Person else Icons.Rounded.MusicNote,
        )
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(item.title, fontSize = 22.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (item.subtitle.isNotEmpty()) Text(item.subtitle, color = Secondary, fontSize = 14.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}
