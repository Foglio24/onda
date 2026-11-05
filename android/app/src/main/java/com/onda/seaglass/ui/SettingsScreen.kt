package com.onda.seaglass.ui

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.onda.seaglass.BuildConfig
import com.onda.seaglass.core.L10n
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Accent
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.Prefs
import com.onda.seaglass.data.Updates
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val app = LocalApp.current
    val accent by Prefs.accent.collectAsStateWithLifecycle()
    val artworkColors by Prefs.artworkColors.collectAsStateWithLifecycle()
    val autoRadio by Prefs.autoRadio.collectAsStateWithLifecycle()
    val skipLongMixes by Prefs.skipLongMixes.collectAsStateWithLifecycle()
    val dataSaver by Prefs.dataSaverFlow.collectAsStateWithLifecycle()
    var update by remember { mutableStateOf<String?>(null) }
    var release by remember { mutableStateOf<Updates.Release?>(null) }
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()

    fun open(url: String) = context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(top = top, bottom = LocalBottomPadding.current),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item { ScreenTitle(tr("Impostazioni")) }
        item {
            Group(tr("Aspetto")) {
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
                ToggleRow(tr("Colori dalla copertina"), artworkColors, Prefs::setArtworkColors)
                Divider()
                ValueRow(tr("Lingua"), L10n.locale.getDisplayLanguage(L10n.locale).replaceFirstChar { it.titlecase(L10n.locale) }) {
                    // Android 13 and later choose the app's language in the system settings.
                    val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        Intent(Settings.ACTION_APP_LOCALE_SETTINGS, Uri.fromParts("package", context.packageName, null))
                    } else {
                        Intent(Settings.ACTION_LOCALE_SETTINGS)
                    }
                    runCatching { context.startActivity(intent) }
                }
            }
        }
        item {
            Group(tr("Riproduzione"), footer = tr("Quando la coda finisce, continua con brani simili.")) {
                ToggleRow(tr("Radio automatica"), autoRadio, Prefs::setAutoRadio)
                Divider()
                ToggleRow(tr("Salta le compilation lunghe"), skipLongMixes, Prefs::setSkipLongMixes)
            }
        }
        item {
            Group(tr("Qualità"), footer = tr("«Massima» usa Opus a 160 kbps, la qualità più alta di YouTube senza Premium.")) {
                ChoiceRow(tr("Massima · Opus 160 kbps"), !dataSaver) { Prefs.setDataSaver(false) }
                Divider()
                ChoiceRow(tr("Risparmio · AAC 48 kbps"), dataSaver) { Prefs.setDataSaver(true) }
            }
        }
        item {
            Group(tr("Spazio")) {
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
        }
        item {
            Group(tr("Aggiornamenti")) {
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
                    ValueRow(tr("Seaglass %@", newer.version), tr("Scarica")) { open(newer.apkUrl ?: newer.pageUrl) }
                    if (newer.notes.isNotBlank()) {
                        Text(newer.notes, color = Secondary, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                    }
                }
            }
        }
        item {
            Group(tr("Informazioni")) {
                ValueRow(tr("Versione"), BuildConfig.VERSION_NAME) {}
                Divider()
                ValueRow(tr("Codice sorgente su GitHub"), "") { open("https://github.com/Foglio24/onda") }
            }
        }
    }
}

@Composable
private fun Group(title: String, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp)) {
        Text(
            title.uppercase(L10n.locale), fontSize = 13.sp, color = Secondary, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(start = 16.dp, bottom = 6.dp, top = 8.dp),
        )
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.07f)), content = content)
        if (footer != null) {
            Text(footer, fontSize = 13.sp, color = Secondary, modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp))
        }
    }
}

@Composable
private fun Divider() = HorizontalDivider(Modifier.padding(start = 16.dp), color = Color.White.copy(alpha = 0.08f))

@Composable
private fun ToggleRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable { onChange(!checked) }.padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f), fontSize = 16.sp)
        Switch(checked = checked, onCheckedChange = onChange, colors = SwitchDefaults.colors(checkedTrackColor = LocalAccent.current))
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
private fun ValueRow(title: String, value: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 15.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f), fontSize = 16.sp)
        if (value.isNotEmpty()) {
            Spacer(Modifier.width(8.dp))
            Text(value, color = Secondary, fontSize = 15.sp)
        }
    }
}
