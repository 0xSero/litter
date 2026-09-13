package com.litter.android.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Test

class ThemeColorTest {
    @Test
    fun alphaLastThemeColorsPreserveCssAlpha() {
        // Theme JSON is CSS hex with alpha last; Android ARGB is alpha first.
        assertEquals(Color(0x80458588), colorFromHex("#45858880"))
        assertEquals(Color(0x804585AA), colorFromHex("#4585AA80"))
        // #RGBA shorthand expands each nibble.
        assertEquals(Color(0xAAAA88AA), colorFromHex("#A8AA"))
    }

    @Test
    fun opaqueThemeTokensMatchGeneratedMaterialRoles() {
        assertEquals(Color(0xFF458588), colorFromHex("#458588"))
        assertEquals(
            colorFromHex("#458588"),
            LitterMaterialSchemes.rolesFor("gruvbox-dark-medium", true)?.primary,
        )
    }

    @Test
    fun shorthandAndInvalidColorsResolveWithoutAndroidFramework() {
        assertEquals(Color(0xFFAABBCC), colorFromHex(" #abc "))
        assertEquals(Color(0xFF123456), colorFromHex("#123456"))
        assertEquals(Color.Red, colorFromHex("#invalid", Color.Red))
        assertEquals(Color.Red, colorFromHex("#1234567", Color.Red))
        assertEquals(Color.Red, colorFromHex(null, Color.Red))
    }
}
