package dev.animetv.anime_tv.player

import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import org.junit.Assert.*
import org.junit.Test

@androidx.annotation.OptIn(UnstableApi::class)
class Media3PlaybackContractTest {
    @Test fun playbackIntentIncludesBufferingButExcludesEverySuppression() {
        for (state in listOf(Player.STATE_READY, Player.STATE_BUFFERING)) {
            assertTrue(Media3PlaybackContract.playing(true, state, Player.PLAYBACK_SUPPRESSION_REASON_NONE, false))
            assertFalse(Media3PlaybackContract.playing(false, state, Player.PLAYBACK_SUPPRESSION_REASON_NONE, false))
            assertFalse(Media3PlaybackContract.playing(true, state, Player.PLAYBACK_SUPPRESSION_REASON_NONE, true))
            for (reason in listOf(Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS, Player.PLAYBACK_SUPPRESSION_REASON_UNSUITABLE_AUDIO_OUTPUT, Player.PLAYBACK_SUPPRESSION_REASON_SCRUBBING, 999)) {
                assertFalse(Media3PlaybackContract.playing(true, state, reason, false))
            }
        }
        for (state in listOf(Player.STATE_IDLE, Player.STATE_ENDED, 999)) {
            assertFalse(Media3PlaybackContract.playing(true, state, Player.PLAYBACK_SUPPRESSION_REASON_NONE, false))
        }
    }

    @Test fun permanentFocusOrNoisyPauseDoesNotResumeOnNextActivityResume() {
        for (reason in listOf(Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS, Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY, Player.PLAY_WHEN_READY_CHANGE_REASON_SUPPRESSED_TOO_LONG)) {
            assertTrue(Media3PlaybackContract.shouldClearPlayIntent(false, reason))
            assertFalse(Media3PlaybackContract.shouldClearPlayIntent(true, reason))
        }
        // Our foreground guard pauses as USER_REQUEST; preserve the separate
        // desiredPlaying flag so ordinary activity resume still works.
        assertFalse(Media3PlaybackContract.shouldClearPlayIntent(false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST))
    }

    @Test fun endClippingPreservesAbsoluteTimelineAndUnlimitedOpenDefault() {
        val clip = Media3PlaybackContract.clipping(20_000)
        assertEquals(0L, clip.startPositionMs)
        assertEquals(20_000L, clip.endPositionMs)
        assertFalse(clip.relativeToDefaultPosition)
        assertFalse(clip.relativeToLiveWindow)
        assertEquals(C.TIME_END_OF_SOURCE, Media3PlaybackContract.clipping(null).endPositionMs)
    }
}
