package com.onda.seaglass.ui

import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.onda.seaglass.data.Prefs

val Background = Color(0xFF0B0B10)
val Secondary = Color(0xFFA1A1AA)

val LocalAccent = staticCompositionLocalOf { Color(1f, 0.31f, 0.6f) }

/** Dark like the iPhone app's player, with the user's theme colour. */
@Composable
fun SeaglassTheme(content: @Composable () -> Unit) {
    val accent by Prefs.accent.collectAsStateWithLifecycle()
    val color = accent.color
    val scheme = darkColorScheme(
        primary = color,
        onPrimary = Color.White,
        secondary = color,
        background = Background,
        surface = Color(0xFF16161D),
        surfaceContainer = Color(0xFF1C1C24),
        surfaceContainerHigh = Color(0xFF23232C),
        surfaceContainerHighest = Color(0xFF2A2A34),
        surfaceContainerLow = Color(0xFF131319),
        onSurface = Color.White,
        onSurfaceVariant = Secondary,
        outline = Color(0x33FFFFFF),
        outlineVariant = Color(0x1FFFFFFF),
    )
    val base = Typography()
    val typography = base.copy(
        displaySmall = base.displaySmall.copy(fontWeight = FontWeight.Bold, fontSize = 34.sp, letterSpacing = (-0.5).sp),
        headlineSmall = base.headlineSmall.copy(fontWeight = FontWeight.Bold, fontSize = 22.sp),
        titleLarge = base.titleLarge.copy(fontWeight = FontWeight.Bold),
        titleMedium = base.titleMedium.copy(fontWeight = FontWeight.SemiBold),
    )
    MaterialTheme(colorScheme = scheme, typography = typography) {
        // Text is white unless it says otherwise (there's no Surface to set it).
        CompositionLocalProvider(LocalAccent provides color, LocalContentColor provides Color.White, content = content)
    }
}

val SectionTitle = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Color.White)
