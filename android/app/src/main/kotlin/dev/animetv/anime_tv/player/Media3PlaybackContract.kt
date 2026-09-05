package dev.animetv.anime_tv.player

import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi

/** Small native contract decisions exercised without constructing a decoder. */
@androidx.annotation.OptIn(UnstableApi::class)
internal object Media3PlaybackContract {
    fun playing(
        playWhenReady: Boolean,
        playbackState: Int,
        suppressionReason: Int,
        hasError: Boolean,
    ): Boolean = playWhenReady && !hasError &&
        suppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE &&
        playbackState in setOf(Player.STATE_READY, Player.STATE_BUFFERING)

    fun shouldClearPlayIntent(playWhenReady: Boolean, changeReason: Int): Boolean =
        !playWhenReady && changeReason in setOf(
            Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS,
            Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY,
            Player.PLAY_WHEN_READY_CHANGE_REASON_SUPPRESSED_TOO_LONG,
        )

    fun clipping(endMs: Long?): MediaItem.ClippingConfiguration =
        MediaItem.ClippingConfiguration.Builder()
            // startMs is the initial resume/seek position, not a new timeline
            // origin. End-only clipping preserves absolute position and cues.
            .setStartPositionMs(0)
            .setEndPositionMs(endMs ?: C.TIME_END_OF_SOURCE)
            .build()
}
