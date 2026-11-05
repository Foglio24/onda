package com.onda.seaglass.ui

import android.content.Intent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.InnerTube
import com.onda.seaglass.model.Track
import com.onda.seaglass.playback.PlaybackEvents
import com.onda.seaglass.playback.PlayerController
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private data class MenuRequest(val track: Track, val playlistId: String?, val playlistIndex: Int?)
private data class Toast(val text: String, val id: Long = System.nanoTime())

private data class Tab(val route: String, val title: String, val icon: ImageVector)

@Composable
fun AppRoot(launch: State<Launch?>) {
    SeaglassTheme {
        val nav = rememberNavController()
        val hazeState = rememberHazeState()
        val context = LocalContext.current
        val scope = rememberCoroutineScope()
        var playerOpen by rememberSaveable { mutableStateOf(false) }
        var lyricsFirst by remember { mutableStateOf(false) }
        var tab by rememberSaveable { mutableStateOf("home") }
        var menu by remember { mutableStateOf<MenuRequest?>(null) }
        var picker by remember { mutableStateOf<Track?>(null) }
        var toast by remember { mutableStateOf<Toast?>(null) }
        val state by PlayerController.state.collectAsStateWithLifecycle()
        val error by PlaybackEvents.error.collectAsStateWithLifecycle()

        val actions = remember(nav) {
            object : AppActions {
                override fun open(route: String) {
                    playerOpen = false
                    nav.navigate(route)
                }
                override fun back() {
                    nav.popBackStack()
                }
                override fun openPlayer() {
                    playerOpen = true
                }
                override fun showMenu(track: Track, playlistId: String?, playlistIndex: Int?) {
                    menu = MenuRequest(track, playlistId, playlistIndex)
                }
                override fun toast(text: String) {
                    toast = Toast(text)
                }
                override fun addToPlaylist(track: Track) {
                    picker = track
                }
            }
        }

        LaunchedEffect(error) { error?.let { actions.toast(it) } }
        LaunchedEffect(toast?.id) {
            if (toast != null) {
                delay(2_200)
                toast = null
            }
        }
        LaunchedEffect(launch.value?.id) {
            val request = launch.value ?: return@LaunchedEffect
            handleLaunch(request, nav, actions, onTab = { tab = it }, onLyrics = { lyricsFirst = it })
        }

        val navBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
        val hasPlayer = state.current != null
        val bottomPadding = navBottom + 8.dp + 64.dp + (if (hasPlayer) 72.dp else 0.dp) + 16.dp

        CompositionLocalProvider(
            LocalApp provides actions,
            LocalHazeState provides hazeState,
            LocalBottomPadding provides bottomPadding,
        ) {
            Box(Modifier.fillMaxSize().background(Background)) {
                // Two layers for the glass: the background, and the pages over it. The bars refract
                // both; glass inside a page (the search field, buttons) refracts the background.
                AmbientBackground(Modifier.hazeSource(hazeState, zIndex = -1f))
                Box(Modifier.fillMaxSize().hazeSource(hazeState, zIndex = 0f)) {
                    NavHost(
                        navController = nav,
                        startDestination = "home",
                        enterTransition = { fadeIn(tween(220)) },
                        exitTransition = { fadeOut(tween(160)) },
                        popEnterTransition = { fadeIn(tween(220)) },
                        popExitTransition = { fadeOut(tween(160)) },
                    ) {
                        composable("home") { HomeScreen() }
                        composable("search") { SearchScreen() }
                        composable("library") { LibraryScreen() }
                        composable("settings") { SettingsScreen() }
                        composable("liked") { LikedScreen() }
                        composable("history") { HistoryScreen() }
                        composable("local/{id}", listOf(navArgument("id") { type = NavType.StringType })) {
                            LocalPlaylistScreen(it.arguments?.getString("id").orEmpty())
                        }
                        composable("artist/{id}", listOf(navArgument("id") { type = NavType.StringType })) {
                            ArtistScreen(it.arguments?.getString("id").orEmpty())
                        }
                        composable("album/{id}", listOf(navArgument("id") { type = NavType.StringType })) {
                            AlbumScreen(it.arguments?.getString("id").orEmpty())
                        }
                        composable("playlist/{id}", listOf(navArgument("id") { type = NavType.StringType })) {
                            PlaylistScreen(it.arguments?.getString("id").orEmpty())
                        }
                    }
                }

                Column(
                    Modifier
                        .align(Alignment.BottomCenter)
                        .widthIn(max = 640.dp)
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp)
                        .padding(bottom = navBottom + 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    AnimatedVisibility(hasPlayer, enter = fadeIn() + slideInVertically { it / 2 }, exit = fadeOut()) {
                        MiniPlayer(onOpen = { lyricsFirst = false; playerOpen = true })
                    }
                    TabBar(tab) { route ->
                        if (route == tab) {
                            nav.popBackStack(route, inclusive = false)
                        } else {
                            tab = route
                            nav.navigate(route) {
                                popUpTo(nav.graph.findStartDestination().id) { saveState = true }
                                launchSingleTop = true
                                restoreState = true
                            }
                        }
                    }
                }

                AnimatedVisibility(
                    toast != null,
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = bottomPadding),
                    enter = fadeIn() + slideInVertically { it },
                    exit = fadeOut(),
                ) {
                    GlassSurface(corner = 22.dp, tint = Color.Black.copy(alpha = 0.25f)) {
                        Text(
                            toast?.text.orEmpty(), color = Color.White, fontSize = 14.sp,
                            modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
                        )
                    }
                }

                AnimatedVisibility(
                    playerOpen && hasPlayer,
                    enter = slideInVertically(tween(320)) { it },
                    exit = slideOutVertically(tween(260)) { it },
                ) {
                    NowPlayingScreen(startWithLyrics = lyricsFirst, onClose = { playerOpen = false })
                }

                menu?.let { request ->
                    TrackMenu(
                        track = request.track,
                        playlistId = request.playlistId,
                        playlistIndex = request.playlistIndex,
                        onDismiss = { menu = null },
                        onShare = { track ->
                            val send = Intent(Intent.ACTION_SEND).setType("text/plain")
                                .putExtra(Intent.EXTRA_TEXT, "${track.title} – ${track.artist}\n${track.shareUrl}")
                            context.startActivity(Intent.createChooser(send, tr("Condividi")))
                        },
                        onArtist = { track ->
                            scope.launch {
                                val id = track.artistId ?: runCatching { InnerTube.artistId(track.primaryArtist) }.getOrNull()
                                if (id != null) actions.open("artist/$id") else actions.toast(tr("Artista non disponibile"))
                            }
                        },
                    )
                }
                picker?.let { track -> PlaylistPicker(track, onDismiss = { picker = null }) }
            }
        }
    }
}

private suspend fun handleLaunch(
    request: Launch,
    nav: NavHostController,
    app: AppActions,
    onTab: (String) -> Unit,
    onLyrics: (Boolean) -> Unit,
) {
    request.route?.let { app.open(it) }
    request.videoId?.takeIf { request.scene == null }?.let { videoId ->
        runCatching { InnerTube.radio(videoId) }.getOrNull()?.takeIf { it.isNotEmpty() }?.let { radio ->
            PlayerController.play(radio)
            app.openPlayer()
        }
        return
    }
    if (request.openPlayer) app.openPlayer()
    val scene = request.scene ?: return
    // Screens for the screenshots in CI.
    fun tab(route: String) {
        onTab(route)
        nav.navigate(route) { launchSingleTop = true }
    }
    when (scene) {
        "search" -> {
            tab("search")
            request.query?.let(SearchModel::search)
        }
        "library", "settings" -> tab(scene)
        "player", "lyrics", "queue" -> {
            val query = request.query ?: "Daft Punk Get Lucky"
            val song = runCatching { InnerTube.searchSongs(query).firstOrNull() }.getOrNull() ?: return
            PlayerController.playRadio(song)
            onLyrics(scene == "lyrics")
            delay(1_500)
            app.openPlayer()
        }
        "artist", "album" -> {
            val results = runCatching { InnerTube.searchCatalog(request.query ?: "Daft Punk") }.getOrNull() ?: return
            val item = if (scene == "artist") {
                results.top?.takeIf { it.kind == com.onda.seaglass.model.MusicItem.Kind.ARTIST } ?: results.artists.firstOrNull()
            } else {
                results.albums.firstOrNull()
            }
            item?.route()?.let(app::open)
        }
    }
}

@Composable
private fun TabBar(selected: String, onSelect: (String) -> Unit) {
    val tabs = listOf(
        Tab("home", tr("Home"), Icons.Rounded.Home),
        Tab("search", tr("Cerca"), Icons.Rounded.Search),
        Tab("library", tr("Libreria"), Icons.Rounded.LibraryMusic),
        Tab("settings", tr("Impostazioni"), Icons.Rounded.Settings),
    )
    val accent = LocalAccent.current
    GlassSurface(Modifier.fillMaxWidth().height(64.dp), corner = 32.dp) {
        Row(Modifier.fillMaxSize().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
            for (item in tabs) {
                val isSelected = item.route == selected
                Column(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .clip(RoundedCornerShape(28.dp))
                        .background(if (isSelected) Color.White.copy(alpha = 0.12f) else Color.Transparent)
                        .clickable { onSelect(item.route) },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(item.icon, null, tint = if (isSelected) accent else Color.White.copy(alpha = 0.85f), modifier = Modifier.size(24.dp))
                    Text(
                        item.title, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        color = if (isSelected) accent else Color.White.copy(alpha = 0.85f),
                        fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                    )
                }
            }
        }
    }
}

@Composable
private fun MiniPlayer(onOpen: () -> Unit) {
    val state by PlayerController.state.collectAsStateWithLifecycle()
    val track = state.current ?: return
    var progress by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(state.isPlaying, track.videoId, state.durationMs) {
        while (true) {
            progress = if (state.durationMs > 0) (PlayerController.positionMs.toFloat() / state.durationMs).coerceIn(0f, 1f) else 0f
            if (!state.isPlaying) break
            delay(500)
        }
    }
    val accent = LocalAccent.current
    GlassSurface(Modifier.fillMaxWidth().height(64.dp).clickable(onClick = onOpen), corner = 22.dp) {
        Row(Modifier.fillMaxSize().padding(start = 10.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Artwork(track.mediumArtwork, Modifier.size(44.dp), RoundedCornerShape(8.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(track.title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                Text(track.artist, maxLines = 1, overflow = TextOverflow.Ellipsis, color = Secondary, fontSize = 13.sp)
            }
            IconButton(onClick = PlayerController::toggle) {
                Icon(if (state.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, tr("Riproduci o metti in pausa"), modifier = Modifier.size(30.dp))
            }
            IconButton(onClick = PlayerController::next) {
                Icon(Icons.Rounded.SkipNext, tr("Brano successivo"), modifier = Modifier.size(28.dp))
            }
        }
        Box(
            Modifier
                .align(Alignment.BottomStart)
                .padding(horizontal = 18.dp)
                .fillMaxWidth()
                .height(2.dp)
                .clip(RoundedCornerShape(1.dp))
                .background(Color.White.copy(alpha = 0.12f)),
        ) {
            Box(Modifier.fillMaxWidth(progress).fillMaxHeight().background(accent))
        }
    }
}
