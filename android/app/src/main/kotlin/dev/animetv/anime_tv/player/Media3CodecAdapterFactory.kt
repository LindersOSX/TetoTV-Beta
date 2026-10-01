package dev.animetv.anime_tv.player

import android.content.Context
import android.os.Build
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.SynchronousMediaCodecAdapter

/** Preserve Media3 defaults except the precisely scoped Fire TV comparison. */
@androidx.annotation.OptIn(UnstableApi::class)
internal class Media3RenderersFactory(context: Context) : DefaultRenderersFactory(context) {
    val codecAdapters = Media3CodecAdapterFactory(super.getCodecAdapterFactory())

    override fun getCodecAdapterFactory(): MediaCodecAdapter.Factory = codecAdapters
}

@androidx.annotation.OptIn(UnstableApi::class)
internal class Media3CodecAdapterFactory(
    private val defaultFactory: MediaCodecAdapter.Factory,
    private val synchronousFactory: MediaCodecAdapter.Factory = SynchronousMediaCodecAdapter.Factory(),
    private val manufacturer: String = Build.MANUFACTURER,
    private val model: String = Build.MODEL,
    private val sdk: Int = Build.VERSION.SDK_INT,
) : MediaCodecAdapter.Factory {
    // Codec creation runs on ExoPlayer's owned playback thread. The main-thread
    // diagnostic sampler observes these scalar results without retaining a
    // codec, format, source URI, or callback after release.
    private val queueing = Media3CodecQueueingState()
    val videoQueueing: Media3CodecQueueingSnapshot? get() = queueing.snapshot

    override fun createAdapter(configuration: MediaCodecAdapter.Configuration): MediaCodecAdapter {
        val format = configuration.format
        val isVideo = format.sampleMimeType?.startsWith("video/") == true
        val ticket = if (isVideo) queueing.begin() else null
        val compatibility = Media3BridgePolicy.useSynchronousVideoQueueing(
            manufacturer, model, sdk, configuration.codecInfo.name,
            format.sampleMimeType, format.width, format.height,
        )
        val adapter = (if (compatibility) synchronousFactory else defaultFactory)
            .createAdapter(configuration)
        if (ticket != null) {
            // Media3's asynchronous implementation is package-private in the
            // pinned version. Inspect only its exact reviewed class name; no
            // arbitrary runtime identifier is exported to diagnostics.
            queueing.created(ticket, adapter.javaClass.name, compatibility)
            // A retained codec keeps its actual mode. Clear only when this
            // exact adapter is released, not a delayed older codec release.
            return Media3QueueingCodecAdapter(adapter, queueing, ticket)
        }
        return adapter
    }
}

/** Observe release without changing the pinned adapter's codec operations. */
@androidx.annotation.OptIn(UnstableApi::class)
internal class Media3QueueingCodecAdapter(
    private val adapter: MediaCodecAdapter,
    private val queueing: Media3CodecQueueingState,
    private val ticket: Media3CodecQueueingState.Ticket,
) : MediaCodecAdapter by adapter {
    // Kotlin delegation does not forward Java default methods. Preserve
    // Media3's async input-buffer protection and buffer-availability callbacks.
    override fun useInputBuffer(runnable: Runnable) = adapter.useInputBuffer(runnable)

    override fun registerOnBufferAvailableListener(
        listener: MediaCodecAdapter.OnBufferAvailableListener,
    ): Boolean = adapter.registerOnBufferAvailableListener(listener)

    override fun release() {
        try {
            adapter.release()
        } finally {
            queueing.released(ticket)
        }
    }
}
