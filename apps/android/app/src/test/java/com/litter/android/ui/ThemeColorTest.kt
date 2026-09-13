package com.litter.android.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Test

class ThemeColorTest {
    @Test
    fun alphaLastThemeColorsMatchGeneratedMaterialRoles() {
        val accent = colorFromHex("#45858880")
        assertEquals(Color(0xFF458588), accent)
        assertEquals(accent, LitterMaterialSchemes.rolesFor("gruvbox-dark-medium", true)?.primary)
    }

    @Test
    fun shorthandAndInvalidColorsResolveWithoutAndroidFramework() {
        assertEquals(Color(0xFFAABBCC), colorFromHex(" #abc "))
        assertEquals(Color(0xFF123456), colorFromHex("#123456"))
        assertEquals(Color.Red, colorFromHex("#invalid", Color.Red))
        assertEquals(Color.Red, colorFromHex(null, Color.Red))
    }
}
