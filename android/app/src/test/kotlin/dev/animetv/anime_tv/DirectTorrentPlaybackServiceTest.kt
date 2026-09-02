package dev.animetv.anime_tv

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DirectTorrentPlaybackServiceTest {
    @Test
    fun `start command never stops service`() {
        assertFalse(
            shouldStopDirectTorrentService(
                DirectTorrentPlaybackService.ACTION_START,
                startId = 1,
            ) { true },
        )
    }

    @Test
    fun `latest stop command stops promoted service`() {
        assertTrue(
            shouldStopDirectTorrentService(
                DirectTorrentPlaybackService.ACTION_STOP,
                startId = 2,
            ) { candidate -> candidate == 2 },
        )
    }

    @Test
    fun `replacement start queued after stop preserves new generation`() {
        val latestIssuedStartId = 3

        assertFalse(
            shouldStopDirectTorrentService(
                DirectTorrentPlaybackService.ACTION_STOP,
                startId = 2,
            ) { candidate -> candidate == latestIssuedStartId },
        )
    }

    @Test
    fun `start interleaving with stop decision cannot be lost by old destroy`() {
        var latestIssuedStartId = 2

        val stopped = shouldStopDirectTorrentService(
            DirectTorrentPlaybackService.ACTION_STOP,
            startId = 2,
        ) { candidate ->
            latestIssuedStartId = 3
            candidate == latestIssuedStartId
        }

        assertFalse(stopped)
        assertTrue(latestIssuedStartId == 3)
    }

    @Test
    fun `unknown command cannot stop service`() {
        assertFalse(
            shouldStopDirectTorrentService(
                action = null,
                startId = 2,
            ) { true },
        )
    }
}
