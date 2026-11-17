package com.onda.seaglass.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.unit.dp
import kotlin.test.Test
import kotlin.test.assertEquals

/** The space bar plays and pauses, once per press, and stays a space in a text field. */
@OptIn(ExperimentalTestApi::class)
class SpaceBarTest {
    @Test
    fun spaceTogglesOncePerPressAndNotWhileTyping() = runComposeUiTest {
        var toggles = 0
        var text by mutableStateOf("")
        val page = FocusRequester()
        val field = FocusRequester()
        setContent {
            Column(Modifier.onPreviewKeyEvent { SpaceBar.handle(it) { toggles++ } }) {
                Box(Modifier.testTag("page").size(40.dp).focusRequester(page).focusable())
                OutlinedTextField(text, { text = it }, modifier = Modifier.testTag("field").focusRequester(field).typing())
            }
            LaunchedEffect(Unit) { page.requestFocus() }
        }
        // Focus on the page: a press toggles once.
        waitForIdle()
        onNodeWithTag("page").performKeyInput { pressKey(Key.Spacebar) }
        waitForIdle()
        assertEquals(1, toggles, "one press, one toggle")
        // In the text field: not taken (the field gets its space).
        runOnIdle { field.requestFocus() }
        waitForIdle()
        assertEquals(true, Typing.active, "the field has the focus")
        onNodeWithTag("field").performKeyInput { pressKey(Key.Spacebar) }
        waitForIdle()
        assertEquals(1, toggles, "a space typed in a field doesn't toggle")
        // Back on the page, it works again.
        runOnIdle { page.requestFocus() }
        waitForIdle()
        assertEquals(false, Typing.active, "the field no longer has the focus")
        onNodeWithTag("page").performKeyInput { pressKey(Key.Spacebar) }
        waitForIdle()
        assertEquals(2, toggles)
    }
}
