@file:OptIn(ExperimentalComposeUiApi::class)

package com.onda.seaglass.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.AccountCircle
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.pointer.PointerIcon
import androidx.compose.ui.input.pointer.pointerHoverIcon
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.account.Account
import com.onda.seaglass.audio.Player
import com.onda.seaglass.core.Prefs
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Downloads
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.LocalMusic
import com.onda.seaglass.ui.pages.AccountPage
import com.onda.seaglass.ui.pages.AlbumPageView
import com.onda.seaglass.ui.pages.ArtistPageView
import com.onda.seaglass.ui.pages.DownloadsPage
import com.onda.seaglass.ui.pages.HistoryPage
import com.onda.seaglass.ui.pages.HomePage
import com.onda.seaglass.ui.pages.LikedPage
import com.onda.seaglass.ui.pages.LocalSongsPage
import com.onda.seaglass.ui.pages.NameDialog
import com.onda.seaglass.ui.pages.PlaylistPageView
import com.onda.seaglass.ui.pages.PlaylistsPage
import com.onda.seaglass.ui.pages.RemotePlaylistPageView
import com.onda.seaglass.ui.pages.SearchPage
import com.onda.seaglass.ui.pages.SettingsPage
import com.onda.seaglass.ui.pages.SongInfoPage
import java.awt.Cursor

/** The library's width when shrunk to its covers, and the narrowest it is otherwise. */
private val COLLAPSED = 72.dp
private val LIBRARY_MIN = 240.dp
private val LIBRARY_MAX = 460.dp
private val RIGHT_MIN = 280.dp
private val RIGHT_MAX = 520.dp
/** The page in the middle never gets narrower than this: the side panels give way first. */
private val PAGE_MIN = 420.dp

/**
 * The whole window, laid out as Spotify's: the top bar (back and forward, Home and the search in
 * the middle, the account), three rounded panels on black (the library, the page, and what's
 * playing, the queue or the lyrics), each border dragged to resize them, and the player bar; or
 * the full player over everything.
 */
@Composable
fun Shell() {
    val palette = LocalPalette.current
    Box(Modifier.fillMaxSize().background(palette.window)) {
        Column(Modifier.fillMaxSize()) {
            TopBar()
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 8.dp)) {
                val total = maxWidth
                var left by remember { mutableFloatStateOf(Prefs.leftPanelWidth.value.toFloat()) }
                var right by remember { mutableFloatStateOf(Prefs.rightPanelWidth.value.toFloat()) }
                val showRight = Nav.panel != Nav.Panel.NONE
                // What the window allows: the page keeps its minimum, the right panel shrinks first.
                val rightWidth = if (showRight) right.dp.coerceIn(RIGHT_MIN, maxOf(RIGHT_MIN, minOf(RIGHT_MAX, total - PAGE_MIN - COLLAPSED - 16.dp))) else 0.dp
                val leftWidth = if (Nav.libraryCollapsed) COLLAPSED else left.dp.coerceIn(LIBRARY_MIN, maxOf(LIBRARY_MIN, minOf(LIBRARY_MAX, total - PAGE_MIN - rightWidth - 16.dp)))
                Row(Modifier.fillMaxSize()) {
                    Panel(Modifier.width(leftWidth)) { LibraryPanel(collapsed = Nav.libraryCollapsed) }
                    Splitter(
                        onDrag = { dx ->
                            if (Nav.libraryCollapsed) {
                                if (dx > 0) {
                                    Nav.libraryCollapsed = false
                                    left = LIBRARY_MIN.value
                                }
                            } else {
                                left = (left + dx).coerceIn(COLLAPSED.value, LIBRARY_MAX.value)
                                // Dragged narrower than its least: it shrinks to its covers, as Spotify's.
                                if (left < LIBRARY_MIN.value - 60) Nav.libraryCollapsed = true
                            }
                        },
                        onDragEnd = { Prefs.leftPanelWidth.value = if (Nav.libraryCollapsed) COLLAPSED.value.toDouble() else left.coerceAtLeast(LIBRARY_MIN.value).toDouble() },
                    )
                    Panel(Modifier.weight(1f)) { MainPanel() }
                    if (showRight) {
                        Splitter(
                            onDrag = { dx -> right = (right - dx).coerceIn(RIGHT_MIN.value, RIGHT_MAX.value) },
                            onDragEnd = { Prefs.rightPanelWidth.value = right.toDouble() },
                        )
                        Panel(Modifier.width(rightWidth)) { RightPanel() }
                    }
                }
            }
            MixBanner()
            PlayerBar()
        }
        AnimatedVisibility(Nav.fullPlayer, enter = fadeIn(), exit = fadeOut()) { FullPlayer() }
        Nav.toast?.let { toast ->
            Box(Modifier.fillMaxSize().padding(bottom = 110.dp), contentAlignment = Alignment.BottomCenter) {
                Row(
                    Modifier.clip(RoundedCornerShape(8.dp)).background(Color.White).padding(start = 18.dp, end = if (toast.action != null) 8.dp else 18.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(toast.message, color = Color.Black, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(vertical = 10.dp))
                    if (toast.action != null) {
                        Text(
                            toast.action, color = Color.Black, fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(start = 16.dp).clip(RoundedCornerShape(6.dp))
                                .clickable { Nav.toast = null; toast.onAction?.invoke() }.padding(horizontal = 10.dp, vertical = 10.dp),
                        )
                    }
                }
            }
        }
        AddToPlaylistDialog()
        SaveToDialog()
        PremiumDialog()
    }
}

/** One of the three panels: dark grey, rounded, on the window's black. */
@Composable
private fun Panel(modifier: Modifier, content: @Composable () -> Unit) {
    val palette = LocalPalette.current
    Box(modifier.fillMaxHeight().clip(RoundedCornerShape(8.dp)).background(palette.page)) { content() }
}

/** The gap between two panels: dragging it moves the border (the cursor shows it can). */
@Composable
private fun Splitter(onDrag: (Float) -> Unit, onDragEnd: () -> Unit) {
    val density = LocalDensity.current
    var hovered by remember { mutableStateOf(false) }
    Box(
        Modifier.width(8.dp).fillMaxHeight()
            .pointerHoverIcon(PointerIcon(Cursor(Cursor.E_RESIZE_CURSOR)))
            .pointerInput(Unit) {
                detectHorizontalDragGestures(
                    onDragStart = { hovered = true },
                    onDragEnd = {
                        hovered = false
                        onDragEnd()
                    },
                    onDragCancel = { hovered = false },
                ) { change, amount ->
                    change.consume()
                    onDrag(with(density) { amount.toDp().value })
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        if (hovered) Box(Modifier.width(2.dp).fillMaxHeight().padding(vertical = 8.dp).background(Color(0x66FFFFFF)))
    }
}

// MARK: The top bar

@Composable
private fun TopBar() {
    val palette = LocalPalette.current
    val signedIn by Account.signedIn.collectAsState()
    Box(Modifier.fillMaxWidth().height(64.dp).padding(horizontal = 16.dp)) {
        Row(Modifier.align(Alignment.CenterStart), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Logo()
            Spacer(Modifier.width(12.dp))
            RoundButton(Icons.AutoMirrored.Rounded.ArrowBack, tr("Indietro"), enabled = Nav.canGoBack, size = 32.dp) { Nav.goBack() }
            RoundButton(Icons.AutoMirrored.Rounded.ArrowForward, tr("Avanti"), enabled = Nav.canGoForward, size = 32.dp) { Nav.goForward() }
        }
        Row(Modifier.align(Alignment.Center), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            RoundButton(Icons.Rounded.Home, tr("Home"), selected = Nav.current == Route.Home, size = 48.dp) { Nav.section(Route.Home) }
            SearchField()
        }
        Row(Modifier.align(Alignment.CenterEnd), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            RoundButton(Icons.Rounded.Settings, tr("Impostazioni"), selected = Nav.current == Route.Settings, size = 40.dp) { Nav.section(Route.Settings) }
            RoundButton(Icons.Rounded.AccountCircle, tr("Account"), selected = Nav.current == Route.Account, size = 40.dp, accent = signedIn) { Nav.section(Route.Account) }
        }
    }
}

@Composable
private fun Logo() {
    val palette = LocalPalette.current
    Box(Modifier.size(32.dp).clip(RoundedCornerShape(8.dp)).background(palette.accent), contentAlignment = Alignment.Center) {
        Icon(Icons.Rounded.LibraryMusic, "Seaglass", Modifier.size(20.dp), tint = palette.onAccent)
    }
}

/** A round button of the top bar, as Spotify's. */
@Composable
fun RoundButton(
    icon: ImageVector, label: String, enabled: Boolean = true, selected: Boolean = false, accent: Boolean = false,
    size: Dp = 40.dp, onClick: () -> Unit,
) {
    val palette = LocalPalette.current
    Hoverable { hovered ->
        Box(
            Modifier.size(size).clip(CircleShape)
                .background(if (hovered && enabled) palette.cardHover else palette.elevated)
                .clickable(enabled = enabled, onClick = onClick),
            contentAlignment = Alignment.Center,
        ) {
            val tint = when {
                !enabled -> palette.tertiary
                selected || accent -> palette.accent
                hovered -> palette.text
                else -> palette.secondary
            }
            Icon(icon, label, Modifier.size(size * 0.55f), tint = tint)
        }
    }
}

@Composable
private fun SearchField() {
    val palette = LocalPalette.current
    val route = Nav.current
    var text by remember { mutableStateOf((route as? Route.Search)?.query.orEmpty()) }
    // Leaving the search empties the field, as on Spotify; a recent search picked fills it.
    LaunchedEffect(route) {
        if (route !is Route.Search) text = "" else if (route.query != text) text = route.query
    }
    var focused by remember { mutableStateOf(false) }
    Hoverable { hovered ->
        Row(
            Modifier.widthIn(min = 280.dp, max = 480.dp).width(440.dp).height(48.dp).clip(RoundedCornerShape(50))
                .background(if (hovered) palette.cardHover else palette.elevated)
                .border(2.dp, if (focused) palette.text else Color.Transparent, RoundedCornerShape(50))
                .padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Rounded.Search, null, Modifier.size(22.dp), tint = palette.secondary)
            Spacer(Modifier.width(10.dp))
            Box(Modifier.weight(1f)) {
                if (text.isEmpty()) Text(tr("Cosa vuoi ascoltare?"), color = palette.secondary, fontSize = 15.sp, maxLines = 1)
                BasicTextField(
                    text,
                    onValueChange = { value ->
                        text = value
                        // Search as you type, as on the iPhone: the page follows the field.
                        if (Nav.current is Route.Search) Nav.replace(Route.Search(value)) else Nav.open(Route.Search(value))
                    },
                    singleLine = true,
                    textStyle = TextStyle(color = palette.text, fontSize = 15.sp),
                    cursorBrush = SolidColor(palette.accent),
                    modifier = Modifier.fillMaxWidth()
                        .onFocusChanged { focused = it.isFocused }
                        .onKeyEvent { event ->
                            if (event.key == Key.Escape) {
                                text = ""
                                true
                            } else if ((event.key == Key.Enter || event.key == Key.NumPadEnter) && event.type == KeyEventType.KeyUp) {
                                // Enter keeps the search in "Ricerche recenti", as sending it does on the iPhone.
                                com.onda.seaglass.data.RecentSearches.remember(text)
                                true
                            } else {
                                false
                            }
                        },
                )
            }
            if (text.isNotEmpty()) {
                Icon(Icons.Rounded.Close, tr("Cancella"), Modifier.size(20.dp).clickable {
                    text = ""
                    if (Nav.current is Route.Search) Nav.replace(Route.Search(""))
                }, tint = palette.secondary)
            }
        }
    }
}

// MARK: The page

@Composable
private fun MainPanel() {
    val palette = LocalPalette.current
    Box(Modifier.fillMaxSize()) {
        // The accent's glow at the top of every page, as Spotify colours its headers.
        Box(
            Modifier.fillMaxWidth().height(320.dp)
                .background(Brush.verticalGradient(listOf(palette.accent.copy(alpha = if (palette.dark) 0.28f else 0.16f), Color.Transparent))),
        )
        Box(Modifier.fillMaxSize().padding(top = 8.dp)) {
            when (val route = Nav.current) {
                Route.Home -> HomePage()
                is Route.Search -> SearchPage(route)
                Route.Liked -> LikedPage()
                Route.Playlists -> PlaylistsPage()
                is Route.Playlist -> PlaylistPageView(route.id)
                Route.Downloads -> DownloadsPage()
                Route.History -> HistoryPage()
                Route.LocalSongs -> LocalSongsPage()
                is Route.Artist -> ArtistPageView(route)
                is Route.Album -> AlbumPageView(route.id)
                is Route.RemotePlaylist -> RemotePlaylistPageView(route)
                is Route.SongInfo -> SongInfoPage(route.track)
                Route.Settings -> SettingsPage()
                Route.Account -> AccountPage()
            }
        }
    }
}

// MARK: The library

/** One entry of "La tua libreria": its cover (or a coloured tile), its name and what it is. */
private data class LibraryEntry(
    val key: String,
    val title: String,
    val subtitle: String,
    val route: Route,
    val artwork: String? = null,
    val icon: ImageVector? = null,
    val tile: Brush? = null,
)

@Composable
private fun LibraryPanel(collapsed: Boolean) {
    val palette = LocalPalette.current
    val playlists by Library.playlists.collectAsState()
    val liked by Library.liked.collectAsState()
    val history by Library.history.collectAsState()
    val downloads by Downloads.items.collectAsState()
    val local by LocalMusic.songs.collectAsState()
    val state by Player.state.collectAsState()
    var creating by remember { mutableStateOf(false) }
    var importing by remember { mutableStateOf(false) }
    var importingSpotify by remember { mutableStateOf(false) }
    val entries = buildList {
        add(LibraryEntry("liked", tr("Brani preferiti"), tr("Playlist · %lld brani", liked.size), Route.Liked, icon = Icons.Rounded.Favorite,
            tile = Brush.linearGradient(listOf(Color(0xFF450AF5), Color(0xFFC4EFD9)))))
        add(LibraryEntry("downloads", tr("Scaricati"), tr("%lld brani", downloads.size), Route.Downloads, icon = Icons.Rounded.Download,
            tile = Brush.linearGradient(listOf(Color(0xFF0D7A4E), Color(0xFF2BD47F)))))
        add(LibraryEntry("history", tr("Cronologia"), tr("%lld brani", history.size), Route.History, icon = Icons.Rounded.History,
            tile = Brush.linearGradient(listOf(Color(0xFF7A3B0D), Color(0xFFE8A04B)))))
        if (local.isNotEmpty() || LocalMusic.folders.isNotEmpty()) {
            add(LibraryEntry("local", tr("I tuoi brani"), tr("%lld brani", local.size), Route.LocalSongs, icon = Icons.Rounded.Folder,
                tile = Brush.linearGradient(listOf(Color(0xFF3A3A44), Color(0xFF6B6B78)))))
        }
        playlists.forEach { playlist ->
            add(LibraryEntry("playlist:${playlist.id}", playlist.name, tr("Playlist · %lld brani", playlist.tracks.size), Route.Playlist(playlist.id),
                artwork = playlist.tracks.firstOrNull()?.resized(120), icon = Icons.AutoMirrored.Rounded.QueueMusic))
        }
    }
    Column(Modifier.fillMaxSize().padding(top = 12.dp)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = if (collapsed) 0.dp else 16.dp).height(40.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = if (collapsed) Arrangement.Center else Arrangement.Start) {
            Hoverable(if (collapsed) Modifier else Modifier.weight(1f)) { hovered ->
                Row(
                    Modifier.clip(RoundedCornerShape(6.dp)).clickable {
                        Nav.libraryCollapsed = !collapsed
                        Prefs.leftPanelWidth.value = if (Nav.libraryCollapsed) COLLAPSED.value.toDouble() else maxOf(LIBRARY_MIN.value.toDouble(), Prefs.leftPanelWidth.value)
                    }.padding(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Rounded.LibraryMusic, tr(if (collapsed) "Espandi la libreria" else "Riduci la libreria"), Modifier.size(24.dp), tint = if (hovered) palette.text else palette.secondary)
                    if (!collapsed) {
                        Spacer(Modifier.width(10.dp))
                        Text(tr("La tua libreria"), color = if (hovered) palette.text else palette.secondary, fontWeight = FontWeight.Bold, fontSize = 15.sp,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            if (!collapsed) {
                // "+": a new playlist, or one brought in from Spotify, Apple Music or YouTube.
                var menu by remember { mutableStateOf(false) }
                Box {
                    RoundButton(Icons.Rounded.Add, tr("Nuova playlist"), size = 32.dp) { menu = true }
                    androidx.compose.material3.DropdownMenu(menu, { menu = false }) {
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text(tr("Nuova playlist")) }, leadingIcon = { Icon(Icons.Rounded.Add, null) },
                            onClick = {
                                menu = false
                                creating = true
                            },
                        )
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text(tr("Importa da Spotify, Apple Music o YouTube")) },
                            leadingIcon = { Icon(Icons.AutoMirrored.Rounded.QueueMusic, null) },
                            onClick = {
                                menu = false
                                // A Premium feature, as on the iPhone.
                                if (Account.unlocks()) importing = true else Nav.premium = tr("Importa playlist da link")
                            },
                        )
                    }
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        LazyColumn(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 8.dp)) {
            items(entries, key = { it.key }) { entry ->
                val selected = Nav.current == entry.route
                val playing = state.isPlaying && state.source != null && state.source == entry.title
                LibraryRow(entry, collapsed, selected, playing)
            }
        }
    }
    if (creating) NameDialog(tr("Nuova playlist"), "", tr("Crea"), onDismiss = { creating = false }) { name ->
        val created = Library.createPlaylist(name)
        creating = false
        Nav.section(Route.Playlist(created.id))
    }
    if (importing) com.onda.seaglass.ui.pages.ImportPlaylistDialog(onSpotifyAccount = { importing = false; importingSpotify = true }) { importing = false }
    if (importingSpotify) com.onda.seaglass.ui.pages.SpotifyImportDialog { importingSpotify = false }
}

@Composable
private fun LibraryRow(entry: LibraryEntry, collapsed: Boolean, selected: Boolean, playing: Boolean) {
    val palette = LocalPalette.current
    Hoverable { hovered ->
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp))
                .background(if (selected) palette.cardHover else if (hovered) palette.card else Color.Transparent)
                .clickable { Nav.section(entry.route) }
                .padding(8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = if (collapsed) Arrangement.Center else Arrangement.Start,
        ) {
            Box(Modifier.size(48.dp).clip(RoundedCornerShape(4.dp)), contentAlignment = Alignment.Center) {
                when {
                    entry.artwork != null -> RemoteImage(entry.artwork, Modifier.fillMaxSize())
                    entry.tile != null -> Box(Modifier.fillMaxSize().background(entry.tile), contentAlignment = Alignment.Center) {
                        Icon(entry.icon ?: Icons.Rounded.LibraryMusic, null, Modifier.size(22.dp), tint = Color.White)
                    }
                    else -> Box(Modifier.fillMaxSize().background(palette.cardHover), contentAlignment = Alignment.Center) {
                        Icon(entry.icon ?: Icons.Rounded.LibraryMusic, null, Modifier.size(22.dp), tint = palette.secondary)
                    }
                }
            }
            if (!collapsed) {
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(entry.title, color = if (playing) palette.accent else palette.text, fontSize = 15.sp, fontWeight = FontWeight.Medium,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(entry.subtitle, color = palette.secondary, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (playing) Icon(Icons.AutoMirrored.Rounded.VolumeUp, null, Modifier.size(16.dp), tint = palette.accent)
            }
        }
    }
}

// MARK: The right panel

@Composable
private fun RightPanel() {
    val palette = LocalPalette.current
    val state by Player.state.collectAsState()
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().height(56.dp).padding(start = 16.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            val title = when (Nav.panel) {
                Nav.Panel.QUEUE -> tr("Coda")
                Nav.Panel.LYRICS -> tr("Testo")
                else -> state.source?.takeIf { it.isNotBlank() } ?: tr("In riproduzione")
            }
            Text(title, color = palette.text, fontWeight = FontWeight.Bold, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            RoundButton(Icons.Rounded.Close, tr("Chiudi"), size = 32.dp) { Nav.panel = Nav.Panel.NONE }
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (Nav.panel) {
                Nav.Panel.QUEUE -> QueuePanel()
                Nav.Panel.LYRICS -> LyricsPanel(compact = true)
                else -> NowPlayingPanel()
            }
        }
    }
}
