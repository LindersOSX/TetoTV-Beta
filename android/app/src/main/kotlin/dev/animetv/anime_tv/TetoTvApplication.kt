package dev.animetv.anime_tv

import android.os.Process
import io.flutter.app.FlutterApplication

class TetoTvApplication : FlutterApplication() {
    override fun onCreate() {
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
    }
}
