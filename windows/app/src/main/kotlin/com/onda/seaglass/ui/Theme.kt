package com.onda.seaglass.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import com.onda.seaglass.core.L10n
import com.onda.seaglass.core.Prefs

/** The accent colours of Settings → Aspetto, as on the iPhone. */
enum class Accent(val key: String, val color: Color) {
    PINK("pink", Color(0xFFEC3F8E)),
    BLUE("blue", Color(0xFF0A84FF)),
    PURPLE("purple", Color(0xFFAF52DE)),
    ORANGE("orange", Color(0xFFFF9500)),
    GREEN("green", Color(0xFF30D158)),
    RED("red", Color(0xFFFF453A)),
    TEAL("teal", Color(0xFF40C8E0));

    companion object {
        fun of(key: String) = entries.firstOrNull { it.key == key } ?: PINK
    }
}

/** Colours beyond Material's: the window's layers, as the Mac app's sidebar, page and player bar. */
data class Palette(
    val dark: Boolean,
    val accent: Color,
    val window: Color,
    val sidebar: Color,
    val page: Color,
    val bar: Color,
    val card: Color,
    val cardHover: Color,
    val separator: Color,
    val text: Color,
    val secondary: Color,
    val tertiary: Color,
)

val LocalPalette = staticCompositionLocalOf { palette(true, Accent.PINK.color) }

fun palette(dark: Boolean, accent: Color) = if (dark) {
    Palette(
        dark = true, accent = accent,
        window = Color(0xFF101014), sidebar = Color(0xFF17171C), page = Color(0xFF121216), bar = Color(0xFF1B1B21),
        card = Color(0xFF1F1F26), cardHover = Color(0xFF2A2A33), separator = Color(0x22FFFFFF),
        text = Color(0xFFF4F4F6), secondary = Color(0xFFA9A9B3), tertiary = Color(0xFF6E6E78),
    )
} else {
    Palette(
        dark = false, accent = accent,
        window = Color(0xFFF4F4F7), sidebar = Color(0xFFEAEAEF), page = Color(0xFFFAFAFC), bar = Color(0xFFF0F0F4),
        card = Color(0xFFFFFFFF), cardHover = Color(0xFFEDEDF2), separator = Color(0x1A000000),
        text = Color(0xFF151518), secondary = Color(0xFF5F5F68), tertiary = Color(0xFF9A9AA3),
    )
}

@Composable
fun SeaglassTheme(content: @Composable () -> Unit) {
    val theme by Prefs.theme.state.collectAsState()
    val accentKey by Prefs.accent.state.collectAsState()
    val dark = when (theme) {
        "dark" -> true
        "light" -> false
        else -> isSystemInDarkTheme()
    }
    val accent = Accent.of(accentKey).color
    val colors = palette(dark, accent)
    val scheme = if (dark) {
        darkColorScheme(
            primary = accent, onPrimary = Color.White, background = colors.page, surface = colors.card,
            onBackground = colors.text, onSurface = colors.text, surfaceVariant = colors.cardHover, onSurfaceVariant = colors.secondary,
            secondary = accent, outline = colors.separator, surfaceContainer = colors.bar, surfaceContainerHigh = colors.cardHover,
        )
    } else {
        lightColorScheme(
            primary = accent, onPrimary = Color.White, background = colors.page, surface = colors.card,
            onBackground = colors.text, onSurface = colors.text, surfaceVariant = colors.cardHover, onSurfaceVariant = colors.secondary,
            secondary = accent, outline = colors.separator, surfaceContainer = colors.bar, surfaceContainerHigh = colors.cardHover,
        )
    }
    CompositionLocalProvider(
        LocalPalette provides colors,
        // Arabic reads right to left, as in the iPhone app.
        LocalLayoutDirection provides if (L10n.isRightToLeft) LayoutDirection.Rtl else LayoutDirection.Ltr,
    ) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
