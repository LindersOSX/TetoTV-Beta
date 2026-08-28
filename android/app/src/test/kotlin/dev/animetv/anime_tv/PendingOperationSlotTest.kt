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
}
