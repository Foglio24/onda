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
import com.onda.seaglass.update.AppUpdater
import com.onda.seaglass.WindowsIntegration
import kotlin.math.log10

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
                        ) { if (option.key == accent) Icon(Icons.Rounded.Check, null, Modifier.size(14.dp), tint = Color.White) }
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
            Choice(tr("Passaggio tra i brani"), transition, listOf("none" to tr("Senza pause"), "crossfade" to tr("Dissolvenza incrociata"))) { Prefs.transition.value = it }
            if (transition == "crossfade") {
                SettingRow(tr("Dissolvenza incrociata: %lld s", crossfade.toInt())) {
                    Slider(
                        crossfade.toFloat(), { Prefs.crossfadeSeconds.value = it.toDouble() }, valueRange = 1f..12f, steps = 10,
                        modifier = Modifier.width(220.dp), colors = SliderDefaults.colors(thumbColor = palette.accent, activeTrackColor = palette.accent),
                    )
                }
            }
            Choice(tr("Uscita audio"), device, listOf<Pair<String?, String>>(null to tr("Predefinita di Windows")) + JavaSoundSink.devices().map { it to it }) {
                Prefs.outputDevice.value = it
                Player.engine.reopenOutput()
            }
            SettingRow(tr("Equalizzatore"), if (Equalizer.state.value.isOn) Equalizer.state.value.preset.title else tr("Disattivato"), onClick = { Nav.open(Route.Equalizer) })
        }

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
        }
    }
}

private fun languageName(code: String): String {
    val locale = java.util.Locale.forLanguageTag(if (code == "zh-Hans") "zh-CN" else code)
    return locale.getDisplayLanguage(locale).replaceFirstChar { it.uppercase() }
}

/** The equalizer, as on the iPhone: the curve, the six bands and Spotify's presets. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun EqualizerPage() {
    val palette = LocalPalette.current
    val state by Equalizer.state.collectAsState()
    Page {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(tr("Equalizzatore"), fontSize = 34.sp, fontWeight = FontWeight.Bold, color = palette.text, modifier = Modifier.weight(1f))
            Switch(state.isOn, { Equalizer.setOn(it) }, colors = SwitchDefaults.colors(checkedTrackColor = palette.accent))
        }
        val gains = state.gains
        // The curve: the whole equalizer's response from 20 Hz to 20 kHz.
        Canvas(Modifier.fillMaxWidth().height(180.dp).padding(top = 16.dp).clip(RoundedCornerShape(10.dp)).background(palette.card)) {
            val zero = size.height / 2
            drawLine(palette.separator, Offset(0f, zero), Offset(size.width, zero))
            val path = Path()
            val steps = 200
            for (i in 0..steps) {
                val frequency = 20.0 * Math.pow(1000.0, i / steps.toDouble())
                val db = Equalizer.response(gains, frequency).coerceIn(-15.0, 15.0)
                val x = (log10(frequency / 20) / 3).toFloat() * size.width
                val y = zero - (db / 15.0 * zero * 0.9).toFloat()
                if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            drawPath(path, if (state.isOn) palette.accent else palette.tertiary, style = Stroke(width = 3f))
        }
        Row(Modifier.fillMaxWidth().padding(top = 18.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
            for (band in 0 until EqualizerBands.COUNT) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("%+.1f dB".format(gains[band]), color = palette.secondary, fontSize = 11.sp)
                    Slider(
                        gains[band], { Equalizer.setGain(band, it) }, valueRange = -EqualizerBands.LIMIT..EqualizerBands.LIMIT,
                        modifier = Modifier.width(130.dp),
                        colors = SliderDefaults.colors(thumbColor = palette.accent, activeTrackColor = palette.accent),
                    )
                    Text(EqualizerBands.labels[band] + " Hz", color = palette.text, fontSize = 12.sp)
                }
            }
        }
        SectionHeader(tr("Preimpostazioni"))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            EqualizerPreset.entries.filter { it != EqualizerPreset.CUSTOM || Equalizer.state.value.custom.any { gain -> gain != 0f } }.forEach { preset ->
                val selected = state.isOn && state.preset == preset
                Text(
                    preset.title,
                    color = if (selected) Color.White else palette.text,
                    fontSize = 13.sp,
                    modifier = Modifier.clip(RoundedCornerShape(50)).background(if (selected) palette.accent else palette.card)
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
