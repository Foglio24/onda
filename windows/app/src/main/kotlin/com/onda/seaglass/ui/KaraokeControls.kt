package com.onda.seaglass.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.Box
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.MicOff
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.RecordVoiceOver
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.onda.seaglass.account.Account
import com.onda.seaglass.audio.karaoke.Karaoke
import com.onda.seaglass.audio.karaoke.KaraokeMode
import com.onda.seaglass.audio.karaoke.KaraokeStatus
import com.onda.seaglass.core.tr
import kotlin.math.roundToInt

val KaraokeMode.title: String
    get() = when (this) {
        KaraokeMode.OFF -> tr("Normale")
        KaraokeMode.NO_VOCALS -> tr("Senza voce")
        KaraokeMode.VOCALS_ONLY -> tr("Solo voce")
    }

private val KaraokeMode.icon: ImageVector
    get() = when (this) {
        KaraokeMode.OFF -> Icons.Rounded.MusicNote
        KaraokeMode.NO_VOCALS -> Icons.Rounded.MicOff
        KaraokeMode.VOCALS_ONLY -> Icons.Rounded.RecordVoiceOver
    }

/** The player's karaoke button: the voice taken away or kept alone, at three strengths (as on the iPhone). */
@Composable
fun KaraokeButton(light: Boolean = false, size: Int = 20) {
    val palette = LocalPalette.current
    val mode by Karaoke.mode.collectAsState()
    val amount by Karaoke.amount.collectAsState()
    val status by Karaoke.status.collectAsState()
    var open by remember { mutableStateOf(false) }
    Box {
        // Karaoke is a Premium feature, as on the iPhone.
        BarButton(if (mode == KaraokeMode.OFF) Icons.Rounded.Mic else mode.icon, tr("Karaoke AI"), active = mode != KaraokeMode.OFF, size = size, light = light) {
            if (Account.unlocks()) open = true else Nav.premium = tr("Karaoke AI")
        }
        DropdownMenu(open, { open = false }, modifier = Modifier.widthIn(min = 240.dp)) {
            Column {
                Text(tr("Karaoke AI"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = palette.secondary, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
                if (mode != KaraokeMode.OFF) {
                    val text = statusText(status)
                    if (text.isNotEmpty()) Text(text, fontSize = 12.sp, color = palette.secondary, modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp).widthIn(max = 260.dp))
                }
                for (choice in KaraokeMode.entries) {
                    DropdownMenuItem(
                        text = { Text(choice.title) },
                        leadingIcon = { Icon(choice.icon, null) },
                        trailingIcon = { if (choice == mode) Icon(Icons.Rounded.Check, null, tint = palette.accent) },
                        onClick = {
                            Karaoke.setMode(choice)
                            open = false
                        },
                    )
                }
                if (mode != KaraokeMode.OFF) {
                    HorizontalDivider()
                    Text(tr("Intensità"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = palette.secondary, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
                    for ((label, value) in listOf(tr("Leggera") to 0.5f, tr("Media") to 0.75f, tr("Piena") to 1f)) {
                        DropdownMenuItem(
                            text = { Text(label) },
                            trailingIcon = { if (value == amount) Icon(Icons.Rounded.Check, null, tint = palette.accent) },
                            onClick = {
                                Karaoke.setAmount(value)
                                open = false
                            },
                        )
                    }
                }
            }
        }
    }
}

private fun percent(value: Double) = "${(value * 100).roundToInt()}%"

/** How the karaoke is going ("Karaoke: preparazione 35% · 12 s"); empty when it plays. */
fun statusText(status: KaraokeStatus): String = when (status) {
    is KaraokeStatus.Downloading -> tr("Karaoke: download del modello %@", percent(status.progress))
    is KaraokeStatus.Preparing -> {
        if (status.progress <= 0 && status.remaining == null) {
            tr("Karaoke: preparazione…")
        } else {
            val text = tr("Karaoke: preparazione %@", percent(status.progress))
            val remaining = status.remaining
            when {
                remaining == null -> text
                remaining < 60 -> "$text · ${maxOf(1, remaining.toInt())} s"
                else -> "$text · ${(remaining / 60).roundToInt()} min"
            }
        }
    }
    is KaraokeStatus.Failed -> status.message
    else -> ""
}
