package dev.animetv.anime_tv.aniyomi

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AniyomiWorkerLifecycleTest {
    @Test fun fatalFailuresReceiveOnlyTheClosedOperationStage() {
        assertEquals("source_search", AniyomiWorkerFailureAttribution.stage("search"))
        assertEquals("source_videos", AniyomiWorkerFailureAttribution.stage("videos"))
        assertEquals("source_pages", AniyomiWorkerFailureAttribution.stage("pages"))
        assertEquals("source_chapters", AniyomiWorkerFailureAttribution.stage("chapters"))
        assertEquals("source_operation", AniyomiWorkerFailureAttribution.stage("private-url"))
    }

    @Test fun terminationIsIdempotentAndPreventsNewCleanupTasks() {
        val watchdog = Executors.newSingleThreadScheduledExecutor()
        val lifecycle = AniyomiWorkerLifecycle()
        try {
            assertTrue(lifecycle.beginTermination())
            assertFalse(lifecycle.beginTermination())
            assertFalse(lifecycle.scheduleTermination(watchdog, 0) {})
        } finally {
            watchdog.shutdownNow()
        }
    }

    @Test fun aConcurrentWatchdogShutdownIsAnExpectedTeardownOutcome() {
        val watchdog = Executors.newSingleThreadScheduledExecutor()
        val lifecycle = AniyomiWorkerLifecycle()
        watchdog.shutdownNow()

        assertFalse(lifecycle.scheduleTermination(watchdog, 0) {})
    }

    @Test fun anActiveWorkerRunsItsScheduledTerminationOnce() {
        val watchdog = Executors.newSingleThreadScheduledExecutor()
        val lifecycle = AniyomiWorkerLifecycle()
        val calls = AtomicInteger()
        try {
            assertTrue(
                lifecycle.scheduleTermination(watchdog, 0) {
                    if (lifecycle.beginTermination()) calls.incrementAndGet()
                },
            )
            watchdog.shutdown()
            assertTrue(watchdog.awaitTermination(2, TimeUnit.SECONDS))
            assertEquals(1, calls.get())
            assertTrue(lifecycle.isTerminating)
        } finally {
            watchdog.shutdownNow()
        }
    }
}
