package dev.animetv.anime_tv

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingOperationSlotTest {
    @Test
    fun `cancel take clears pending connect before retry claims the slot`() {
        val slot = PendingOperationSlot<Any>()
        val firstConnect = Any()
        val retryConnect = Any()

        assertTrue(slot.trySet(firstConnect))
        assertFalse(slot.trySet(retryConnect))

        // Mirrors discordDisconnect: take is both retrieval and atomic clear.
        assertSame(firstConnect, slot.take())
        assertNull(slot.take())

        // Mirrors Settings Retry: it can start a new native connection.
        assertTrue(slot.trySet(retryConnect))
        assertSame(retryConnect, slot.take())
    }

    @Test
    fun `old timeout cannot clear a replacement retry`() {
        val slot = PendingOperationSlot<Any>()
        val oldConnect = Any()
        val retryConnect = Any()
        assertTrue(slot.trySet(oldConnect))
        assertSame(oldConnect, slot.takeIf(oldConnect))
        assertTrue(slot.trySet(retryConnect))

        assertNull(slot.takeIf(oldConnect))
        assertFalse(slot.trySet(Any()))
        assertSame(retryConnect, slot.takeIf(retryConnect))
        assertNull(slot.take())
    }

    @Test
    fun `late native request identity cannot settle a replacement refresh`() {
        data class Refresh(val requestId: Long)
        val slot = PendingOperationSlot<Refresh>()
        val oldRefresh = Refresh(1L)
        val retryRefresh = Refresh(2L)
        assertTrue(slot.trySet(oldRefresh))
        assertSame(oldRefresh, slot.takeIf(oldRefresh))
        assertTrue(slot.trySet(retryRefresh))

        assertNull(slot.takeMatching { it.requestId == oldRefresh.requestId })
        assertNull(slot.takeIf(oldRefresh))
        assertFalse(slot.trySet(Refresh(3L)))
        assertSame(retryRefresh, slot.takeMatching { it.requestId == retryRefresh.requestId })
        assertNull(slot.take())
    }
}
