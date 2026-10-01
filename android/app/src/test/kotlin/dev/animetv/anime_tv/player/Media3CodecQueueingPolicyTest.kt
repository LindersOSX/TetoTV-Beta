package dev.animetv.anime_tv.player

import org.junit.Assert.*
import org.junit.Test

class Media3CodecQueueingPolicyTest {
    private fun trial(
        manufacturer: String = "Amazon",
        model: String = "AFTKRT",
        sdk: Int = 30,
        decoder: String = "OMX.MTK.VIDEO.DECODER.HEVC",
        mime: String? = "video/hevc",
        width: Int = 3840,
        height: Int = 2160,
    ) = Media3BridgePolicy.useSynchronousVideoQueueing(
        manufacturer, model, sdk, decoder, mime, width, height,
    )

    @Test fun onlyTheVerifiedAffectedNativeFormatUsesTheCompatibilityAdapter() {
        assertTrue(trial())
        assertTrue(trial(manufacturer = "amazon", model = "aftkrt"))
        assertTrue(trial(manufacturer = "AMAZON", model = "AFTKRT"))
    }

    @Test fun otherDevicesAndOperatingSystemsKeepTheirDefaultQueueing() {
        for (manufacturer in listOf("", "Amazon ", "other", "NVIDIA")) {
            assertFalse(trial(manufacturer = manufacturer))
        }
        for (model in listOf("", "AFTKRT ", "AFTKM", "AFTMM", "AFTKRT2")) {
            assertFalse(trial(model = model))
        }
        for (sdk in listOf(0, 24, 28, 29, 31, 36, Int.MAX_VALUE)) {
            assertFalse(trial(sdk = sdk))
        }
    }

    @Test fun otherDecoderNamesAndMediaTypesKeepTheDefaultAdapter() {
        for (decoder in listOf(
            "", "OMX.MTK.VIDEO.DECODER.HEVC.secure", "c2.mtk.hevc.decoder",
            "OMX.google.hevc.decoder", "c2.android.hevc.decoder",
            "OMX.MTK.VIDEO.DECODER.AVC", "omx.mtk.video.decoder.hevc",
        )) assertFalse(trial(decoder = decoder))
        for (mime in listOf(null, "", "video/avc", "video/dolby-vision", "audio/mp4a-latm", "VIDEO/HEVC")) {
            assertFalse(trial(mime = mime))
        }
    }

    @Test fun unknownAndOtherResolutionsAreNotInferredFromAnAdvertised4kDecoder() {
        for ((width, height) in listOf(
            -1 to -1, 0 to 0, 1920 to 1080, 1280 to 720, 4096 to 2160,
            3840 to 2176, 2160 to 3840, Int.MAX_VALUE to Int.MAX_VALUE,
        )) assertFalse(trial(width = width, height = height))
        assertFalse(trial(width = 3840, height = -1))
        assertFalse(trial(width = -1, height = 2160))
    }

    @Test fun queueingDiagnosticsNameOnlyTheActualReviewedPinnedImplementations() {
        assertEquals("synchronous", Media3BridgePolicy.codecQueueingMode(
            "androidx.media3.exoplayer.mediacodec.SynchronousMediaCodecAdapter",
        ))
        assertEquals("asynchronous", Media3BridgePolicy.codecQueueingMode(
            "androidx.media3.exoplayer.mediacodec.AsynchronousMediaCodecAdapter",
        ))
        for (name in listOf(
            "", "SynchronousMediaCodecAdapter", "AsynchronousMediaCodecAdapter",
            "androidx.media3.exoplayer.mediacodec.DefaultMediaCodecAdapterFactory",
            "androidx.media3.exoplayer.mediacodec.AsynchronousMediaCodecAdapter.Factory",
            "custom.PrivateTitleAdapter", "https://private.example/token",
        )) assertNull(Media3BridgePolicy.codecQueueingMode(name))
    }

    @Test fun adapterEvidenceIsUnknownBeforeSuccessfulCreationAndAfterRelease() {
        val state = Media3CodecQueueingState()
        assertNull(state.snapshot)
        val ticket = state.begin()
        assertNull(state.snapshot)
        state.created(ticket,
            "androidx.media3.exoplayer.mediacodec.SynchronousMediaCodecAdapter", true)
        assertEquals(Media3CodecQueueingSnapshot("synchronous", true), state.snapshot)
        // No new creation means the retained adapter keeps its actual mode.
        assertEquals(Media3CodecQueueingSnapshot("synchronous", true), state.snapshot)
        state.released(ticket)
        assertNull(state.snapshot)
    }

    @Test fun replacementClearsEvidenceUntilCreationAndIgnoresLateOldReleases() {
        val state = Media3CodecQueueingState()
        val old = state.begin()
        state.created(old,
            "androidx.media3.exoplayer.mediacodec.SynchronousMediaCodecAdapter", true)
        val replacement = state.begin()
        assertNull(state.snapshot)
        state.created(replacement,
            "androidx.media3.exoplayer.mediacodec.AsynchronousMediaCodecAdapter", false)
        state.released(old)
        state.created(old,
            "androidx.media3.exoplayer.mediacodec.SynchronousMediaCodecAdapter", true)
        assertEquals(Media3CodecQueueingSnapshot("asynchronous", false), state.snapshot)
        state.released(replacement)
        assertNull(state.snapshot)
    }

    @Test fun unknownOrFailedReplacementDoesNotRetainThePreviousAdaptersEvidence() {
        val state = Media3CodecQueueingState()
        val old = state.begin()
        state.created(old,
            "androidx.media3.exoplayer.mediacodec.SynchronousMediaCodecAdapter", false)
        val unknown = state.begin()
        state.created(unknown, "custom.PrivateTitleAdapter", false)
        assertNull(state.snapshot)
        state.begin() // A native factory failure never calls created().
        assertNull(state.snapshot)
    }
}
