package com.litter.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MainActivityNotificationPermissionTest {

    @Test
    fun `only Android 13 and newer needs the notification runtime prompt`() {
        assertFalse(
            shouldRequestNotificationPermission(
                sdkInt = 32,
                isGranted = false,
                wasAlreadyRequested = false,
            ),
        )
        assertTrue(
            shouldRequestNotificationPermission(
                sdkInt = 33,
                isGranted = false,
                wasAlreadyRequested = false,
            ),
        )
    }

    @Test
    fun `granted and previously dismissed notification prompts are not repeated`() {
        assertFalse(
            shouldRequestNotificationPermission(
                sdkInt = 36,
                isGranted = true,
                wasAlreadyRequested = false,
            ),
        )
        assertFalse(
            shouldRequestNotificationPermission(
                sdkInt = 36,
                isGranted = false,
                wasAlreadyRequested = true,
            ),
        )
    }
}
