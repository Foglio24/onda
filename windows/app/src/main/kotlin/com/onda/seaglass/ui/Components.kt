@file:OptIn(ExperimentalComposeUiApi::class, ExperimentalFoundationApi::class)

package com.onda.seaglass.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.PlaylistAdd
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.RemoveCircleOutline
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.isSecondaryPressed
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.audio.Player
import com.onda.seaglass.audio.isLocal
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Downloads
import com.onda.seaglass.data.Library
import com.onda.seaglass.model.MusicItem
import com.onda.seaglass.model.Track
import com.onda.seaglass.model.formatDuration

@Composable
fun Hoverable(modifier: Modifier = Modifier, content: @Composable (hovered: Boolean) -> Unit) {
    var hovered by remember { mutableStateOf(false) }
    Box(
        modifier
            .onPointerEvent(PointerEventType.Enter) { hovered = true }
            .onPointerEvent(PointerEventType.Exit) { hovered = false },
    ) { content(hovered) }
}

@Composable
fun SectionHeader(title: String, action: String? = null, onAction: (() -> Unit)? = null) {
    val palette = LocalPalette.current
    Row(Modifier.fillMaxWidth().padding(top = 18.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, fontSize = 20.sp, fontWeight = FontWeight.Bold, color = palette.text, modifier = Modifier.weight(1f))
        if (action != null && onAction != null) {
            Text(action, color = palette.accent, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, modifier = Modifier.clickable(onClick = onAction))
        }
    }
}

/** A pill-shaped button, filled with the accent or quiet. */
@Composable
fun PillButton(label: String, icon: ImageVector? = null, prominent: Boolean = false, onClick: () -> Unit) {
    val palette = LocalPalette.current
    Row(
        Modifier.clip(RoundedCornerShape(50))
            .background(if (prominent) palette.accent else palette.cardHover)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (icon != null) Icon(icon, null, Modifier.size(18.dp), tint = if (prominent) Color.White else palette.text)
        Text(label, color = if (prominent) Color.White else palette.text, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
    }
}

/** Play and Shuffle under a page's title. */
@Composable
fun PlayShuffleButtons(tracks: List<Track>, source: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        PillButton(tr("Riproduci"), Icons.Rounded.PlayArrow, prominent = true) { Player.play(tracks, 0, source, shuffled = false) }
        PillButton(tr("Casuale"), Icons.Rounded.Shuffle) { Player.play(tracks, (tracks.indices).random(), source, shuffled = true) }
    }
}

/** A page's top: the cover, the title, a line or two under it, and its buttons. */
@Composable
fun PageHeader(
    title: String,
    subtitle: String?,
    detail: String?,
    artwork: String?,
    round: Boolean = false,
    actions: @Composable RowScope.() -> Unit = {},
) {
    val palette = LocalPalette.current
    Row(Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 18.dp), verticalAlignment = Alignment.Bottom) {
        RemoteImage(artwork, Modifier.size(200.dp), if (round) CircleShape else RoundedCornerShape(10.dp))
        Spacer(Modifier.width(24.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 34.sp, fontWeight = FontWeight.Bold, color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (!subtitle.isNullOrBlank()) Text(subtitle, fontSize = 17.sp, color = palette.accent, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 4.dp))
            if (!detail.isNullOrBlank()) Text(detail, fontSize = 13.sp, color = palette.secondary, modifier = Modifier.padding(top = 4.dp))
            Row(Modifier.padding(top = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically, content = actions)
        }
    }
}

/**
 * A song in a list: double-click (or the cover's play) plays [tracks] from it; right-click or ⋯
 * opens its menu. The playing song shows in the accent colour.
 */
@Composable
fun TrackRow(
    track: Track,
    index: Int,
    tracks: List<Track>,
    source: String,
    number: Int? = null,
    showArtwork: Boolean = true,
    extraMenu: (@Composable (close: () -> Unit) -> Unit)? = null,
) {
    val palette = LocalPalette.current
    val state by Player.state.collectAsState()
    val liked by Library.liked.collectAsState()
    val isCurrent = state.current?.videoId == track.videoId
    var menu by remember { mutableStateOf(false) }
    Hoverable { hovered ->
        Row(
            Modifier.fillMaxWidth().height(56.dp).clip(RoundedCornerShape(8.dp))
                .background(if (hovered) palette.cardHover else Color.Transparent)
                .combinedClickable(onDoubleClick = { Player.play(tracks, index, source) }, onClick = {})
                .onPointerEvent(PointerEventType.Press) { if (it.buttons.isSecondaryPressed) menu = true }
                .padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (number != null) {
                Box(Modifier.width(28.dp), contentAlignment = Alignment.Center) {
                    if (hovered) {
                        Icon(Icons.Rounded.PlayArrow, tr("Riproduci"), Modifier.size(20.dp).clickable { Player.play(tracks, index, source) }, tint = palette.text)
                    } else {
                        Text("$number", color = if (isCurrent) palette.accent else palette.secondary, fontSize = 13.sp)
                    }
                }
                Spacer(Modifier.width(10.dp))
            }
            if (showArtwork) {
                Box(contentAlignment = Alignment.Center) {
                    RemoteImage(track.resized(120), Modifier.size(40.dp), RoundedCornerShape(5.dp))
                    if (hovered && number == null) {
                        Box(Modifier.size(40.dp).clip(RoundedCornerShape(5.dp)).background(Color(0x88000000)).clickable { Player.play(tracks, index, source) }, contentAlignment = Alignment.Center) {
                            Icon(Icons.Rounded.PlayArrow, tr("Riproduci"), tint = Color.White)
                        }
                    }
                }
                Spacer(Modifier.width(12.dp))
            }
            Column(Modifier.weight(1.4f)) {
                Text(track.title, color = if (isCurrent) palette.accent else palette.text, fontWeight = FontWeight.Medium, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(track.artist, color = palette.secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.clickable(enabled = !track.isLocal && track.primaryArtist.isNotEmpty()) { Nav.open(Route.Artist(track.artistId, track.primaryArtist)) })
            }
            Text(track.album.orEmpty(), color = palette.secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f).padding(horizontal = 12.dp).clickable(enabled = track.albumId != null) { track.albumId?.let { Nav.open(Route.Album(it)) } })
            val isLiked = liked.any { it.videoId == track.videoId }
            if (!track.isLocal && (hovered || isLiked)) {
                Icon(
                    if (isLiked) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                    tr(if (isLiked) "Rimuovi dai preferiti" else "Aggiungi ai preferiti"),
                    Modifier.size(18.dp).clickable { Library.toggleLike(track) },
                    tint = if (isLiked) palette.accent else palette.secondary,
                )
            } else {
                Spacer(Modifier.size(18.dp))
            }
            Text(formatDuration(track.duration), color = palette.secondary, fontSize = 12.sp, modifier = Modifier.width(56.dp).padding(start = 14.dp))
            Box {
                IconButton(onClick = { menu = true }, Modifier.size(32.dp)) {
                    Icon(Icons.Rounded.MoreHoriz, tr("Altre opzioni"), tint = if (hovered) palette.text else Color.Transparent)
                }
                TrackMenu(track, menu, { menu = false }, extraMenu)
            }
        }
    }
}

/** A song's actions, as the iPhone app's ··· menu. */
@Composable
fun TrackMenu(track: Track, expanded: Boolean, onDismiss: () -> Unit, extra: (@Composable (close: () -> Unit) -> Unit)? = null) {
    val clipboard = LocalClipboardManager.current
    val downloads by Downloads.items.collectAsState()
    val liked by Library.liked.collectAsState()
    DropdownMenu(expanded, onDismiss) {
        fun item(label: String, icon: ImageVector, action: () -> Unit): @Composable () -> Unit = {
            DropdownMenuItem(text = { Text(label) }, leadingIcon = { Icon(icon, null) }, onClick = {
                onDismiss()
                action()
            })
        }
        item(tr("Riproduci dopo"), Icons.Rounded.SkipNext) { Player.playNext(track); Nav.toast(tr("Riproduci dopo")) }()
        item(tr("Aggiungi in coda"), Icons.AutoMirrored.Rounded.QueueMusic) { Player.addToQueue(listOf(track)); Nav.toast(tr("Aggiunto alla coda")) }()
        if (!track.isLocal) {
            item(tr("Avvia radio"), Icons.Rounded.Radio) { Player.play(listOf(track), 0, track.title); }()
            item(tr("Aggiungi a una playlist"), Icons.AutoMirrored.Rounded.PlaylistAdd) { Nav.addToPlaylist = listOf(track) }()
            val isLiked = liked.any { it.videoId == track.videoId }
            item(tr(if (isLiked) "Rimuovi dai preferiti" else "Aggiungi ai preferiti"), if (isLiked) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder) { Library.toggleLike(track) }()
            val download = downloads[track.videoId]
            if (download == null) {
                item(tr("Scarica"), Icons.Rounded.Download) { Downloads.download(listOf(track)) }()
            } else {
                item(tr("Rimuovi download"), Icons.Rounded.RemoveCircleOutline) { Downloads.remove(track) }()
            }
            if (track.primaryArtist.isNotEmpty()) item(tr("Vai all'artista"), Icons.Rounded.Person) { Nav.open(Route.Artist(track.artistId, track.primaryArtist)) }()
            track.albumId?.let { album -> item(tr("Vai all'album"), Icons.Rounded.Album) { Nav.open(Route.Album(album)) }() }
            item(tr("Informazioni sul brano"), Icons.Rounded.Info) { Nav.open(Route.SongInfo(track)) }()
            item(tr("Copia link"), Icons.Rounded.Link) {
                clipboard.setText(AnnotatedString(track.shareUrl))
                Nav.toast(tr("Link copiato"))
            }()
        }
        extra?.invoke(onDismiss)
    }
}

/** A song list with its column headers. */
@Composable
fun TrackList(tracks: List<Track>, source: String, numbered: Boolean = false, showArtwork: Boolean = true, extraMenu: ((Track, Int) -> (@Composable (close: () -> Unit) -> Unit)?)? = null) {
    Column {
        tracks.forEachIndexed { index, track ->
            TrackRow(track, index, tracks, source, if (numbered) index + 1 else null, showArtwork, extraMenu?.invoke(track, index))
        }
    }
}

/** A card of an album, artist or playlist in a shelf. */
@Composable
fun ItemCard(item: MusicItem, size: Dp = 168.dp, onClick: () -> Unit) {
    val palette = LocalPalette.current
    Hoverable { hovered ->
        Column(
            Modifier.width(size + 16.dp).clip(RoundedCornerShape(10.dp))
                .background(if (hovered) palette.cardHover else Color.Transparent)
                .clickable(onClick = onClick).padding(8.dp),
        ) {
            val round = item.kind == MusicItem.Kind.ARTIST
            RemoteImage(item.artworkUrl, Modifier.size(size), if (round) CircleShape else RoundedCornerShape(8.dp))
            Text(item.title, color = palette.text, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 8.dp))
            if (item.subtitle.isNotBlank()) Text(item.subtitle, color = palette.secondary, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** A song as a card: play on click. */
@Composable
fun TrackCard(track: Track, size: Dp = 168.dp, onClick: () -> Unit) {
    val palette = LocalPalette.current
    var menu by remember { mutableStateOf(false) }
    Hoverable { hovered ->
        Column(
            Modifier.width(size + 16.dp).clip(RoundedCornerShape(10.dp))
                .background(if (hovered) palette.cardHover else Color.Transparent)
                .clickable(onClick = onClick)
                .onPointerEvent(PointerEventType.Press) { if (it.buttons.isSecondaryPressed) menu = true }
                .padding(8.dp),
        ) {
            Box(contentAlignment = Alignment.BottomEnd) {
                RemoteImage(track.resized(400), Modifier.size(size), RoundedCornerShape(8.dp))
                if (hovered) {
                    Box(Modifier.padding(8.dp).size(36.dp).clip(CircleShape).background(palette.accent), contentAlignment = Alignment.Center) {
                        Icon(Icons.Rounded.PlayArrow, tr("Riproduci"), tint = Color.White)
                    }
                }
                TrackMenu(track, menu, { menu = false })
            }
            Text(track.title, color = palette.text, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 8.dp))
            Text(track.artist, color = palette.secondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** A row that scrolls sideways (with the mouse wheel's shift, or a touchpad). */
@Composable
fun Shelf(content: @Composable RowScope.() -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp), content = content)
}

/** "Aggiungi a una playlist": the user's playlists, or a new one. */
@Composable
fun AddToPlaylistDialog() {
    val tracks = Nav.addToPlaylist ?: return
    val playlists by Library.playlists.collectAsState()
    var creating by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    val palette = LocalPalette.current
    AlertDialog(
        onDismissRequest = { Nav.addToPlaylist = null },
        title = { Text(tr("Aggiungi a una playlist")) },
        text = {
            Column {
                if (creating) {
                    OutlinedTextField(name, { name = it }, label = { Text(tr("Nome")) }, singleLine = true)
                } else {
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).clickable { creating = true }.padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.AutoMirrored.Rounded.PlaylistAdd, null, tint = palette.accent)
                        Spacer(Modifier.width(10.dp))
                        Text(tr("Nuova playlist"), color = palette.accent, fontWeight = FontWeight.SemiBold)
                    }
                    playlists.forEach { playlist ->
                        Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).clickable {
                                tracks.forEach { track -> if (!Library.contains(track, playlist.id)) Library.toggle(track, playlist.id) }
                                Nav.addToPlaylist = null
                                Nav.toast(tr("Aggiunto a %@", playlist.name))
                            }.padding(10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            RemoteImage(playlist.tracks.firstOrNull()?.resized(120), Modifier.size(36.dp), RoundedCornerShape(4.dp))
                            Spacer(Modifier.width(10.dp))
                            Text(playlist.name, color = palette.text)
                        }
                    }
                }
            }
        },
        confirmButton = {
            if (creating) {
                TextButton(onClick = {
                    val created = Library.createPlaylist(name, tracks)
                    Nav.addToPlaylist = null
                    Nav.toast(tr("Aggiunto a %@", created.name))
                }, enabled = name.isNotBlank()) { Text(tr("Crea")) }
            }
        },
        dismissButton = { TextButton(onClick = { Nav.addToPlaylist = null }) { Text(tr("Annulla")) } },
    )
}

/** A centred message for an empty or failed page. */
@Composable
fun EmptyState(icon: ImageVector, title: String, message: String? = null) {
    val palette = LocalPalette.current
    Column(Modifier.fillMaxWidth().padding(top = 80.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, null, Modifier.size(48.dp), tint = palette.tertiary)
        Text(title, color = palette.text, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, modifier = Modifier.padding(top = 12.dp))
        if (message != null) Text(message, color = palette.secondary, fontSize = 13.sp, modifier = Modifier.padding(top = 6.dp))
    }
}
