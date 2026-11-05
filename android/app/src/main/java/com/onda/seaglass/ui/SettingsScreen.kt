package com.onda.seaglass.ui

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.text.format.Formatter
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Lyrics
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material.icons.rounded.Storage
import androidx.compose.material.icons.rounded.SystemUpdate
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.onda.seaglass.BuildConfig
import com.onda.seaglass.core.L10n
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Accent
import com.onda.seaglass.data.AudioQuality
import com.onda.seaglass.data.AudioSupport
import com.onda.seaglass.data.Downloads
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.LyricsTranslator
import com.onda.seaglass.data.Prefs
import com.onda.seaglass.data.SongTransition
import com.onda.seaglass.data.Updates
import com.onda.seaglass.playback.BitPerfect
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/** Settings: a short list of topics, each with its own page, as in the iPhone app. */
@Composable
fun SettingsScreen() {
    val app = LocalApp.current
    val context = LocalContext.current
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val language = L10n.locale.getDisplayLanguage(L10n.locale).replaceFirstChar { it.titlecase(L10n.locale) }
    // Each topic says what it holds and how it's set, so a page is opened only to change something.
    val wifi by Prefs.wifiQuality.flow.collectAsStateWithLifecycle()
    val cellular by Prefs.cellularQuality.flow.collectAsStateWithLifecycle()
    val dolby by Prefs.preferDolby.flow.collectAsStateWithLifecycle()
    val normalize by Prefs.normalizeVolume.flow.collectAsStateWithLifecycle()
    val transition by Prefs.transition.flow.collectAsStateWithLifecycle()
    val seconds by Prefs.crossfadeSeconds.collectAsStateWithLifecycle()
    val autoRadio by Prefs.autoRadio.collectAsStateWithLifecycle()
    val target by Prefs.translationTarget.flow.collectAsStateWithLifecycle()
    val accent by Prefs.accent.collectAsStateWithLifecycle()
    val artworkColors by Prefs.artworkColors.collectAsStateWithLifecycle()
    val downloads by Downloads.items.collectAsStateWithLifecycle()
    fun short(quality: AudioQuality) = quality.title.substringBefore(" · ")
    val audio = listOfNotNull(
        "${tr("Wi-Fi")} ${short(wifi)}",
        "${tr("Rete cellulare")} ${short(cellular)}",
        tr("Dolby quando disponibile").takeIf { dolby && AudioSupport.dolby },
        tr("Volume uniforme").takeIf { normalize },
    ).joinToString(" · ")
    val playback = listOfNotNull(
        when (transition) {
            SongTransition.CROSSFADE -> "${transition.title} ${tr("%lld s", seconds.roundToInt())}"
            else -> transition.title
        },
        tr("Radio automatica").takeIf { autoRadio },
    ).joinToString(" · ")
    val downloaded = downloads.values.count { it.isComplete }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = top, bottom = LocalBottomPadding.current)) {
        item { ScreenTitle(tr("Impostazioni")) }
        item {
            Group {
                TopicRow(Icons.Rounded.GraphicEq, tr("Audio"), audio) { app.open("settings/audio") }
                Divider()
                TopicRow(Icons.Rounded.PlayCircle, tr("Riproduzione"), playback) { app.open("settings/playback") }
                Divider()
                TopicRow(Icons.Rounded.Lyrics, tr("Testi"), "${tr("Traduci in")} ${LyricsTranslator.languageName(target.ifEmpty { LyricsTranslator.target() })}") {
                    app.open("settings/lyrics")
                }
                Divider()
                TopicRow(
                    Icons.Rounded.Palette, tr("Aspetto"),
                    listOfNotNull(accent.title, tr("Colori dalla copertina").takeIf { artworkColors }).joinToString(" · "),
                ) { app.open("settings/appearance") }
                Divider()
                TopicRow(Icons.Rounded.Language, tr("Lingua"), language) { openLanguageSettings(context) }
            }
        }
        item {
            Group {
                TopicRow(
                    Icons.Rounded.Storage, tr("Spazio"),
                    "${tr("Brani scaricati")}: $downloaded · ${Formatter.formatShortFileSize(context, Downloads.bytes)}",
                ) { app.open("settings/storage") }
                Divider()
                TopicRow(Icons.Rounded.SystemUpdate, tr("Aggiornamenti"), tr("Hai la versione %@", BuildConfig.VERSION_NAME)) {
                    app.open("settings/updates")
                }
                Divider()
                TopicRow(Icons.Rounded.Info, tr("Informazioni"), tr("Codice sorgente su GitHub")) { app.open("settings/about") }
            }
        }
    }
}

private fun openLanguageSettings(context: android.content.Context) {
    // Android 13 and later choose the app's language in the system settings.
    val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        Intent(Settings.ACTION_APP_LOCALE_SETTINGS, Uri.fromParts("package", context.packageName, null))
    } else {
        Intent(Settings.ACTION_LOCALE_SETTINGS)
    }
    runCatching { context.startActivity(intent) }
}

/** A settings page: its title, a back button, its groups. */
@Composable
fun SettingsPage(page: String) {
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val title = when (page) {
        "audio" -> tr("Audio")
        "playback" -> tr("Riproduzione")
        "lyrics" -> tr("Testi")
        "appearance" -> tr("Aspetto")
        "storage" -> tr("Spazio")
        "updates" -> tr("Aggiornamenti")
        else -> tr("Informazioni")
    }
    Box(Modifier.fillMaxSize()) {
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(top = top + 52.dp, bottom = LocalBottomPadding.current),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item { ScreenTitle(title) }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    when (page) {
                        "audio" -> AudioSettings()
                        "playback" -> PlaybackSettings()
                        "lyrics" -> LyricsSettings()
                        "appearance" -> AppearanceSettings()
                        "storage" -> StorageSettings()
                        "updates" -> UpdateSettings()
                        else -> AboutSettings()
                    }
                }
            }
        }
        GlassBackButton(Modifier.padding(top = top + 8.dp, start = 12.dp))
    }
}

@Composable
private fun AudioSettings() {
    val wifi by Prefs.wifiQuality.flow.collectAsStateWithLifecycle()
    val cellular by Prefs.cellularQuality.flow.collectAsStateWithLifecycle()
    val download by Prefs.downloadQuality.flow.collectAsStateWithLifecycle()
    val dolby by Prefs.preferDolby.flow.collectAsStateWithLifecycle()
    val normalize by Prefs.normalizeVolume.flow.collectAsStateWithLifecycle()
    val bitPerfect by Prefs.bitPerfect.flow.collectAsStateWithLifecycle()
    val bitPerfectStatus by BitPerfect.status.collectAsStateWithLifecycle()
    var picking by remember { mutableStateOf<Prefs.Choice<AudioQuality>?>(null) }

    Group(tr("Qualità"), footer = tr("«Massima» usa Opus a 160 kbps, la qualità più alta di YouTube senza Premium.")) {
        ValueRow(tr("Wi-Fi"), wifi.title) { picking = Prefs.wifiQuality }
        Divider()
        ValueRow(tr("Rete cellulare"), cellular.title) { picking = Prefs.cellularQuality }
        Divider()
        ValueRow(tr("Download"), download.let { if (it == AudioQuality.MEDIUM) AudioQuality.LOW else it }.title) { picking = Prefs.downloadQuality }
    }
    Group(tr("Formato"), footer = if (AudioSupport.dolby) null else tr("Questo telefono non decodifica il Dolby.")) {
        ToggleRow(tr("Dolby quando disponibile"), dolby && AudioSupport.dolby, enabled = AudioSupport.dolby) { Prefs.preferDolby.set(it) }
        Divider()
        ToggleRow(tr("Volume uniforme"), normalize) { Prefs.normalizeVolume.set(it) }
    }
    Group(
        footer = tr("Invia l'audio al DAC USB così com'è, alla frequenza di ogni brano, senza il mixer di Android. Il volume diventa quello del DAC; volume uniforme e dissolvenza si fermano."),
    ) {
        ToggleRow(tr("Bit-perfect (DAC USB)"), bitPerfect, enabled = BitPerfect.supported) { Prefs.bitPerfect.set(it) }
        if (bitPerfect || !BitPerfect.supported) {
            Divider()
            Text(
                if (!BitPerfect.supported) BitPerfect.describe(BitPerfect.Status.Unsupported) else BitPerfect.describe(bitPerfectStatus),
                color = Secondary, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
            )
        }
    }

    picking?.let { choice ->
        val options = if (choice === Prefs.downloadQuality) {
            listOf(AudioQuality.MAX, AudioQuality.HIGH, AudioQuality.LOW)
        } else {
            AudioQuality.entries
        }
        OptionsDialog(
            title = when (choice) {
                Prefs.wifiQuality -> tr("Wi-Fi")
                Prefs.cellularQuality -> tr("Rete cellulare")
                else -> tr("Download")
            },
            options = options.map { it to it.title },
            selected = choice.value.let { if (choice === Prefs.downloadQuality && it == AudioQuality.MEDIUM) AudioQuality.LOW else it },
            onSelect = { choice.set(it) },
            onDismiss = { picking = null },
        )
    }
}

@Composable
private fun PlaybackSettings() {
    val transition by Prefs.transition.flow.collectAsStateWithLifecycle()
    val seconds by Prefs.crossfadeSeconds.collectAsStateWithLifecycle()
    val autoRadio by Prefs.autoRadio.collectAsStateWithLifecycle()
    val skipLongMixes by Prefs.skipLongMixes.collectAsStateWithLifecycle()
    val accent = LocalAccent.current
    Group(tr("Transizioni")) {
        SongTransition.entries.forEachIndexed { index, option ->
            if (index > 0) Divider()
            ChoiceRow(option.title, transition == option) { Prefs.transition.set(option) }
        }
        if (transition == SongTransition.CROSSFADE) {
            Divider()
            Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(tr("Durata della dissolvenza"), Modifier.weight(1f), fontSize = 16.sp)
                    Text(tr("%lld s", seconds.roundToInt()), color = Secondary, fontSize = 15.sp)
                }
                Slider(
                    value = seconds, onValueChange = { Prefs.setCrossfadeSeconds(it.roundToInt().toFloat()) },
                    valueRange = 1f..12f, steps = 10,
                    colors = SliderDefaults.colors(thumbColor = accent, activeTrackColor = accent),
                )
            }
        }
    }
    Group(footer = tr("Quando la coda finisce, continua con brani simili.")) {
        ToggleRow(tr("Radio automatica"), autoRadio, onChange = Prefs::setAutoRadio)
    }
    Group(footer = tr("Tiene fuori da radio e consigli i video di oltre 15 minuti.")) {
        ToggleRow(tr("Salta le compilation lunghe"), skipLongMixes, onChange = Prefs::setSkipLongMixes)
    }
}

@Composable
private fun LyricsSettings() {
    val target by Prefs.translationTarget.flow.collectAsStateWithLifecycle()
    var picking by remember { mutableStateOf(false) }
    Group(tr("Traduci i testi"), footer = tr("La traduzione avviene sul dispositivo, anche offline.")) {
        ValueRow(tr("Traduci in"), LyricsTranslator.languageName(target.ifEmpty { LyricsTranslator.target() })) { picking = true }
    }
    if (picking) {
        OptionsDialog(
            title = tr("Traduci in"),
            options = LyricsTranslator.languages.map { it to LyricsTranslator.languageName(it) },
            selected = LyricsTranslator.target(),
            onSelect = { Prefs.translationTarget.set(it) },
            onDismiss = { picking = false },
        )
    }
}

@Composable
private fun AppearanceSettings() {
    val accent by Prefs.accent.collectAsStateWithLifecycle()
    val artworkColors by Prefs.artworkColors.collectAsStateWithLifecycle()
    Group {
        Text(tr("Colore del tema"), fontSize = 16.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp))
        FlowRow(
            Modifier.padding(horizontal = 16.dp).padding(bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Accent.entries.forEach { choice ->
                Box(
                    Modifier
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(choice.color)
                        .then(if (choice == accent) Modifier.border(2.dp, Color.White, CircleShape) else Modifier)
                        .clickable { Prefs.setAccent(choice) },
                    contentAlignment = Alignment.Center,
                ) { if (choice == accent) Icon(Icons.Rounded.Check, choice.title, tint = Color.White, modifier = Modifier.size(18.dp)) }
            }
        }
        Divider()
        ToggleRow(tr("Colori dalla copertina"), artworkColors, onChange = Prefs::setArtworkColors)
    }
}

@Composable
private fun StorageSettings() {
    val app = LocalApp.current
    val context = LocalContext.current
    val downloads by Downloads.items.collectAsStateWithLifecycle()
    var confirm by remember { mutableStateOf(false) }
    val count = downloads.values.count { it.isComplete }
    Group(tr("Musica scaricata")) {
        ValueRow(tr("Brani scaricati"), count.toString()) { app.open("downloads") }
        Divider()
        ValueRow(tr("Spazio occupato"), Formatter.formatShortFileSize(context, Downloads.bytes)) {}
        if (downloads.isNotEmpty()) {
            Divider()
            ValueRow(tr("Elimina tutti i download"), "", tint = Color(0xFFFF6B6B)) { confirm = true }
        }
    }
    Group {
        ValueRow(tr("Cancella ricerche recenti"), "") {
            Prefs.clearRecentSearches()
            app.toast(tr("Fine"))
        }
        Divider()
        ValueRow(tr("Cancella cronologia ascolti"), "") {
            Library.clearHistory()
            app.toast(tr("Fine"))
        }
    }
    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            containerColor = Color(0xFF1C1C24),
            title = { Text(tr("Eliminare tutti i brani scaricati?")) },
            confirmButton = {
                TextButton(onClick = { Downloads.removeAll(); confirm = false }) { Text(tr("Elimina"), color = Color(0xFFFF6B6B)) }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text(tr("Annulla")) } },
        )
    }
}

@Composable
private fun UpdateSettings() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var update by remember { mutableStateOf<String?>(null) }
    var release by remember { mutableStateOf<Updates.Release?>(null) }
    Group(footer = tr("Hai la versione %@", BuildConfig.VERSION_NAME)) {
        ValueRow(tr("Cerca aggiornamenti"), update.orEmpty()) {
            update = "…"
            scope.launch {
                runCatching { Updates.latest() }
                    .onSuccess { latest ->
                        release = latest?.takeIf(Updates::isNewer)
                        update = if (release != null) tr("Nuova versione") else tr("Aggiornata")
                    }
                    .onFailure { update = tr("Non riuscito") }
            }
        }
        release?.let { newer ->
            Divider()
            ValueRow(tr("Seaglass %@", newer.version), tr("Scarica")) {
                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(newer.apkUrl ?: newer.pageUrl)))
            }
            if (newer.notes.isNotBlank()) {
                Text(newer.notes, color = Secondary, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            }
        }
    }
}

@Composable
private fun AboutSettings() {
    val context = LocalContext.current
    Group {
        ValueRow(tr("Versione"), BuildConfig.VERSION_NAME) {}
        Divider()
        ValueRow(tr("Codice sorgente su GitHub"), "") {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/Foglio24/onda")))
        }
    }
}

@Composable
private fun <T> OptionsDialog(title: String, options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF1C1C24),
        title = { Text(title) },
        text = {
            LazyColumn(Modifier.heightIn(max = 420.dp)) {
                items(options) { (value, label) ->
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable { onSelect(value); onDismiss() }.padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = value == selected, onClick = { onSelect(value); onDismiss() }, colors = RadioButtonDefaults.colors(selectedColor = LocalAccent.current))
                        Text(label, fontSize = 16.sp)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(tr("Annulla")) } },
    )
}

@Composable
private fun Group(title: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp)) {
        if (title != null) {
            Text(
                title.uppercase(L10n.locale), fontSize = 13.sp, color = Secondary, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 16.dp, bottom = 6.dp, top = 8.dp),
            )
        }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.07f)), content = content)
        if (footer != null) {
            Text(footer, fontSize = 13.sp, color = Secondary, modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp))
        }
    }
}

@Composable
private fun Divider() = HorizontalDivider(Modifier.padding(start = 16.dp), color = Color.White.copy(alpha = 0.08f))

@Composable
private fun TopicRow(icon: ImageVector, title: String, summary: String = "", onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(34.dp).clip(RoundedCornerShape(9.dp)).background(LocalAccent.current),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, tint = Color.White, modifier = Modifier.size(20.dp)) }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.Medium)
            if (summary.isNotEmpty()) {
                Text(summary, color = Secondary, fontSize = 13.sp, lineHeight = 17.sp, maxLines = 2)
            }
        }
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = Secondary)
    }
}

@Composable
private fun ToggleRow(title: String, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(enabled = enabled) { onChange(!checked) }.padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f), fontSize = 16.sp, color = if (enabled) Color.White else Secondary)
        Switch(
            checked = checked, onCheckedChange = onChange, enabled = enabled,
            colors = SwitchDefaults.colors(checkedTrackColor = LocalAccent.current),
        )
    }
}

@Composable
private fun ChoiceRow(title: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f), fontSize = 16.sp)
        RadioButton(selected = selected, onClick = onClick, colors = RadioButtonDefaults.colors(selectedColor = LocalAccent.current))
    }
}

@Composable
private fun ValueRow(title: String, value: String, tint: Color = Color.White, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 15.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f), fontSize = 16.sp, color = tint)
        if (value.isNotEmpty()) {
            Spacer(Modifier.width(8.dp))
            Text(value, color = Secondary, fontSize = 15.sp, maxLines = 2)
        }
    }
}

/** The downloaded songs, newest first ("Brani scaricati"). */
@Composable
fun DownloadsScreen() {
    val items by Downloads.items.collectAsStateWithLifecycle()
    val songs = items.values.sortedByDescending { it.started }.map { it.track }
    DownloadListScreen(songs)
}

@Composable
private fun DownloadListScreen(songs: List<com.onda.seaglass.model.Track>) {
    TrackListPage(tr("Download"), songs, tr("Nessun download"), tr("Tocca ··· accanto a un brano e scegli Scarica."), downloadable = false)
}
