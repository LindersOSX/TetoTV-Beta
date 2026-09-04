package dev.animetv.anime_tv

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DirectTorrentHandleOwnershipContractTest {
    private val source by lazy { directTorrentManagerSource() }

    @Test
    fun `alert callbacks retain only session-owned torrent handles`() {
        val engine = source
            .substringAfter("internal object DirectTorrentEngine", "")
            .substringBefore("internal class DirectTorrentManager", "")
        val listener = source
            .substringAfter("private val alertListener", "")
            .substringBefore("fun start(", "")

        assertTrue(engine.contains("fun retainAlertHandle(alert: TorrentAlert<*>)"))
        assertTrue(engine.contains("session.swig().find_torrent(hash)"))
        assertTrue(engine.contains("hashes.has_v1()"))
        assertTrue(engine.contains("hashes.has_v2()"))
        assertTrue(engine.contains("!state.leased || state.poisoned"))
        assertTrue(listener.contains("DirectTorrentEngine.retainAlertHandle(added)"))
        assertFalse(listener.contains("torrentHandle.set(added.handle())"))
        assertFalse(listener.contains("handleOrNull()"))

        val addAlert = listener
            .substringAfter("AlertType.ADD_TORRENT ->", "")
            .substringBefore("AlertType.METADATA_RECEIVED", "")
        assertEquals(
            "Only an explicit native add error may prove that no torrent exists",
            1,
            Regex("addFailed\\.set\\(true\\)").findAll(addAlert).count(),
        )
    }

    private fun directTorrentManagerSource(): String {
        val workingDirectory = System.getProperty("user.dir") ?: "."
        return generateSequence(File(workingDirectory)) { it.parentFile }
            .take(7)
            .flatMap { directory ->
                sequenceOf(
                    File(directory, "src/main/kotlin/dev/animetv/anime_tv/DirectTorrentManager.kt"),
                    File(directory, "app/src/main/kotlin/dev/animetv/anime_tv/DirectTorrentManager.kt"),
                    File(directory, "android/app/src/main/kotlin/dev/animetv/anime_tv/DirectTorrentManager.kt"),
                )
            }
            .firstOrNull(File::isFile)
            ?.readText()
            ?: error("Missing DirectTorrentManager.kt")
    }
}
