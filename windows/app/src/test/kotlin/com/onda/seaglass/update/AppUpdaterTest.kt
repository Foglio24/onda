package com.onda.seaglass.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AppUpdaterTest {
    @Test
    fun comparesVersionsNumberByNumber() {
        assertTrue(AppUpdater.isNewer("0.1.1", "0.1.0"))
        assertTrue(AppUpdater.isNewer("1.0.0", "0.9.9"))
        assertEquals(0, AppUpdater.compareVersions("0.1.0", "0.1.0"))
        assertTrue(AppUpdater.compareVersions("0.1.10", "0.1.9") > 0)
    }
}
