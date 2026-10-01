package dev.animetv.anime_tv.player

import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

@androidx.annotation.OptIn(UnstableApi::class)
class Media3CodecAdapterDelegationTest {
    private fun fake(invoke: (String, Array<out Any?>?) -> Any?): MediaCodecAdapter =
        Proxy.newProxyInstance(
            MediaCodecAdapter::class.java.classLoader,
            arrayOf(MediaCodecAdapter::class.java),
        ) { _, method, args -> invoke(method.name, args) } as MediaCodecAdapter

    @Test fun pinnedJavaDefaultMethodsAreExplicitlyForwardedToTheActualAdapter() {
        val state = Media3CodecQueueingState()
        val ticket = state.begin()
        val calls = mutableListOf<String>()
        val listener = object : MediaCodecAdapter.OnBufferAvailableListener {}
        val delegate = fake { name, args ->
            calls += name
            when (name) {
                "useInputBuffer" -> (args!![0] as Runnable).run()
                "registerOnBufferAvailableListener" -> {
                    assertSame(listener, args!![0])
                    true
                }
                else -> null
            }
        }
        val wrapped = Media3QueueingCodecAdapter(delegate, state, ticket)
        var used = false
        wrapped.useInputBuffer { used = true }
        assertTrue(used)
        assertTrue(wrapped.registerOnBufferAvailableListener(listener))
        assertEquals(listOf("useInputBuffer", "registerOnBufferAvailableListener"), calls)
        // A new upstream Java default requires an explicit review/forwarder.
        for (method in MediaCodecAdapter::class.java.declaredMethods.filter { it.isDefault }) {
            assertNotNull(Media3QueueingCodecAdapter::class.java.getDeclaredMethod(
                method.name, *method.parameterTypes,
            ))
        }
    }

    @Test fun ordinaryOperationsAndNullableBuffersKeepTheDelegateContract() {
        val state = Media3CodecQueueingState()
        val calls = mutableListOf<String>()
        val delegate = fake { name, _ ->
            calls += name
            when (name) {
                "dequeueInputBufferIndex" -> 42
                "needsReconfiguration" -> true
                else -> null
            }
        }
        val wrapped = Media3QueueingCodecAdapter(delegate, state, state.begin())
        assertEquals(42, wrapped.dequeueInputBufferIndex())
        assertTrue(wrapped.needsReconfiguration())
        assertNull(wrapped.getInputBuffer(42))
        wrapped.flush()
        assertEquals(listOf("dequeueInputBufferIndex", "needsReconfiguration", "getInputBuffer", "flush"), calls)
    }

    @Test fun releaseForwardsOnceAndClearsOnlyItsOwnEvidenceEvenWhenTheDelegateThrows() {
        val state = Media3CodecQueueingState()
        val old = state.begin()
        state.created(old, "androidx.media3.exoplayer.mediacodec.SynchronousMediaCodecAdapter", true)
        var releases = 0
        val failure = IllegalStateException("test")
        val wrapped = Media3QueueingCodecAdapter(fake { name, _ ->
            if (name == "release") {
                releases++
                throw failure
            }
            null
        }, state, old)
        val replacement = state.begin()
        state.created(replacement, "androidx.media3.exoplayer.mediacodec.AsynchronousMediaCodecAdapter", false)
        assertSame(failure, assertThrows(IllegalStateException::class.java) { wrapped.release() })
        assertEquals(1, releases)
        assertEquals(Media3CodecQueueingSnapshot("asynchronous", false), state.snapshot)
        val current = Media3QueueingCodecAdapter(fake { _, _ -> null }, state, replacement)
        current.release()
        assertNull(state.snapshot)
    }
}
