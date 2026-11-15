@file:OptIn(ExperimentalComposeUiApi::class)

package com.onda.seaglass.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Library
import com.onda.seaglass.ui.pages.AlbumPageView
import com.onda.seaglass.ui.pages.ArtistPageView
import com.onda.seaglass.ui.pages.DownloadsPage
import com.onda.seaglass.ui.pages.EqualizerPage
import com.onda.seaglass.ui.pages.HistoryPage
import com.onda.seaglass.ui.pages.HomePage
import com.onda.seaglass.ui.pages.LikedPage
import com.onda.seaglass.ui.pages.LocalSongsPage
import com.onda.seaglass.ui.pages.PlaylistPageView
import com.onda.seaglass.ui.pages.PlaylistsPage
import com.onda.seaglass.ui.pages.RemotePlaylistPageView
import com.onda.seaglass.ui.pages.SearchPage
import com.onda.seaglass.ui.pages.SettingsPage
import com.onda.seaglass.ui.pages.SongInfoPage
import com.onda.seaglass.ui.pages.AccountPage

/** The whole window: sidebar, page, right panel and player bar; or the full player over them. */
@Composable
fun Shell() {
    val palette = LocalPalette.current
    Box(Modifier.fillMaxSize().background(palette.window)) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.weight(1f).fillMaxWidth()) {
                Sidebar()
                Box(Modifier.weight(1f).fillMaxHeight().background(palette.page)) { PageArea() }
                if (Nav.panel != Nav.Panel.NONE) {
                    Box(Modifier.width(340.dp).fillMaxHeight().background(palette.sidebar)) {
                        if (Nav.panel == Nav.Panel.QUEUE) QueuePanel() else LyricsPanel(compact = true)
                    }
                }
            }
            PlayerBar()
        }
        AnimatedVisibility(Nav.fullPlayer, enter = fadeIn(), exit = fadeOut()) { FullPlayer() }
        Nav.toast?.let { message ->
            Box(Modifier.fillMaxSize().padding(bottom = 110.dp), contentAlignment = Alignment.BottomCenter) {
                Text(
                    message,
                    color = Color.White,
                    modifier = Modifier.clip(RoundedCornerShape(50)).background(Color(0xE6222228)).padding(horizontal = 18.dp, vertical = 10.dp),
                )
            }
        }
        AddToPlaylistDialog()
        PremiumDialog()
    }
}

@Composable
private fun PageArea() {
    val palette = LocalPalette.current
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = Nav::goBack, enabled = Nav.canGoBack) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, tr("Indietro"), tint = if (Nav.canGoBack) palette.text else palette.tertiary)
            }
            IconButton(onClick = Nav::goForward, enabled = Nav.canGoForward) {
                Icon(Icons.AutoMirrored.Rounded.ArrowForward, tr("Avanti"), tint = if (Nav.canGoForward) palette.text else palette.tertiary)
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
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
                Route.Equalizer -> EqualizerPage()
                Route.Account -> AccountPage()
            }
        }
    }
}

@Composable
private fun Sidebar() {
    val palette = LocalPalette.current
    val playlists by Library.playlists.collectAsState()
    Column(Modifier.width(240.dp).fillMaxHeight().background(palette.sidebar).padding(horizontal = 12.dp)) {
        Row(Modifier.padding(start = 8.dp, top = 18.dp, bottom = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(26.dp).clip(RoundedCornerShape(7.dp)).background(palette.accent), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.LibraryMusic, null, Modifier.size(16.dp), tint = Color.White)
            }
            Spacer(Modifier.width(10.dp))
            Text("Seaglass", color = palette.text, fontWeight = FontWeight.Bold, fontSize = 18.sp)
        }
        SearchField()
        Spacer(Modifier.height(10.dp))
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            SidebarItem(tr("Home"), Icons.Rounded.Home, Nav.current == Route.Home) { Nav.section(Route.Home) }
            SidebarItem(tr("Cerca"), Icons.Rounded.Search, Nav.current is Route.Search) { Nav.section(Route.Search()) }
            SidebarHeading(tr("Libreria"))
            SidebarItem(tr("Brani preferiti"), Icons.Rounded.Favorite, Nav.current == Route.Liked) { Nav.section(Route.Liked) }
            SidebarItem(tr("Playlist"), Icons.AutoMirrored.Rounded.QueueMusic, Nav.current == Route.Playlists) { Nav.section(Route.Playlists) }
            SidebarItem(tr("Scaricati"), Icons.Rounded.Download, Nav.current == Route.Downloads) { Nav.section(Route.Downloads) }
            SidebarItem(tr("Cronologia"), Icons.Rounded.History, Nav.current == Route.History) { Nav.section(Route.History) }
            SidebarItem(tr("I tuoi brani"), Icons.Rounded.Folder, Nav.current == Route.LocalSongs) { Nav.section(Route.LocalSongs) }
            if (playlists.isNotEmpty()) {
                SidebarHeading(tr("Playlist"))
                playlists.forEach { playlist ->
                    val selected = (Nav.current as? Route.Playlist)?.id == playlist.id
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(7.dp))
                            .background(if (selected) palette.cardHover else Color.Transparent)
                            .clickable { Nav.section(Route.Playlist(playlist.id)) }
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RemoteImage(playlist.tracks.firstOrNull()?.resized(120), Modifier.size(26.dp), RoundedCornerShape(4.dp))
                        Spacer(Modifier.width(10.dp))
                        Text(playlist.name, color = palette.text, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
        SidebarItem(tr("Impostazioni"), Icons.Rounded.Settings, Nav.current == Route.Settings) { Nav.section(Route.Settings) }
        Spacer(Modifier.height(10.dp))
    }
}

@Composable
private fun SearchField() {
    val palette = LocalPalette.current
    var text by remember { mutableStateOf("") }
    Row(
        Modifier.fillMaxWidth().height(34.dp).clip(RoundedCornerShape(8.dp)).background(palette.cardHover).padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Rounded.Search, null, Modifier.size(16.dp), tint = palette.secondary)
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f)) {
            if (text.isEmpty()) Text(tr("Cerca"), color = palette.tertiary, fontSize = 13.sp)
            BasicTextField(
                text,
                onValueChange = { value ->
                    text = value
                    // Search as you type, as on the iPhone: the page follows the field.
                    if (Nav.current is Route.Search) Nav.replace(Route.Search(value)) else Nav.open(Route.Search(value))
                },
                singleLine = true,
                textStyle = TextStyle(color = palette.text, fontSize = 13.sp),
                cursorBrush = SolidColor(palette.accent),
                modifier = Modifier.fillMaxWidth().onKeyEvent { event ->
                    if (event.key == Key.Escape) {
                        text = ""
                        true
                    } else {
                        false
                    }
                },
            )
        }
    }
}

@Composable
private fun SidebarHeading(title: String) {
    Text(title, color = LocalPalette.current.tertiary, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 8.dp, top = 18.dp, bottom = 6.dp))
}

@Composable
private fun SidebarItem(title: String, icon: ImageVector, selected: Boolean, onClick: () -> Unit) {
    val palette = LocalPalette.current
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(7.dp))
            .background(if (selected) palette.cardHover else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(icon, null, Modifier.size(18.dp), tint = palette.accent)
        Text(title, color = palette.text, fontSize = 13.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
    }
}
