package com.onda.seaglass.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.onda.seaglass.core.L10n
import com.onda.seaglass.core.tr
import com.onda.seaglass.playback.BitPerfect
import com.onda.seaglass.playback.Equalizer
import com.onda.seaglass.playback.EqualizerBands
import com.onda.seaglass.playback.EqualizerPreset
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.roundToInt

/** Settings → Audio → Equalizzatore: a page. */
@Composable
fun EqualizerScreen() {
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    Box(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = top + 52.dp, bottom = LocalBottomPadding.current)) {
            item { ScreenTitle(tr("Equalizzatore")) }
            item { EqualizerContent() }
        }
        GlassBackButton(Modifier.padding(top = top + 8.dp, start = 12.dp))
    }
}

/** The same, over the player. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EqualizerSheet(onDismiss: () -> Unit) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Color(0xF21A1A22),
    ) {
        LazyColumn(Modifier.windowInsetsPadding(WindowInsets.navigationBars).padding(bottom = 12.dp)) {
            item {
                Text(tr("Equalizzatore"), style = SectionTitle, modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp))
            }
            item { EqualizerContent() }
        }
    }
}

/**
 * Spotify's presets and a curve to drag, as on the iPhone: the switch, the curve with its six
 * points (60 Hz to 15 kHz, ±12 dB), and the presets.
 */
@Composable
fun EqualizerContent() {
    val state by Equalizer.state.collectAsStateWithLifecycle()
    val bitPerfect by BitPerfect.status.collectAsStateWithLifecycle()
    val accent = LocalAccent.current
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.07f))) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(tr("Equalizzatore"), Modifier.weight(1f), fontSize = 16.sp)
                Switch(
                    checked = state.isOn, onCheckedChange = Equalizer::setOn,
                    colors = SwitchDefaults.colors(checkedTrackColor = accent),
                )
            }
        }
        val note = if (bitPerfect is BitPerfect.Status.Active) {
            tr("Il bit-perfect invia l'audio senza modifiche: l'equalizzatore riprende quando lo spegni.")
        } else {
            tr("Vale per tutti i brani, in streaming e scaricati, anche in karaoke. Quando un preset alza delle frequenze, il volume generale scende di quanto serve perché il suono non distorca.")
        }
        Text(note, color = Secondary, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 16.dp))

        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.07f)).padding(12.dp)) {
            Column {
                Text(
                    state.preset.title, fontWeight = FontWeight.SemiBold, fontSize = 16.sp,
                    color = if (state.isOn) Color.White else Secondary,
                )
                Spacer(Modifier.height(8.dp))
                // Frequencies run left to right in every language.
                CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
                    Curve(state.gains, enabled = state.isOn)
                }
            }
        }
        Text(tr("Trascina un punto in su o in giù per creare il tuo equalizzatore."), color = Secondary, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 16.dp))

        Text(
            tr("Preset").uppercase(L10n.locale), fontSize = 13.sp, color = Secondary, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(start = 16.dp, top = 8.dp),
        )
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.07f))) {
            // "Personalizzato" once there is a curve of your own to go back to.
            val presets = EqualizerPreset.entries.filter { it != EqualizerPreset.CUSTOM || Equalizer.hasCustom || state.preset == it }
            presets.forEachIndexed { index, preset ->
                if (index > 0) HorizontalDivider(Modifier.padding(start = 16.dp), color = Color.White.copy(alpha = 0.08f))
                Row(
                    Modifier.fillMaxWidth().clickable { Equalizer.select(preset) }.padding(horizontal = 16.dp, vertical = 13.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(preset.title, Modifier.weight(1f), fontSize = 16.sp)
                    if (state.isOn && state.preset == preset) Icon(Icons.Rounded.Check, null, tint = accent)
                }
            }
        }
    }
}

/** The curve the six bands make (the filters' real response), with a point to drag on each band. */
@Composable
private fun Curve(gains: FloatArray, enabled: Boolean) {
    val accent = LocalAccent.current
    var active by remember { mutableIntStateOf(-1) }
    var size by remember { mutableStateOf(androidx.compose.ui.geometry.Size.Zero) }
    val limit = EqualizerBands.LIMIT
    val minLog = log10(30.0)
    val maxLog = log10(18_000.0)
    fun x(frequency: Double, width: Float) = ((log10(frequency) - minLog) / (maxLog - minLog) * width).toFloat()
    fun y(decibels: Double, height: Float) = (height / 2 - decibels / limit * (height / 2 - 12)).toFloat()
    fun gainAt(yPosition: Float, height: Float) = ((height / 2 - yPosition) / (height / 2 - 12) * limit)

    Column {
        Canvas(
            Modifier
                .fillMaxWidth()
                .height(190.dp)
                .pointerInput(Unit) {
                    detectDragGestures(
                        onDragStart = { start ->
                            // The nearest point to where the finger lands.
                            active = EqualizerBands.frequencies.indices.minByOrNull { abs(x(EqualizerBands.frequencies[it], size.width) - start.x) } ?: -1
                        },
                        onDragEnd = { active = -1 },
                        onDragCancel = { active = -1 },
                    ) { change, _ ->
                        change.consume()
                        if (active >= 0) Equalizer.setGain(active, gainAt(change.position.y, size.height))
                    }
                },
        ) {
            size = this.size
            val w = this.size.width
            val h = this.size.height
            val faint = Color.White.copy(alpha = 0.10f)
            // 0 dB and ±6 dB lines.
            for (db in listOf(-6.0, 0.0, 6.0)) {
                drawLine(if (db == 0.0) Color.White.copy(alpha = 0.22f) else faint, Offset(0f, y(db, h)), Offset(w, y(db, h)), strokeWidth = 1.dp.toPx())
            }
            for (frequency in EqualizerBands.frequencies) {
                drawLine(faint, Offset(x(frequency, w), 0f), Offset(x(frequency, w), h), strokeWidth = 1.dp.toPx())
            }
            val color = if (enabled) accent else Color.White.copy(alpha = 0.35f)
            val path = Path()
            val steps = 120
            for (i in 0..steps) {
                val frequency = 10.0.pow(minLog + (maxLog - minLog) * i / steps)
                val response = Equalizer.response(gains, frequency).coerceIn(-limit.toDouble(), limit.toDouble())
                val px = x(frequency, w)
                val py = y(response, h)
                if (i == 0) path.moveTo(px, py) else path.lineTo(px, py)
            }
            val fill = Path().apply {
                addPath(path)
                lineTo(w, h)
                lineTo(0f, h)
                close()
            }
            drawPath(fill, Brush.verticalGradient(listOf(color.copy(alpha = 0.28f), Color.Transparent)))
            drawPath(path, color, style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round))
            EqualizerBands.frequencies.forEachIndexed { band, frequency ->
                val center = Offset(x(frequency, w), y(gains[band].toDouble(), h))
                drawCircle(Color.White, radius = if (band == active) 10.dp.toPx() else 7.dp.toPx(), center = center)
                drawCircle(color, radius = if (band == active) 6.dp.toPx() else 4.dp.toPx(), center = center)
            }
        }
        // The bands, and while dragging the value of the one held.
        Box(Modifier.fillMaxWidth().height(20.dp)) {
            EqualizerBands.labels.forEachIndexed { band, label ->
                val fraction = ((log10(EqualizerBands.frequencies[band]) - minLog) / (maxLog - minLog)).toFloat()
                val text = if (band == active) {
                    val value = gains[band]
                    (if (value > 0) "+" else "") + (if (value % 1f == 0f) value.roundToInt().toString() else "%.1f".format(value)) + " dB"
                } else {
                    label
                }
                Text(
                    text, fontSize = 11.sp, color = if (band == active) accent else Secondary,
                    modifier = Modifier.align(androidx.compose.ui.BiasAlignment(fraction * 2 - 1, 0f)).width(52.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
    }
}
