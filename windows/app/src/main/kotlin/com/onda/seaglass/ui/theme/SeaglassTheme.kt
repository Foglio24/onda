package com.onda.seaglass.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Panel = Color(0xFF121212)
private val Surface = Color(0xFF1A1A1A)
private val Accent = Color(0xFF1DB954)
private val OnDark = Color(0xFFE8E8E8)
private val Muted = Color(0xFFB3B3B3)

private val scheme = darkColorScheme(
    primary = Accent,
    onPrimary = Color.Black,
    background = Panel,
    onBackground = OnDark,
    surface = Surface,
    onSurface = OnDark,
    onSurfaceVariant = Muted,
    secondary = Muted,
)

@Composable
fun SeaglassTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme, content = content)
}
