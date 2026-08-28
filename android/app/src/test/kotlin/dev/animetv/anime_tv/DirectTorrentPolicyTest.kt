package dev.animetv.anime_tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class DirectTorrentPolicyTest {
    @Test
    fun `runtime capability accepts arm64 on 16 KiB pages`() {
        assertTrue(
            supportsDirectTorrentRuntime(
                processIs64Bit = true,
                supportedAbis = listOf("arm64-v8a", "armeabi-v7a"),
                pageSizeBytes = 16_384L,
            ),
        )
    }

    @Test
    fun `runtime capability rejects arm32 on pages larger than 4 KiB`() {
        assertTrue(
            supportsDirectTorrentRuntime(
                processIs64Bit = false,
                supportedAbis = listOf("armeabi-v7a"),
                pageSizeBytes = 4_096L,
            ),
        )
        assertFalse(
            supportsDirectTorrentRuntime(
                processIs64Bit = false,
                supportedAbis = listOf("armeabi-v7a"),
                pageSizeBytes = 16_384L,
            ),
        )
        assertFalse(
            supportsDirectTorrentRuntime(
                processIs64Bit = false,
                supportedAbis = listOf("armeabi-v7a"),
                pageSizeBytes = -1L,
            ),
        )
    }

    @Test
    fun `process engine starts once then resumes across repeated leases`() {
        val state = DirectTorrentEngineState()

        assertEquals(DirectTorrentEngineAcquireAction.START, state.beginAcquire())
        state.markStarted()
        assertTrue(state.release())
        assertEquals(DirectTorrentEngineAcquireAction.RESUME, state.beginAcquire())
        assertTrue(state.release())
        assertEquals(DirectTorrentEngineAcquireAction.RESUME, state.beginAcquire())
        assertTrue(state.release())
        assertFalse(state.release())
    }

    @Test
    fun `cancelled first acquire can retry without reconstructing a started engine`() {
        val state = DirectTorrentEngineState()

        assertEquals(DirectTorrentEngineAcquireAction.START, state.beginAcquire())
        state.markStarted()
        state.failAcquire()
        assertFalse(state.leased)
        assertEquals(DirectTorrentEngineAcquireAction.RESUME, state.beginAcquire())
        assertTrue(state.release())
    }

    @Test
    fun `uncertain torrent removal permanently poisons engine state`() {
        val state = DirectTorrentEngineState()

        state.beginAcquire()
        state.markStarted()
        state.poison()
        assertTrue(state.poisoned)
        assertTrue(state.release())
        assertTrue(state.started)
        assertThrows(IllegalStateException::class.java) {
            state.beginAcquire()
        }
    }

    @Test
    fun `single video torrent may use its only playable file`() {
        val file = candidate(3, "Show.mkv", 900)

        assertEquals(file, DirectTorrentPolicy.chooseVideoFile(listOf(file), 7, null))
    }

    @Test
    fun `multi file pack fails closed when requested episode is absent`() {
        val files = listOf(
            candidate(0, "Show - 01.mkv", 800),
            candidate(1, "Show - 02.mkv", 900),
            candidate(2, "Show - 03.mkv", 1_000),
        )

        assertNull(DirectTorrentPolicy.chooseVideoFile(files, 7, null))
    }

    @Test
    fun `episode match wins over largest unrelated file`() {
        val selected = candidate(4, "Show.S01E07.1080p.mkv", 700)
        val files = listOf(
            candidate(0, "Show.S01E06.2160p.mkv", 2_000),
            selected,
            candidate(8, "sample.mkv", 100),
        )

        assertEquals(selected, DirectTorrentPolicy.chooseVideoFile(files, 7, null))
    }

    @Test
    fun `episode match overrides wrong preferred index`() {
        val one = candidate(1, "Show - 01.mkv", 800)
        val two = candidate(2, "Show - 02.mkv", 900)

        assertEquals(one, DirectTorrentPolicy.chooseVideoFile(listOf(one, two), 1, 2))
        assertEquals(one, DirectTorrentPolicy.chooseVideoFile(listOf(one, two), 1, 99))
    }

    @Test
    fun `matching preferred index still wins between same episode encodes`() {
        val compact = candidate(1, "Show S01E01 720p.mkv", 800)
        val large = candidate(2, "Show S01E01 1080p.mkv", 900)

        assertEquals(
            compact,
            DirectTorrentPolicy.chooseVideoFile(listOf(compact, large), 1, 1),
        )
    }

    @Test
    fun `later season preserves provider absolute-number preference without season markers`() {
        val absolute87 = candidate(87, "87.mkv", 800)
        val absolute88 = candidate(88, "88.mkv", 900)
        val local25 = candidate(25, "25.mkv", 1_000)

        assertEquals(
            absolute88,
            DirectTorrentPolicy.chooseVideoFile(
                listOf(absolute87, absolute88, local25),
                episode = 25,
                preferredFileIndex = 88,
                requestedSeason = 4,
            ),
        )
    }

    @Test
    fun `explicit later-season patterns override preferred absolute-number file`() {
        for (name in listOf("Show.S04E25.1080p.mkv", "Show.4x25.1080p.mkv")) {
            val preferredAbsolute = candidate(88, "88.mkv", 1_000)
            val explicit = candidate(25, name, 800)

            assertEquals(
                explicit,
                DirectTorrentPolicy.chooseVideoFile(
                    listOf(preferredAbsolute, explicit),
                    episode = 25,
                    preferredFileIndex = 88,
                    requestedSeason = 4,
                ),
            )
        }
    }

    @Test
    fun `audio channel decimal cannot impersonate requested episode`() {
        val wrong = candidate(2, "Show.S01E02.[5.1].mkv", 900)

        assertNull(
            DirectTorrentPolicy.chooseVideoFile(
                listOf(wrong),
                episode = 1,
                preferredFileIndex = 2,
                requestedSeason = 1,
            ),
        )
    }

    @Test
    fun `wrong episode pack cannot select preferred unknown extra`() {
        val files = listOf(
            candidate(1, "Show - 01.mkv", 800),
            candidate(2, "Show - 02.mkv", 900),
            candidate(9, "NCOP.mkv", 1_000),
        )

        assertNull(
            DirectTorrentPolicy.chooseVideoFile(
                files,
                episode = 7,
                preferredFileIndex = 9,
            ),
        )
    }

    @Test
    fun `selected basename removes path controls and bounds channel value`() {
        val longTitle = "A".repeat(DIRECT_TORRENT_MAX_SELECTED_BASENAME_CHARS + 20)
        val selected = DirectTorrentPolicy.selectedBasename(
            "private/folder/\u0000$longTitle Episode 07.mkv",
        )

        assertFalse(selected.contains('/'))
        assertFalse(selected.contains('\u0000'))
        assertEquals(DIRECT_TORRENT_MAX_SELECTED_BASENAME_CHARS, selected.length)
        assertTrue(selected.endsWith("Episode 07.mkv"))
    }

    @Test
    fun `pad non video oversized and empty files are rejected`() {
        val files = listOf(
            candidate(0, ".pad/0", 10, pad = true),
            candidate(1, "Episode 07.txt", 100),
            candidate(2, "Episode 07.mkv", 0),
            candidate(3, "Episode 07.mkv", DIRECT_TORRENT_MAX_FILE_BYTES + 1),
        )

        assertNull(DirectTorrentPolicy.chooseVideoFile(files, 7, null))
    }

    @Test
    fun `range parser supports open bounded and suffix requests`() {
        assertEquals(null, DirectTorrentPolicy.parseRange(null, 1_000))
        assertEquals(DirectTorrentByteRange(100, 999), DirectTorrentPolicy.parseRange("bytes=100-", 1_000))
        assertEquals(DirectTorrentByteRange(100, 199), DirectTorrentPolicy.parseRange("bytes=100-199", 1_000))
        assertEquals(DirectTorrentByteRange(900, 999), DirectTorrentPolicy.parseRange("bytes=-100", 1_000))
        assertEquals(DirectTorrentByteRange(0, 999), DirectTorrentPolicy.parseRange("bytes=-5000", 1_000))
        assertEquals(DirectTorrentByteRange(900, 999), DirectTorrentPolicy.parseRange("bytes=900-5000", 1_000))
    }

    @Test
    fun `range parser rejects malformed unsatisfiable and multi ranges`() {
        for (header in listOf("items=0-1", "bytes=-", "bytes=1000-", "bytes=9-2", "bytes=0-1,4-5")) {
            assertThrows(DirectTorrentRangeException::class.java) {
                DirectTorrentPolicy.parseRange(header, 1_000)
            }
        }
    }

    private fun candidate(
        index: Int,
        path: String,
        size: Long,
        pad: Boolean = false,
    ) = DirectTorrentFileCandidate(index, path, size, pad)
}
