package com.onda.seaglass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.chrisbanes.haze.HazeInput
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.glass.GlassStyle
import dev.chrisbanes.haze.glass.hazeGlass

/** The content behind the floating bars: what their glass refracts. */
val LocalHazeState = staticCompositionLocalOf<HazeState?> { null }

/**
 * Liquid glass, as on the iPhone: the content behind refracts and blurs through the material, with
 * a light rim. Android 13 and later draw the full material (refraction, specular light); Android 12
 * gets the frosted blur; older versions a translucent fill.
 */
@Composable
fun Modifier.glass(
    corner: Dp = 28.dp,
    tint: Color = Color.White.copy(alpha = 0.04f),
    clear: Boolean = false,
    state: HazeState? = LocalHazeState.current,
): Modifier {
    val shape = remember(corner) { RoundedCornerShape(corner) }
    val style = remember(corner, tint, clear) {
        (if (clear) GlassStyle.clear else GlassStyle.regular).then {
            shape(RoundedCornerShape(corner))
            tint(tint)
            backgroundColor(Color(0x33101016))
        }
    }
    val material = if (state != null) hazeGlass(input = HazeInput.Sources(state), style = style)
    else background(Color(0xCC1C1C24), shape)
    return this
        .then(material)
        .clip(shape)
        .border(
            width = 0.5.dp,
            brush = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.28f), Color.White.copy(alpha = 0.06f))),
            shape = shape,
        )
}

/** A glass surface holding [content]. */
@Composable
fun GlassSurface(
    modifier: Modifier = Modifier,
    corner: Dp = 28.dp,
    tint: Color = Color.White.copy(alpha = 0.04f),
    clear: Boolean = false,
    state: HazeState? = LocalHazeState.current,
    content: @Composable BoxScope.() -> Unit,
) {
    Box(modifier.glass(corner, tint, clear, state), content = content)
}
