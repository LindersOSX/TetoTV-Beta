package dev.animetv.anime_tv.aniyomi

import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Coordinates one disposable worker's deadline, result-delivery, and cancel races. */
internal class AniyomiWorkerLifecycle {
    private val terminating = AtomicBoolean(false)

    val isTerminating: Boolean
        get() = terminating.get()

    fun beginTermination(): Boolean = terminating.compareAndSet(false, true)

    /**
     * Schedules cleanup only while the worker is active.
     *
     * The host may send CANCEL between the active check and schedule(). A
     * rejected task is therefore an expected teardown outcome, not an
     * uncaught worker exception.
     */
    fun scheduleTermination(
        watchdog: ScheduledExecutorService,
        delayMillis: Long,
        terminate: () -> Unit,
    ): Boolean {
        if (isTerminating || watchdog.isShutdown) return false
        return try {
            watchdog.schedule(
                { if (!isTerminating) terminate() },
                delayMillis.coerceAtLeast(0L),
                TimeUnit.MILLISECONDS,
            )
            true
        } catch (_: RejectedExecutionException) {
            false
        }
    }
}

/** Fixed operation attribution for failures raised by provider-owned threads. */
internal object AniyomiWorkerFailureAttribution {
    fun stage(operation: String): String = when (operation) {
        "search" -> "source_search"
        "details" -> "source_details"
        "seasons" -> "source_seasons"
        "episodes" -> "source_episodes"
        "chapters" -> "source_chapters"
        "videos" -> "source_videos"
        "pages" -> "source_pages"
        "sources" -> "source_describe"
        else -> "source_operation"
    }
}
