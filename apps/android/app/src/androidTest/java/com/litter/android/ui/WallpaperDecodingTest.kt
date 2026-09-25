package com.litter.android.ui

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException

@RunWith(AndroidJUnit4::class)
class WallpaperDecodingTest {
    private fun imageBytes(width: Int, height: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        return try {
            ByteArrayOutputStream().use { output ->
                assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
                output.toByteArray()
            }
        } finally {
            bitmap.recycle()
        }
    }

    @Test
    fun oversizedImageIsSampledAndBothStreamsAreClosed() {
        val bytes = imageBytes(8192, 512)
        var opened = 0
        var closed = 0
        val decoded = WallpaperManager.decodeSampledBitmap {
            opened++
            object : ByteArrayInputStream(bytes) {
                override fun close() {
                    closed++
                    super.close()
                }
            }
        }
        try {
            requireNotNull(decoded)
            assertEquals(2048, decoded.width)
            assertEquals(128, decoded.height)
            assertTrue(decoded.allocationByteCount <= 2048 * 128 * 4)
            assertEquals(2, opened)
            assertEquals(2, closed)
        } finally {
            decoded?.recycle()
        }
    }

    @Test
    fun boundsDecodeDoesNotDiscardAValidSmallImage() {
        val bytes = imageBytes(48, 16)
        val decoded = WallpaperManager.decodeSampledBitmap { ByteArrayInputStream(bytes) }
        try {
            requireNotNull(decoded)
            assertEquals(48, decoded.width)
            assertEquals(16, decoded.height)
        } finally {
            decoded?.recycle()
        }
    }

    @Test
    fun oddDimensionsStayWithinTheDecodeLimit() {
        val bytes = imageBytes(4097, 17)
        val decoded = WallpaperManager.decodeSampledBitmap { ByteArrayInputStream(bytes) }
        try {
            requireNotNull(decoded)
            assertTrue(decoded.width <= 2048)
            assertTrue(decoded.height <= 2048)
        } finally {
            decoded?.recycle()
        }
    }

    @Test
    fun malformedOrUnavailableImagesDoNotCrash() {
        assertNull(WallpaperManager.decodeSampledBitmap { ByteArrayInputStream(byteArrayOf(1, 2, 3)) })
        assertNull(WallpaperManager.decodeSampledBitmap { null })
        assertNull(WallpaperManager.decodeSampledBitmap { throw IOException("Unavailable test image") })
        val bytes = imageBytes(48, 16)
        var opened = 0
        assertNull(WallpaperManager.decodeSampledBitmap {
            if (opened++ == 0) ByteArrayInputStream(bytes) else null
        })
    }
}
