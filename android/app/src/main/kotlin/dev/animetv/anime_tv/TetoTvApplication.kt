package dev.animetv.anime_tv

import android.os.Process
import android.os.Build
import io.flutter.app.FlutterApplication

class TetoTvApplication : FlutterApplication() {
    // The extension process must not initialize Flutter, account stores, or
    // crash-report storage. Its UID cannot access those resources anyway.
    private val isExtensionWorker: Boolean
        get() = if (Process.myUid() % 100_000 in 90_000..99_999) {
            true
        } else if (Build.VERSION.SDK_INT >= 28) {
            android.app.Application.getProcessName().endsWith(":aniyomi_worker")
        } else {
            runCatching {
                java.io.File("/proc/self/cmdline").readText()
                    .trimEnd('\u0000').endsWith(":aniyomi_worker")
            }.getOrDefault(false)
        }

    @Suppress("MissingSuperCall")
    override fun onCreate() {
        if (isExtensionWorker) return
        super.onCreate()
        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching {
                AnonymousCrashStore.storeUnhandledJavaCrash(this, thread, error)
            }
            if (previousHandler != null) {
                previousHandler.uncaughtException(thread, error)
            } else {
                Process.killProcess(Process.myPid())
            }
        }
        AnonymousCrashStore.recordBreadcrumb(this, "app_process_created")
    }

    override fun onTrimMemory(level: Int) {
        if (isExtensionWorker) return
        super.onTrimMemory(level)
        // Fixed OS categories only; recording must not interrupt normal memory
        // handling. Modern Android may send only UI-hidden/background levels.
        runCatching { AnonymousCrashStore.recordMemoryTrim(this, level) }
    }

    @Suppress("DEPRECATION")
    override fun onLowMemory() {
        if (isExtensionWorker) return
        super.onLowMemory()
        runCatching { AnonymousCrashStore.recordBreadcrumb(this, "memory_low_callback") }
    }
}
