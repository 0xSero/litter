package com.litter.android

import com.litter.android.ui.home.HomeDashboardSupport
import com.litter.android.ui.home.usesServerConfiguredModelDefault
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeDashboardSupportTests {

    @Test
    fun `Local Studio-only catalogs defer to the server configured default`() {
        assertTrue(usesServerConfiguredModelDefault(listOf("local-studio")))
        assertTrue(
            usesServerConfiguredModelDefault(
                listOf("local-studio", "local-studio"),
            ),
        )
        assertFalse(usesServerConfiguredModelDefault(emptyList()))
        assertFalse(
            usesServerConfiguredModelDefault(
                listOf("local-studio", "codex"),
            ),
        )
    }

    @Test
    fun `workspaceLabel extracts last path component`() {
        assertEquals("projects", HomeDashboardSupport.workspaceLabel("/home/user/projects"))
        assertEquals("src", HomeDashboardSupport.workspaceLabel("/home/user/projects/src"))
    }

    @Test
    fun `workspaceLabel returns tilde for null or blank`() {
        assertEquals("~", HomeDashboardSupport.workspaceLabel(null))
        assertEquals("~", HomeDashboardSupport.workspaceLabel(""))
        assertEquals("~", HomeDashboardSupport.workspaceLabel("   "))
    }

    @Test
    fun `workspaceLabel handles root path`() {
        assertEquals("/", HomeDashboardSupport.workspaceLabel("/"))
    }

    @Test
    fun `workspaceLabel trims trailing slash`() {
        assertEquals("projects", HomeDashboardSupport.workspaceLabel("/home/user/projects/"))
    }

    @Test
    fun `relativeTime formats correctly`() {
        val now = System.currentTimeMillis() / 1000L

        assertEquals("just now", HomeDashboardSupport.relativeTime(now - 30))
        assertEquals("5m ago", HomeDashboardSupport.relativeTime(now - 300))
        assertEquals("2h ago", HomeDashboardSupport.relativeTime(now - 7200))
        assertEquals("3d ago", HomeDashboardSupport.relativeTime(now - 259200))
    }

    @Test
    fun `relativeTime returns empty for null or zero`() {
        assertEquals("", HomeDashboardSupport.relativeTime(null))
        assertEquals("", HomeDashboardSupport.relativeTime(0L))
    }
}
