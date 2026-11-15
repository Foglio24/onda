package com.onda.seaglass.ui

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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.BuildConfig
import com.onda.seaglass.account.Account
import com.onda.seaglass.update.AppUpdater
import kotlinx.coroutines.launch
import java.awt.Desktop
import java.net.URI

enum class Page { Home, Search, Library, Settings }

@Composable
fun ClassicShell() {
    var page by remember { mutableStateOf(Page.Home) }
    var libraryWidth by remember { mutableStateOf(260.dp) }
    var queueWidth by remember { mutableStateOf(300.dp) }
    var queueOpen by remember { mutableStateOf(true) }

    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        UpdateBanner()
        Row(Modifier.weight(1f).fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            LibraryPanel(
                width = libraryWidth,
                page = page,
                onSelect = { page = it },
            )
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surface)
                    .padding(20.dp)
            ) {
                when (page) {
                    Page.Home -> HomePage()
                    Page.Search -> SearchPage()
                    Page.Library -> LibraryPage()
                    Page.Settings -> SettingsPage()
                }
            }
            if (queueOpen) {
                QueuePanel(width = queueWidth)
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
        is AppUpdater.Status.Available -> {
            Banner(
                text = "Seaglass ${s.release.version} è disponibile",
                action = "Installa",
                onAction = { scope.launch { AppUpdater.downloadAndStage(s.release) } },
            )
        }
        is AppUpdater.Status.Downloading -> {
            Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface).padding(8.dp)) {
                Text("Download aggiornamento…", color = MaterialTheme.colorScheme.onSurface)
                LinearProgressIndicator(
                    progress = {
                        if (s.total > 0) (s.received.toFloat() / s.total).coerceIn(0f, 1f) else 0f
                    },
                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                )
            }
        }
        is AppUpdater.Status.Ready -> {
            Banner(
                text = "Seaglass ${s.release.version} è pronto",
                action = "Riavvia e installa",
                onAction = {
                    if (AppUpdater.installAndRelaunch()) {
                        kotlin.system.exitProcess(0)
                    }
                },
            )
        }
        is AppUpdater.Status.Failed -> {
            Banner(text = "Aggiornamento: ${s.message}", action = null, onAction = {})
        }
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
        if (action != null) {
            TextButton(onClick = onAction) { Text(action) }
        }
    }
}

@Composable
private fun LibraryPanel(width: androidx.compose.ui.unit.Dp, page: Page, onSelect: (Page) -> Unit) {
    Column(
        Modifier
            .width(width)
            .fillMaxHeight()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface)
            .padding(12.dp)
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
private fun NavItem(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, selected: Boolean, onClick: () -> Unit) {
    val bg = if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.2f) else MaterialTheme.colorScheme.surface
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(bg)
            .clickable(onClick = onClick)
            .padding(10.dp),
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
                    val url = Account.signedInManageUrl()
                    Desktop.getDesktop().browse(URI(url))
                }
            }) { Text("Gestisci sul sito") }
            TextButton(onClick = { Account.signOut() }) { Text("Esci") }
        } else {
            Button(onClick = { scope.launch { Account.signIn() } }) { Text("Accedi con il sito") }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp) }
    }
}

@Composable
private fun QueuePanel(width: androidx.compose.ui.unit.Dp) {
    Column(
        Modifier
            .width(width)
            .fillMaxHeight()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface)
            .padding(16.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.AutoMirrored.Filled.QueueMusic, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text("Coda", fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(12.dp))
        Text("Stai ascoltando", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
        Text("—", fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(16.dp))
        Text("In coda", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
        Text("Nessun brano. Avvia la riproduzione dalla Home o da Cerca.")
    }
}

@Composable
private fun PlayerBar(queueOpen: Boolean, onToggleQueue: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .height(72.dp)
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text("Seaglass per Windows", fontWeight = FontWeight.SemiBold)
            Text("v${BuildConfig.VERSION_NAME}", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
        }
        Text("▶  ⏮  ⏭", fontSize = 18.sp)
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onToggleQueue) {
            Text(if (queueOpen) "Nascondi coda" else "Coda")
        }
    }
}

@Composable
private fun HomePage() {
    Column {
        Text("Home", fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text(
            "Benvenuto su Seaglass per Windows 11. Accedi con lo stesso account del sito per sincronizzare libreria e preferenze con iPhone, iPad e Mac.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun SearchPage() {
    Column {
        Text("Cerca", fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text("La ricerca YouTube Music arriva nella prossima build (stesso motore di Android).", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun LibraryPage() {
    Column {
        Text("La tua libreria", fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text("Brani che ti piacciono, playlist e cronologia si sincronizzano con l’account.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SettingsPage() {
    val scope = rememberCoroutineScope()
    val status by AppUpdater.status.collectAsState()
    Column {
        Text("Impostazioni", fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(16.dp))
        Text("Aggiornamenti", fontWeight = FontWeight.SemiBold)
        Text("Come sul Mac: Seaglass cerca `windows-v*` su GitHub e installa da sola.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(8.dp))
        Button(onClick = { scope.launch { AppUpdater.check(userInitiated = true) } }) {
            Text("Cerca aggiornamenti")
        }
        Text("Stato: ${status::class.simpleName}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(24.dp))
        Text("Account", fontWeight = FontWeight.SemiBold)
        Text("Gestito su ${Account.manageUrl}", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
