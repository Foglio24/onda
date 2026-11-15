package com.onda.seaglass.ui.pages

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AccountCircle
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.BuildConfig
import com.onda.seaglass.account.Account
import com.onda.seaglass.audio.Equalizer
import com.onda.seaglass.audio.EqualizerBands
import com.onda.seaglass.audio.EqualizerPreset
import com.onda.seaglass.audio.JavaSoundSink
import com.onda.seaglass.audio.Player
import com.onda.seaglass.core.L10n
import com.onda.seaglass.core.Prefs
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.SongCache
import com.onda.seaglass.ui.Accent
import com.onda.seaglass.ui.LocalPalette
import com.onda.seaglass.ui.Nav
import com.onda.seaglass.ui.PillButton
import com.onda.seaglass.ui.Route
import com.onda.seaglass.ui.SectionHeader
import com.onda.seaglass.ui.ThinSlider
import com.onda.seaglass.update.AppUpdater
import com.onda.seaglass.WindowsIntegration
import kotlin.math.log10
import kotlinx.coroutines.launch

@Composable
private fun Group(content: @Composable ColumnScope.() -> Unit) {
    val palette = LocalPalette.current
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(palette.card).padding(horizontal = 16.dp, vertical = 6.dp), content = content)
}

@Composable
private fun SettingRow(title: String, detail: String? = null, onClick: (() -> Unit)? = null, trailing: @Composable () -> Unit = {}) {
    val palette = LocalPalette.current
    Row(
        Modifier.fillMaxWidth().clickable(enabled = onClick != null) { onClick?.invoke() }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, color = palette.text, fontSize = 14.sp)
            if (detail != null) Text(detail, color = palette.secondary, fontSize = 12.sp, modifier = Modifier.padding(top = 2.dp))
        }
        trailing()
    }
}

@Composable
private fun Toggle(title: String, detail: String? = null, checked: Boolean, onChange: (Boolean) -> Unit) {
    val palette = LocalPalette.current
    SettingRow(title, detail, onClick = { onChange(!checked) }) {
        Switch(checked, onChange, colors = SwitchDefaults.colors(checkedTrackColor = palette.accent))
    }
}

/** A setting with a few choices, in a menu. */
@Composable
private fun <T> Choice(title: String, value: T, options: List<Pair<T, String>>, detail: String? = null, onSelect: (T) -> Unit) {
    val palette = LocalPalette.current
    var open by remember { mutableStateOf(false) }
    SettingRow(title, detail, onClick = { open = true }) {
        Box {
            Text(options.firstOrNull { it.first == value }?.second.orEmpty() + "  ▾", color = palette.secondary, fontSize = 13.sp)
            DropdownMenu(open, { open = false }) {
                options.forEach { (option, label) ->
                    DropdownMenuItem(
                        text = { Text(label) },
                        trailingIcon = { if (option == value) Icon(Icons.Rounded.Check, null) },
                        onClick = {
                            open = false
                            onSelect(option)
                        },
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SettingsPage() {
    val palette = LocalPalette.current
    val language by Prefs.language.state.collectAsState()
    val theme by Prefs.theme.state.collectAsState()
    val accent by Prefs.accent.state.collectAsState()
    val quality by Prefs.quality.state.collectAsState()
    val normalize by Prefs.normalizeVolume.state.collectAsState()
    val transition by Prefs.transition.state.collectAsState()
    val crossfade by Prefs.crossfadeSeconds.state.collectAsState()
    val device by Prefs.outputDevice.state.collectAsState()
    val tray by Prefs.keepPlayingInTray.state.collectAsState()
    val autostart by Prefs.startWithWindows.state.collectAsState()
    val autoUpdate by Prefs.autoUpdate.state.collectAsState()
    val skipMixes by Prefs.skipLongMixes.state.collectAsState()
    val update by AppUpdater.state.collectAsState()
    val signedIn by Account.signedIn.collectAsState()
    val details by Account.details.collectAsState()
    var languageChanged by remember { mutableStateOf(false) }
    Page {
        Text(tr("Impostazioni"), fontSize = 34.sp, fontWeight = FontWeight.Bold, color = palette.text)

        SectionHeader(tr("Account"))
        Group {
            SettingRow(
                if (signedIn) details?.name ?: details?.email ?: tr("Account Seaglass") else tr("Account Seaglass"),
                if (signedIn) details?.email else tr("Accedi per sincronizzare la libreria con iPhone, iPad e Mac."),
                onClick = { Nav.open(Route.Account) },
            ) { Icon(Icons.Rounded.AccountCircle, null, tint = palette.accent) }
        }

        SectionHeader(tr("Aspetto"))
        Group {
            Choice(tr("Lingua"), language, listOf<Pair<String?, String>>(null to tr("Sistema")) + L10n.supported.map { it to languageName(it) }) {
                Prefs.language.value = it
                languageChanged = true
            }
            if (languageChanged) Text(tr("La lingua cambia al prossimo avvio di Seaglass."), color = palette.accent, fontSize = 12.sp, modifier = Modifier.padding(bottom = 8.dp))
            Choice(tr("Tema"), theme, listOf("system" to tr("Sistema"), "dark" to tr("Scuro"), "light" to tr("Chiaro"))) { Prefs.theme.value = it }
            SettingRow(tr("Colore")) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Accent.entries.forEach { option ->
                        Box(
                            Modifier.size(22.dp).clip(CircleShape).background(option.color).clickable { Prefs.accent.value = option.key },
                            contentAlignment = Alignment.Center,
                        ) { if (option.key == accent) Icon(Icons.Rounded.Check, null, Modifier.size(14.dp), tint = if (option.color.luminance() > 0.4f) Color.Black else Color.White) }
                    }
                }
            }
        }

        SectionHeader(tr("Audio"))
        Group {
            Choice(
                tr("Qualità"), quality,
                listOf("max" to tr("Massima"), "high" to tr("Alta"), "medium" to tr("Media"), "low" to tr("Risparmio dati")),
            ) { Prefs.quality.value = it }
            Toggle(tr("Volume uniforme"), tr("Tutti i brani allo stesso volume, come su iPhone."), normalize) { Prefs.normalizeVolume.value = it }
            Choice(
                tr("Passaggio tra i brani"), transition,
                listOf("none" to tr("Senza pause"), "crossfade" to tr("Dissolvenza incrociata"), "automix" to tr("AutoMix")),
                detail = if (transition == "automix") tr("Il brano successivo entra a tempo, con i bassi che passano da un brano all'altro, come farebbe un DJ.") else null,
            ) {
                // AutoMix is a Premium feature, as on the iPhone.
                if (it == "automix" && !Account.unlocks()) Nav.premium = tr("AutoMix") else Prefs.transition.value = it
            }
            if (transition == "crossfade") {
                SettingRow(tr("Dissolvenza incrociata: %lld s", crossfade.toInt())) {
                    ThinSlider(crossfade.toFloat(), 1f..12f, Modifier.width(220.dp), step = 1f) { Prefs.crossfadeSeconds.value = it.toDouble() }
                }
            }
            Choice(tr("Uscita audio"), device, listOf<Pair<String?, String>>(null to tr("Predefinita di Windows")) + JavaSoundSink.devices().map { it to it }) {
                Prefs.outputDevice.value = it
                Player.engine.reopenOutput()
            }
        }

        SectionHeader(tr("Equalizzatore"))
        Group { EqualizerSection() }

        SectionHeader(tr("Last.fm"))
        Group { LastFMSettings() }

        SectionHeader(tr("Catalogo"))
        Group {
            Toggle(tr("Escludi i mix lunghi"), tr("Le compilation di oltre 20 minuti caricate come brani restano fuori da ricerche e consigli."), skipMixes) { Prefs.skipLongMixes.value = it }
        }

        SectionHeader(tr("Windows"))
        Group {
            Toggle(tr("Continua nell'area di notifica"), tr("Chiudendo la finestra la musica continua: Seaglass resta accanto all'orologio."), tray) { Prefs.keepPlayingInTray.value = it }
            Toggle(tr("Avvia con Windows"), null, autostart) {
                Prefs.startWithWindows.value = it
                WindowsIntegration.setAutostart(it)
            }
        }

        SectionHeader(tr("Spazio"))
        Group {
            var cache by remember { mutableStateOf(SongCache.bytes) }
            SettingRow(tr("Brani in cache"), formatBytes(cache)) {
                PillButton(tr("Svuota")) {
                    SongCache.clear()
                    cache = SongCache.bytes
                }
            }
        }

        SectionHeader(tr("Aggiornamenti"))
        Group {
            Toggle(tr("Aggiornamenti automatici"), tr("Seaglass cerca una nuova versione ogni ora e la installa al riavvio."), autoUpdate) { Prefs.autoUpdate.value = it }
            SettingRow(
                tr("Versione %@", BuildConfig.VERSION),
                when (val current = update) {
                    AppUpdater.State.Idle -> null
                    AppUpdater.State.Checking -> tr("Ricerca in corso…")
                    AppUpdater.State.UpToDate -> tr("Seaglass è aggiornato.")
                    is AppUpdater.State.Downloading -> tr("Download della versione %@…", current.version)
                    is AppUpdater.State.Ready -> tr("La versione %@ è pronta.", current.version)
                    is AppUpdater.State.Failed -> current.message
                },
            ) {
                when (val current = update) {
                    is AppUpdater.State.Ready -> PillButton(tr("Riavvia e aggiorna"), prominent = true) {
                        if (AppUpdater.installNow()) WindowsIntegration.quit()
                    }
                    is AppUpdater.State.Downloading -> LinearProgressIndicator(progress = { current.progress }, Modifier.width(140.dp))
                    else -> PillButton(tr("Cerca aggiornamenti")) { AppUpdater.check() }
                }
            }
        }

        SectionHeader(tr("Informazioni"))
        Group {
            SettingRow("Seaglass ${BuildConfig.VERSION}", tr("Seaglass non è un'app ufficiale e non è affiliata a YouTube o Google."))
            // What the app noted (songs that couldn't play, AutoMix's choices), to send when something goes wrong.
            SettingRow(tr("Registro dell'app"), tr("Se qualcosa non va, invia questo file insieme a uno screenshot.")) {
                PillButton(tr("Apri cartella")) {
                    runCatching { java.awt.Desktop.getDesktop().open(com.onda.seaglass.core.Log.file.parentFile) }
                }
            }
        }
    }
}

private fun languageName(code: String): String {
    val locale = java.util.Locale.forLanguageTag(if (code == "zh-Hans") "zh-CN" else code)
    return locale.getDisplayLanguage(locale).replaceFirstChar { it.uppercase() }
}

/** The equalizer, in Settings as on the iPhone: on or off, the curve, the six bands and Spotify's presets. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun EqualizerSection() {
    val palette = LocalPalette.current
    val state by Equalizer.state.collectAsState()
    Column(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
        Toggle(tr("Equalizzatore"), if (state.isOn) state.preset.title else tr("Disattivato"), state.isOn) { Equalizer.setOn(it) }
        val gains = state.gains
        // As Spotify's: the six bands as points on a curve, each dragged up or down (or clicked
        // where it should go); the gain over the point while it moves.
        var dragging by remember { mutableStateOf<Int?>(null) }
        val line = if (state.isOn) palette.accent else palette.tertiary
        BoxWithConstraints(Modifier.fillMaxWidth().height(200.dp).padding(top = 8.dp).clip(RoundedCornerShape(8.dp)).background(palette.page)) {
            val bandAt = { x: Float, width: Float -> ((x / width) * EqualizerBands.COUNT).toInt().coerceIn(0, EqualizerBands.COUNT - 1) }
            fun gainAt(y: Float, height: Float): Float {
                val zero = height / 2
                return ((zero - y) / (zero * 0.8f) * EqualizerBands.LIMIT).coerceIn(-EqualizerBands.LIMIT, EqualizerBands.LIMIT)
            }
            fun set(band: Int, gain: Float) {
                if (!Equalizer.state.value.isOn) Equalizer.setOn(true)
                // Whole half-decibels, and 0 easy to land on.
                val rounded = Math.round(gain * 2) / 2f
                Equalizer.setGain(band, if (kotlin.math.abs(rounded) < 0.5f) 0f else rounded)
            }
            Canvas(
                Modifier.fillMaxSize()
                    .pointerInput(Unit) {
                        detectTapGestures { offset -> set(bandAt(offset.x, size.width.toFloat()), gainAt(offset.y, size.height.toFloat())) }
                    }
                    .pointerInput(Unit) {
                        detectDragGestures(
                            onDragStart = { offset -> dragging = bandAt(offset.x, size.width.toFloat()) },
                            onDragEnd = { dragging = null },
                            onDragCancel = { dragging = null },
                        ) { change, _ ->
                            dragging?.let { band -> set(band, gainAt(change.position.y, size.height.toFloat())) }
                            change.consume()
                        }
                    },
            ) {
                val zero = size.height / 2
                val step = size.width / EqualizerBands.COUNT
                val points = (0 until EqualizerBands.COUNT).map { band ->
                    Offset(step * (band + 0.5f), zero - gains[band] / EqualizerBands.LIMIT * zero * 0.8f)
                }
                // The grid: 0 dB across, and each band's line.
                drawLine(palette.separator, Offset(0f, zero), Offset(size.width, zero), strokeWidth = 1.5f)
                points.forEach { drawLine(palette.separator, Offset(it.x, 12f), Offset(it.x, size.height - 12f)) }
                // A smooth line through the points, the space under it filled.
                val curve = Path()
                curve.moveTo(0f, points.first().y)
                curve.lineTo(points.first().x, points.first().y)
                for (i in 1 until points.size) {
                    val a = points[i - 1]
                    val b = points[i]
                    val middle = (a.x + b.x) / 2
                    curve.cubicTo(middle, a.y, middle, b.y, b.x, b.y)
                }
                curve.lineTo(size.width, points.last().y)
                val fill = Path().apply {
                    addPath(curve)
                    lineTo(size.width, size.height)
                    lineTo(0f, size.height)
                    close()
                }
                drawPath(fill, Brush.verticalGradient(listOf(line.copy(alpha = 0.35f), line.copy(alpha = 0.02f))))
                drawPath(curve, line, style = Stroke(width = 3f))
                points.forEachIndexed { band, point ->
                    drawCircle(Color.White, radius = if (dragging == band) 10f else 7f, center = point)
                    drawCircle(line, radius = if (dragging == band) 10f else 7f, center = point, style = Stroke(width = 2f))
                }
            }
            // The gains over the points, the frequencies under them.
            Row(Modifier.fillMaxWidth().align(Alignment.BottomCenter).padding(bottom = 4.dp)) {
                for (band in 0 until EqualizerBands.COUNT) {
                    Text(EqualizerBands.labels[band] + " Hz", color = palette.secondary, fontSize = 11.sp, maxLines = 1,
                        textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
                }
            }
            Row(Modifier.fillMaxWidth().align(Alignment.TopCenter).padding(top = 4.dp)) {
                for (band in 0 until EqualizerBands.COUNT) {
                    Text("%+.1f dB".format(gains[band]), color = if (dragging == band) palette.text else palette.tertiary, fontSize = 11.sp, maxLines = 1,
                        textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
                }
            }
        }
        Text(tr("Preimpostazioni"), color = palette.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 16.dp, bottom = 8.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            EqualizerPreset.entries.filter { it != EqualizerPreset.CUSTOM || Equalizer.state.value.custom.any { gain -> gain != 0f } }.forEach { preset ->
                val selected = state.isOn && state.preset == preset
                Text(
                    preset.title,
                    color = if (selected) palette.onAccent else palette.text,
                    fontSize = 13.sp,
                    modifier = Modifier.clip(RoundedCornerShape(50)).background(if (selected) palette.accent else palette.cardHover)
                        .clickable { Equalizer.select(preset) }.padding(horizontal = 14.dp, vertical = 8.dp),
                )
            }
        }
    }
}

@Composable
fun AccountPage() {
    val palette = LocalPalette.current
    val signedIn by Account.signedIn.collectAsState()
    val details by Account.details.collectAsState()
    val sync by Account.sync.collectAsState()
    val lastSync by Account.lastSync.collectAsState()
    val error by Account.error.collectAsState()
    val waiting by Account.waiting.collectAsState()
    Page {
        Text(tr("Account Seaglass"), fontSize = 34.sp, fontWeight = FontWeight.Bold, color = palette.text)
        if (!signedIn) {
            Text(
                tr("Con un account la libreria (brani preferiti, playlist e cronologia) è la stessa su iPhone, iPad, Mac e Windows."),
                color = palette.secondary, fontSize = 14.sp, modifier = Modifier.padding(vertical = 14.dp),
            )
            PillButton(tr("Accedi o crea un account"), prominent = true) { Account.signIn() }
            if (waiting) Text(tr("Completa l'accesso nel browser: Seaglass si aggiorna da solo."), color = palette.secondary, fontSize = 13.sp, modifier = Modifier.padding(top = 12.dp))
            error?.let { Text(it, color = Color(0xFFFF6B6B), fontSize = 13.sp, modifier = Modifier.padding(top = 12.dp)) }
            return@Page
        }
        Group {
            SettingRow(details?.name ?: details?.email ?: "", details?.email)
            SettingRow(tr("Piano"), if (details?.premium == true) "Seaglass Premium" else tr("Gratuito"))
            SettingRow(
                tr("Sincronizzazione"),
                when (val current = sync) {
                    Account.Sync.Syncing -> tr("Sincronizzazione in corso…")
                    is Account.Sync.Failed -> current.message
                    Account.Sync.Idle -> lastSync?.let {
                        tr("Ultima sincronizzazione: %@", java.time.Instant.ofEpochMilli(it).atZone(java.time.ZoneId.systemDefault())
                            .format(java.time.format.DateTimeFormatter.ofLocalizedDateTime(java.time.format.FormatStyle.SHORT).withLocale(L10n.locale)))
                    }
                },
            ) { PillButton(tr("Sincronizza ora")) { Account.syncNow() } }
        }
        Row(Modifier.padding(top = 18.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PillButton(tr("Gestisci account")) { Account.openAccountPage() }
            PillButton(tr("Esci")) { Account.signOut() }
        }
    }
}

/** Last.fm, as on the iPhone: the user's own API key, then the account authorised in the browser. */
@Composable
private fun LastFMSettings() {
    val palette = LocalPalette.current
    val username by com.onda.seaglass.data.LastFM.username.collectAsState()
    val pending by com.onda.seaglass.data.LastFM.pending.collectAsState()
    val scrobbling by com.onda.seaglass.data.LastFM.scrobbling.state.collectAsState()
    val scope = rememberCoroutineScope()
    var editing by remember { mutableStateOf(!com.onda.seaglass.data.LastFM.hasCredentials) }
    var key by remember { mutableStateOf(com.onda.seaglass.data.LastFM.apiKey) }
    var secret by remember { mutableStateOf("") }
    var waiting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    if (username != null) {
        SettingRow(tr("Account"), username)
        Toggle(tr("Scrobbling"), tr("Serve una API key gratuita di Last.fm. Un brano viene registrato dopo metà ascolto o 4 minuti."), scrobbling) {
            com.onda.seaglass.data.LastFM.scrobbling.value = it
        }
        if (pending > 0) SettingRow(tr("Scrobble in attesa"), pending.toString())
        SettingRow(tr("Disconnetti"), onClick = { com.onda.seaglass.data.LastFM.signOut() })
        return
    }
    if (editing) {
        androidx.compose.material3.OutlinedTextField(key, { key = it }, label = { Text(tr("API key")) }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
        androidx.compose.material3.OutlinedTextField(
            secret, { secret = it }, label = { Text(tr("Shared secret")) }, singleLine = true,
            visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
        )
        Row(Modifier.padding(vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PillButton(tr("Salva chiavi"), prominent = true) {
                if (key.isNotBlank() && secret.isNotBlank()) {
                    com.onda.seaglass.data.LastFM.saveCredentials(key, secret)
                    secret = ""
                    editing = false
                }
            }
            PillButton(tr("Crea una API key su last.fm")) { runCatching { java.awt.Desktop.getDesktop().browse(java.net.URI("https://www.last.fm/api/account/create")) } }
        }
        return
    }
    SettingRow(tr("Connetti account Last.fm"), if (waiting) tr("Consenti l'accesso a Seaglass nella pagina di Last.fm aperta nel browser, poi torna qui e fai clic su OK.") else error, onClick = {
        error = null
        scope.launch {
            runCatching { com.onda.seaglass.data.LastFM.beginAuth() }
                .onSuccess { url ->
                    runCatching { java.awt.Desktop.getDesktop().browse(java.net.URI(url)) }
                    waiting = true
                }
                .onFailure { error = it.message }
        }
    }) {
        if (waiting) PillButton(tr("OK"), prominent = true) {
            scope.launch {
                runCatching { com.onda.seaglass.data.LastFM.completeAuth() }.onFailure { error = it.message }
                waiting = false
            }
        }
    }
    SettingRow(tr("Modifica chiavi API"), onClick = { editing = true })
}
