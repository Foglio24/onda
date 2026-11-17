package com.onda.seaglass.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import java.util.concurrent.atomic.AtomicInteger

/**
 * Whether a text field has the focus, for the keys that act on the player (the space bar): while
 * someone is typing, a space is a space. Every text field in the app wears [typing].
 */
object Typing {
    private val fields = AtomicInteger(0)
    val active: Boolean get() = fields.get() > 0
    internal fun enter() = fields.incrementAndGet()
    internal fun leave() = fields.updateAndGet { maxOf(0, it - 1) }
}

/** Marks a text field: while it has the focus, [Typing.active] is true (also if it leaves the screen focused). */
@Composable
fun Modifier.typing(): Modifier {
    var focused by remember { mutableStateOf(false) }
    // The value as it is for this effect (the delegate reads the live state, which has changed by the time it is disposed).
    val hasFocus = focused
    DisposableEffect(hasFocus) {
        if (hasFocus) Typing.enter()
        onDispose { if (hasFocus) Typing.leave() }
    }
    return this.onFocusChanged { focused = it.isFocused }
}

/**
 * The space bar plays and pauses, unless a text field has the focus (a space is a space there). Meant
 * for a preview key handler, which sees the key before whatever has the focus (a focused button
 * would take it as a click). Once per press: holding it down repeats the key, and the release is
 * taken too. True when the event was the space bar's and is used.
 */
object SpaceBar {
    private var held = false

    fun handle(event: KeyEvent, toggle: () -> Unit): Boolean {
        if (event.key != Key.Spacebar || event.isCtrlPressed || event.isAltPressed || event.isMetaPressed || Typing.active) return false
        when (event.type) {
            KeyEventType.KeyDown -> {
                if (!held) toggle()
                held = true
            }
            KeyEventType.KeyUp -> held = false
            else -> {}
        }
        return true
    }
}
