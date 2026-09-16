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
    fun `runtime capability accepts arm32 through 16 KiB pages`() {
        assertTrue(
            supportsDirectTorrentRuntime(
                processIs64Bit = false,
                supportedAbis = listOf("armeabi-v7a"),
                pageSizeBytes = 4_096L,
            ),
        )
        assertTrue(
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
                pageSizeBytes = 65_536L,
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
    fun `single opaque video torrent fails closed`() {
        val file = candidate(3, "Show.mkv", 900)

        assertNull(DirectTorrentPolicy.chooseVideoFile(listOf(file), 7, null))
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
    fun `anime suffix followed by release tags proves the episode`() {
        val selected = candidate(
            8,
            "[Group] Show - 08 Dual Audio 1080p x265.mkv",
            900,
        )

        assertEquals(
            selected,
            DirectTorrentPolicy.chooseVideoFile(listOf(selected), 8, null),
        )
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
    fun `later season uses an authoritative absolute episode instead of provider preference`() {
        val absolute87 = candidate(87, "87.mkv", 800)
        val absolute88 = candidate(88, "88.mkv", 900)
        val local25 = candidate(25, "25.mkv", 1_000)

        assertEquals(
            absolute88,
            DirectTorrentPolicy.chooseVideoFile(
                listOf(absolute87, absolute88, local25),
                episode = 25,
                preferredFileIndex = 25,
                requestedSeason = 4,
                requestedAbsoluteEpisode = 88,
            ),
        )
    }

    @Test
    fun `later season without an offset or season scope fails closed`() {
        val absolute88 = candidate(88, "88.mkv", 900)
        val local25 = candidate(25, "25.mkv", 1_000)

        assertNull(
            DirectTorrentPolicy.chooseVideoFile(
                listOf(absolute88, local25),
                episode = 25,
                preferredFileIndex = 88,
                requestedSeason = 4,
            ),
        )
    }

    @Test
    fun `unnumbered sequel title requires an explicit numbering scheme`() {
        val local = candidate(1, "Show Final Season - 01.mkv", 1_000)
        val absolute = candidate(60, "Show Final Season - 60.mkv", 900)
        val explicit = candidate(2, "Show Final Season S04E01.mkv", 800)

        assertNull(
            DirectTorrentPolicy.chooseVideoFile(
                listOf(local, absolute),
                episode = 1,
                preferredFileIndex = 60,
                requireNumberingSchemeEvidence = true,
            ),
        )
        assertEquals(
            explicit,
            DirectTorrentPolicy.chooseVideoFile(
                listOf(explicit),
                episode = 1,
                preferredFileIndex = 2,
                requireNumberingSchemeEvidence = true,
            ),
        )
    }

    @Test
    fun `season folder scopes a plain numeric anime filename`() {
        val six = candidate(6, "Show/Season 3/06.mkv", 800)
        val seven = candidate(7, "Show/Season 3/07.mkv", 900)

        assertEquals(
            seven,
            DirectTorrentPolicy.chooseVideoFile(
                listOf(six, seven),
                episode = 7,
                preferredFileIndex = 6,
                requestedSeason = 3,
            ),
        )
    }

    @Test
    fun `multi episode video range is not treated as the selected episode`() {
        val compilation = candidate(0, "Show S01E01-E12.mkv", 5_000)

        assertNull(
            DirectTorrentPolicy.chooseVideoFile(
                listOf(compilation),
                episode = 7,
                preferredFileIndex = 0,
                requestedSeason = 1,
            ),
        )
    }

    @Test
    fun `regular episode does not select a numbered special`() {
        val special = candidate(0, "Show Special 01.mkv", 900)

        assertNull(
            DirectTorrentPolicy.chooseVideoFile(
                listOf(special),
                episode = 1,
                preferredFileIndex = 0,
                requestedSeason = 1,
            ),
        )
        assertEquals(
            special,
            DirectTorrentPolicy.chooseVideoFile(
                listOf(special),
                episode = 1,
                preferredFileIndex = 0,
                requestedSeason = 0,
                requestedSpecial = true,
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
        val technicalOnly = listOf(
            candidate(5, "Show - 5.1 audio.mkv", 900),
            candidate(10, "Show - 10-bit x265.mkv", 900),
            candidate(60, "Show - 60 fps.mkv", 900),
        )

        assertNull(
            DirectTorrentPolicy.chooseVideoFile(
                listOf(wrong),
                episode = 1,
                preferredFileIndex = 2,
                requestedSeason = 1,
            ),
        )
        assertNull(DirectTorrentPolicy.chooseVideoFile(technicalOnly, 5, null))
        assertNull(DirectTorrentPolicy.chooseVideoFile(technicalOnly, 10, null))
        assertNull(DirectTorrentPolicy.chooseVideoFile(technicalOnly, 60, null))
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
