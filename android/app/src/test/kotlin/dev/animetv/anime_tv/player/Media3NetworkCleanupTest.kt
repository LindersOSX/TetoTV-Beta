package dev.animetv.anime_tv.player

import java.util.concurrent.Executor
import org.junit.Assert.*
import org.junit.Test

class Media3NetworkCleanupTest {
    @Test fun networkCleanupDoesNotRunOnTheCallingPlayerThread() {
        val queued = mutableListOf<Runnable>()
        val steps = mutableListOf<String>()
        Media3NetworkCleanup.enqueue(Executor(queued::add),
            { steps += "cancel" }, { steps += "evict" }, { steps += "shutdown" })
        assertTrue(steps.isEmpty())
        queued.single().run()
        assertEquals(listOf("cancel", "evict", "shutdown"), steps)
    }

    @Test fun failedNetworkCleanupDoesNotSkipOtherResourcesOrEscapeToPlayerRelease() {
        val steps = mutableListOf<String>()
        Media3NetworkCleanup.enqueue(Executor(Runnable::run),
            { steps += "cancel"; throw IllegalStateException("private detail") },
            { steps += "evict"; throw IllegalStateException("private detail") },
            { steps += "shutdown" })
        assertEquals(listOf("cancel", "evict", "shutdown"), steps)
    }
}
