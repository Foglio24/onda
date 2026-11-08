package com.onda.seaglass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.MicOff
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.RecordVoiceOver
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.onda.seaglass.core.tr
import com.onda.seaglass.playback.karaoke.Karaoke
import com.onda.seaglass.playback.karaoke.KaraokeMode
import com.onda.seaglass.playback.karaoke.KaraokeStatus
import kotlin.math.roundToInt

private val KaraokeMode.icon: ImageVector
    get() = when (this) {
        KaraokeMode.OFF -> Icons.Rounded.MusicNote
        KaraokeMode.NO_VOCALS -> Icons.Rounded.MicOff
        KaraokeMode.VOCALS_ONLY -> Icons.Rounded.RecordVoiceOver
    }

/** The player's karaoke button: the voice taken away or kept alone, at three strengths (as on the iPhone). */
@Composable
fun KaraokeButton() {
    val mode by Karaoke.mode.collectAsStateWithLifecycle()
    val amount by Karaoke.amount.collectAsStateWithLifecycle()
    val status by Karaoke.status.collectAsStateWithLifecycle()
    var open by remember { mutableStateOf(false) }
    val accent = LocalAccent.current
    Box {
        Box(
            Modifier
                .size(48.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = if (mode != KaraokeMode.OFF) 0.18f else 0f))
                .clickable { open = true },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (mode == KaraokeMode.OFF) Icons.Rounded.Mic else mode.icon, tr("Karaoke AI"),
                tint = if (mode != KaraokeMode.OFF) accent else Color.White, modifier = Modifier.size(24.dp),
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, modifier = Modifier.widthIn(min = 220.dp)) {
            Text(tr("Karaoke AI"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.6f),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
            (status as? KaraokeStatus.Failed)?.let {
                Text(it.message, fontSize = 13.sp, color = Color.White.copy(alpha = 0.8f), modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
            }
            for (choice in KaraokeMode.entries) {
                DropdownMenuItem(
                    text = { Text(choice.title) },
                    leadingIcon = { Icon(choice.icon, null) },
                    trailingIcon = { if (choice == mode) Icon(Icons.Rounded.Check, null, tint = accent) },
                    onClick = {
                        Karaoke.setMode(choice)
                        open = false
                    },
                )
            }
            if (mode != KaraokeMode.OFF) {
                HorizontalDivider()
                Text(tr("Intensità"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.6f),
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
                for ((label, value) in listOf(tr("Leggera") to 0.5f, tr("Media") to 0.75f, tr("Piena") to 1f)) {
                    DropdownMenuItem(
                        text = { Text(label) },
                        trailingIcon = { if (value == amount) Icon(Icons.Rounded.Check, null, tint = accent) },
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

/** While karaoke is on: how it's going ("Karaoke: preparazione 35% · 12 s"), or what it plays. */
@Composable
fun KaraokeBadge(modifier: Modifier = Modifier) {
    val mode by Karaoke.mode.collectAsStateWithLifecycle()
    val status by Karaoke.status.collectAsStateWithLifecycle()
    if (mode == KaraokeMode.OFF) return
    GlassSurface(modifier, corner = 14.dp, tint = Color.Black.copy(alpha = 0.15f)) {
        Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            when (val current = status) {
                is KaraokeStatus.Downloading, is KaraokeStatus.Preparing -> {
                    CircularProgressIndicator(Modifier.size(12.dp), color = Color.White, strokeWidth = 1.5.dp)
                    Spacer(Modifier.width(8.dp))
                    Text(progressText(current), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
                is KaraokeStatus.Failed -> {
                    Icon(Icons.Rounded.WarningAmber, null, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(tr("Karaoke non riuscito"), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
                else -> {
                    Icon(mode.icon, null, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(mode.title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

private fun percent(value: Double) = "${(value * 100).roundToInt()}%"

private fun progressText(status: KaraokeStatus): String = when (status) {
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
    else -> ""
}
