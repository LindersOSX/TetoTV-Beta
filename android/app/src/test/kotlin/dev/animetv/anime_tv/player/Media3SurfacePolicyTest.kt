package dev.animetv.anime_tv.player

import org.junit.Assert.*
import org.junit.Test

class Media3SurfacePolicyTest {
    @Test fun omittedSurfaceTypeRetainsTextureViewAndOnlyExplicitSurfaceOptInChangesIt() {
        assertEquals("texture", Media3BridgePolicy.surfaceType(null))
        assertEquals("texture", Media3BridgePolicy.surfaceType("texture"))
        assertEquals("surface", Media3BridgePolicy.surfaceType("surface"))
        for (raw in listOf("", "SurfaceView", "surface_view", "SURFACE", " texture", true, 1, emptyMap<String, String>())) {
            assertThrows(IllegalArgumentException::class.java) { Media3BridgePolicy.surfaceType(raw) }
        }
    }

    @Test fun capturesStayBoundedAndKeepLandscapeAndPortraitAspectRatios() {
        assertEquals(480 to 270, Media3BridgePolicy.screenshotSize(1920, 1080))
        assertEquals(270 to 480, Media3BridgePolicy.screenshotSize(1080, 1920))
        assertEquals(320 to 240, Media3BridgePolicy.screenshotSize(320, 240))
        assertEquals(480 to 480, Media3BridgePolicy.screenshotSize(Int.MAX_VALUE, Int.MAX_VALUE))
        assertEquals(1 to 480, Media3BridgePolicy.screenshotSize(1, Int.MAX_VALUE))
        for ((width, height) in listOf(0 to 100, 100 to 0, -1 to 100, 100 to -1)) {
            assertNull(Media3BridgePolicy.screenshotSize(width, height))
        }
        assertEquals(256 * 1024, Media3BridgePolicy.SCREENSHOT_MAX_BYTES)
    }

    @Test fun cancelledCaptureCompletesOnceAndDiscardsLateCopiedPixels() {
        val replies = mutableListOf<ByteArray?>()
        val capture = Media3ScreenshotResult { replies.add(it) }
        assertTrue(capture.isPending)
        capture.complete(null)
        assertFalse(capture.isPending)
        capture.complete(byteArrayOf(1, 2, 3))
        capture.complete(null)
        assertEquals(1, replies.size)
        assertNull(replies.single())
    }

    @Test fun successfulCapturePreservesByteResponseAndCannotCompleteTwice() {
        val replies = mutableListOf<ByteArray?>()
        val capture = Media3ScreenshotResult { replies.add(it) }
        val pixels = byteArrayOf(4, 5, 6)
        capture.complete(pixels)
        capture.complete(null)
        assertFalse(capture.isPending)
        assertEquals(1, replies.size)
        assertSame(pixels, replies.single())
    }
}
