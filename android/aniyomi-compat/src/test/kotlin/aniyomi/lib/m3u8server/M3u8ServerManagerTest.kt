package aniyomi.lib.m3u8server

import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Test

class M3u8ServerManagerTest {
    @Test
    fun socketFreeLifecycleReturnsOnlyStructurallySafeHttps() {
        val manager = M3u8ServerManager(OkHttpClient())
        assertFalse(manager.isRunning())
        assertNull(manager.getServerUrl())
        assertNull(manager.processM3u8Url("https://media.example/master.m3u8"))

        manager.startServer()
        assertTrue(manager.isRunning())
        assertEquals(
            "https://media.example/master.m3u8",
            manager.processM3u8Url(
                "https://media.example/master.m3u8",
                "https://embed.example/",
                "Aniyomi fixture",
            ),
        )
        assertNull(manager.processM3u8Url("http://127.0.0.1/private.m3u8"))
        assertNull(manager.processM3u8Url("https://user:pass@media.example/private.m3u8"))
        assertNull(manager.processM3u8Url("https://media.example/master.m3u8", "http://embed.example/"))
        assertNull(manager.processM3u8Url("https://media.example/master.m3u8", userAgent = "bad\nagent"))

        manager.stopServer()
        assertFalse(manager.isRunning())
        assertNull(manager.processM3u8Url("https://media.example/master.m3u8"))
    }

    @Test
    fun bridgeDiagnosticsAreBoundedToTheCurrentRuntimeRequest() {
        M3u8ServerManager.resetBridgeDiagnostics()
        val manager = M3u8ServerManager(OkHttpClient())
        manager.startServer()
        repeat(3) {
            assertNotNull(manager.processM3u8Url("https://media.example/$it.m3u8"))
        }
        assertEquals(3, M3u8ServerManager.consumeBridgeCount())
        assertEquals(0, M3u8ServerManager.consumeBridgeCount())
    }
}
