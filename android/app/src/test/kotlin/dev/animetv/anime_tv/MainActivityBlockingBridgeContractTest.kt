package dev.animetv.anime_tv

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MainActivityBlockingBridgeContractTest {
    private val mainActivity by lazy { mainActivitySource() }

    @Test
    fun `potentially blocking platform calls use the background dispatcher`() {
        val handler = mainActivity
            .substringAfter("channel.setMethodCallHandler", "")
            .substringBefore("private fun <T> runPlatformBlockingOperation")
        val methods = listOf(
            "setAnonymousCrashReportingEnabled",
            "storePendingAnonymousCrashReport",
            "getPendingAnonymousCrashReport",
            "getRecentLocalCrashSummaries",
            "acknowledgeAnonymousCrashReport",
            "clearPendingAnonymousCrashReports",
            "publishWatchNext",
            "removeWatchNext",
            "syncEpisodeReleaseNotifications",
        )

        methods.forEachIndexed { index, method ->
            val nextMethod = methods.getOrNull(index + 1)
            val branch = handler
                .substringAfter("\"$method\" ->", "")
                .let { source ->
                    if (nextMethod == null) source else source.substringBefore("\"$nextMethod\" ->")
                }
            assertTrue("$method must not run on the platform thread", branch.contains("runPlatformBlockingOperation"))
        }
    }

    @Test
    fun `dispatcher is single threaded bounded and never falls back to caller thread`() {
        val executor = mainActivity
            .substringAfter("private val platformBlockingExecutor", "")
            .substringBefore("private const val AUTO_RELEASE_REMINDER_PREFERENCES")

        assertTrue(executor.contains("ThreadPoolExecutor("))
        assertTrue(executor.contains("ArrayBlockingQueue<Runnable>"))
        assertTrue(executor.contains("PLATFORM_BLOCKING_QUEUE_CAPACITY"))
        assertTrue(executor.contains("ThreadPoolExecutor.AbortPolicy()"))
        assertFalse(executor.contains("CallerRunsPolicy"))
    }

    @Test
    fun `background outcomes are delivered on the main handler`() {
        val dispatcher = mainActivity
            .substringAfter("private fun <T> runPlatformBlockingOperation", "")
            .substringBefore("private fun isTelevision")
        val executeIndex = dispatcher.indexOf("platformBlockingExecutor.execute")
        val postIndex = dispatcher.indexOf("platformResultHandler.post")

        assertTrue(executeIndex >= 0)
        assertTrue(postIndex > executeIndex)
        assertTrue(dispatcher.contains("RejectedExecutionException"))
        assertTrue(dispatcher.contains("ANDROID_TV_BUSY"))
    }

    @Test
    fun `notification permission prompt remains on the main-thread completion path`() {
        val sync = mainActivity
            .substringAfter("private fun syncEpisodeReleaseNotifications", "")
            .substringBefore("private fun requestEpisodeReleaseNotificationPermissionIfNeeded")
        val permission = mainActivity
            .substringAfter("private fun requestEpisodeReleaseNotificationPermissionIfNeeded", "")
            .substringBefore("private fun autoReleaseReminderPendingIntent")
        val channelBranch = mainActivity
            .substringAfter("\"syncEpisodeReleaseNotifications\" ->", "")
            .substringBefore("\"clearPreferredFrameRate\" ->")

        assertFalse(sync.contains("requestPermissions("))
        assertTrue(permission.contains("requestPermissions("))
        assertTrue(permission.contains("isFinishing || isDestroyed"))
        assertTrue(channelBranch.contains("onSuccess = { scheduledCount ->"))
        assertTrue(channelBranch.contains("requestEpisodeReleaseNotificationPermissionIfNeeded(scheduledCount)"))
    }

    private fun mainActivitySource(): String {
        val workingDirectory = System.getProperty("user.dir") ?: "."
        val source = generateSequence(File(workingDirectory)) { it.parentFile }
            .take(7)
            .flatMap { directory ->
                sequenceOf(
                    File(directory, "src/main/kotlin/dev/animetv/anime_tv/MainActivity.kt"),
                    File(directory, "app/src/main/kotlin/dev/animetv/anime_tv/MainActivity.kt"),
                    File(directory, "android/app/src/main/kotlin/dev/animetv/anime_tv/MainActivity.kt"),
                )
            }
            .firstOrNull(File::isFile)
            ?: error("Missing MainActivity.kt")
        return source.readText()
    }
}
