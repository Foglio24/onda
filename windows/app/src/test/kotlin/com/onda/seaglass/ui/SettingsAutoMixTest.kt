package com.onda.seaglass.ui

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.graphics.toAwtImage
import com.onda.seaglass.core.Prefs
import com.onda.seaglass.core.tr
import com.onda.seaglass.ui.pages.SettingsPage
import java.io.File
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Settings › Audio shows AutoMix's options under AutoMix, and they change the settings. */
@OptIn(ExperimentalTestApi::class)
class SettingsAutoMixTest {
    private fun shown(text: String) = tr(text)

    @Test
    fun theOptionsAppearUnderAutoMixAndChangeTheSettings() = runComposeUiTest {
        Prefs.transition.value = "automix"
        Prefs.liveMix.value = true
        Prefs.mixStyle.value = "automatic"
        setContent { SeaglassTheme { SettingsPage() } }
        for (label in listOf("Mix dal vivo", "Stile", "Durata del mix", "Variazione di tempo", "Equalizzazione automatica", "Tieni l'album intero", "Mix Lab", "Avanti", "Segna il mix sulla barra", "Radio automatica")) {
            onNodeWithText(shown(label)).performScrollTo()
            assertTrue(onAllNodesWithText(shown(label)).fetchSemanticsNodes().isNotEmpty(), "$label is shown")
        }
        // A switch: Equalizzazione automatica off.
        assertTrue(Prefs.autoEqualiser.value)
        onNodeWithText(shown("Equalizzazione automatica")).performClick()
        assertEquals(false, Prefs.autoEqualiser.value)
        onNodeWithText(shown("Equalizzazione automatica")).performClick()
        // Mix Lab opens its three switches.
        onNodeWithText(shown("Mix Lab")).performClick()
        waitForIdle()
        onNodeWithText(shown("Stile per energia")).performScrollTo().performClick()
        assertTrue(Prefs.labEnergy.value)
        Prefs.labEnergy.value = false
        // Mix dal vivo off hides the rest.
        onNodeWithText(shown("Mix dal vivo")).performScrollTo().performClick()
        waitForIdle()
        assertEquals(false, Prefs.liveMix.value)
        assertTrue(onAllNodesWithText(shown("Durata del mix")).fetchSemanticsNodes().isEmpty(), "the options are hidden")
        Prefs.liveMix.value = true
        onNodeWithText(shown("Mix dal vivo")).performScrollTo()
        // A picture of the page, for whoever reads the results (not an assertion).
        val out = File(System.getProperty("java.io.tmpdir"), "seaglass-settings-automix.png")
        ImageIO.write(onRoot().captureToImage().toAwtImage(), "png", out)
    }
}
