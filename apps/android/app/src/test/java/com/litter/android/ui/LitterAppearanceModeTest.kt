package com.litter.android.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LitterAppearanceModeTest {
    @Test
    fun parsesStoredAppearanceModes() {
        assertEquals(LitterAppearanceMode.SYSTEM, LitterAppearanceMode.fromStorageValue("system"))
        assertEquals(LitterAppearanceMode.LIGHT, LitterAppearanceMode.fromStorageValue("LIGHT"))
        assertEquals(LitterAppearanceMode.DARK, LitterAppearanceMode.fromStorageValue("dark"))
    }

    @Test
    fun ignoresUnknownStoredAppearanceMode() {
        assertNull(LitterAppearanceMode.fromStorageValue("sepia"))
        assertNull(LitterAppearanceMode.fromStorageValue(null))
    }

    @Test
    fun resolvesDarkThemeFromSystemPreference() {
        assertEquals(false, LitterAppearanceMode.SYSTEM.resolvesDarkTheme(systemIsDark = false))
        assertEquals(true, LitterAppearanceMode.SYSTEM.resolvesDarkTheme(systemIsDark = true))
        assertEquals(false, LitterAppearanceMode.LIGHT.resolvesDarkTheme(systemIsDark = true))
        assertEquals(true, LitterAppearanceMode.DARK.resolvesDarkTheme(systemIsDark = false))
    }
}
