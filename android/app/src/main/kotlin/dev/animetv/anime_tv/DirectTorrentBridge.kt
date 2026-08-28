package dev.animetv.anime_tv

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.system.Os
import android.system.OsConstants
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Privacy-preserving platform-channel facade for direct torrent playback. */
object DirectTorrentBridge {
    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newCachedThreadPool { task ->
        Thread(task, "TetoTV-direct-torrent-worker").apply { isDaemon = true }
    }
    private var active: DirectTorrentManager? = null
    private var activeSessionId: String? = null
    private var activeRequestId: String? = null

    fun handle(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ): Boolean = when (call.method) {
        "getDirectTorrentCapability" -> {
            result.success(capability())
            true
        }
        "startDirectTorrent" -> {
            start(context.applicationContext, call, result)
            true
        }
        "stopDirectTorrent" -> {
            stop(context.applicationContext, call.argument<String>("sessionId"), result)
            true
        }
        "cancelDirectTorrentStart" -> {
            cancelStart(
                context.applicationContext,
                call.argument<String>("requestId"),
                result,
            )
            true
        }
        else -> false
    }

    private fun capability(): Map<String, Any> {
        val supportedAbi = supportsDirectTorrentRuntime(
            processIs64Bit = Process.is64Bit(),
            supportedAbis = Build.SUPPORTED_ABIS.toList(),
            pageSizeBytes = runCatching {
                Os.sysconf(OsConstants._SC_PAGESIZE)
            }.getOrDefault(-1L),
        )
        return mapOf(
            "supported" to supportedAbi,
            "engine" to if (supportedAbi) "libtorrent4j" else "unavailable",
            "maximumFileBytes" to DIRECT_TORRENT_MAX_FILE_BYTES,
            "temporaryStorage" to true,
            "supportsSeeking" to true,
        )
    }

    private fun start(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        if (capability()["supported"] != true) {
            result.error(
                "DIRECT_TORRENT_UNSUPPORTED_DEVICE",
                "Direct torrent playback is unavailable on this device.",
                null,
            )
            return
        }
        val magnet = call.argument<String>("magnet").orEmpty()
        val requestId = call.argument<String>("requestId")?.takeIf {
            it.length in 8..128
        }
        if (requestId == null) {
            result.error(
                "DIRECT_TORRENT_INVALID_REQUEST",
                "Direct torrent playback received an invalid request.",
                null,
            )
            return
        }
        val episode = call.argument<Number>("episode")?.toInt()
        val requestedSeason = call.argument<Number>("season")
            ?.toInt()
            ?.takeIf { it in 1..999 }
        val preferredFileIndex = call.argument<Number>("preferredFileIndex")?.toInt()
        val manager = synchronized(lock) {
            if (active != null) null else DirectTorrentManager(context).also { created ->
                active = created
                activeSessionId = null
                activeRequestId = requestId
            }
        }
        if (manager == null) {
            result.error(
                "DIRECT_TORRENT_BUSY",
                "Another direct torrent stream is already active.",
                null,
            )
            return
        }
        runCatching { DirectTorrentPlaybackService.start(context) }.onFailure {
            synchronized(lock) {
                if (active === manager) active = null
                if (activeRequestId == requestId) activeRequestId = null
            }
            runCatching { manager.close() }
            stopServiceIfIdle(context)
            result.error(
                "DIRECT_TORRENT_SERVICE_FAILED",
                "Android could not start direct torrent playback.",
                null,
            )
            return
        }
        worker.execute {
            try {
                val started = manager.start(
                    magnet,
                    episode,
                    preferredFileIndex,
                    requestedSeason,
                )
                val stillActive = synchronized(lock) {
                    if (active === manager && activeRequestId == requestId) {
                        activeSessionId = started.sessionId
                        true
                    } else {
                        false
                    }
                }
                if (!stillActive) {
                    manager.close()
                    mainHandler.post {
                        result.error(
                            "DIRECT_TORRENT_CANCELLED",
                            "Direct torrent playback was cancelled.",
                            null,
                        )
                    }
                    return@execute
                }
                mainHandler.post {
                    result.success(
                        mapOf(
                            "sessionId" to started.sessionId,
                            "url" to started.playbackUrl,
                            "size" to started.size,
                            "mimeType" to started.mimeType,
                            "selectedBasename" to started.selectedBasename,
                        ),
                    )
                }
            } catch (error: DirectTorrentException) {
                synchronized(lock) {
                    if (active === manager) {
                        active = null
                        activeSessionId = null
                        activeRequestId = null
                    }
                }
                stopServiceIfIdle(context)
                mainHandler.post { result.error(error.code, error.message, null) }
            } catch (_: Throwable) {
                synchronized(lock) {
                    if (active === manager) {
                        active = null
                        activeSessionId = null
                        activeRequestId = null
                    }
                }
                runCatching { manager.close() }
                stopServiceIfIdle(context)
                mainHandler.post {
                    result.error(
                        "DIRECT_TORRENT_START_FAILED",
                        "Direct torrent playback could not start.",
                        null,
                    )
                }
            }
        }
    }

    private fun stop(
        context: Context,
        sessionId: String?,
        result: MethodChannel.Result,
    ) {
        val manager = synchronized(lock) {
            if (sessionId.isNullOrBlank() || sessionId != activeSessionId) {
                null
            } else {
                active.also {
                    active = null
                    activeSessionId = null
                    activeRequestId = null
                }
            }
        }
        if (manager == null) {
            result.success(false)
            return
        }
        worker.execute {
            runCatching { manager.close() }
            stopServiceIfIdle(context)
            mainHandler.post { result.success(true) }
        }
    }

    private fun cancelStart(
        context: Context,
        requestId: String?,
        result: MethodChannel.Result,
    ) {
        val manager = synchronized(lock) {
            if (
                requestId.isNullOrBlank() ||
                requestId != activeRequestId ||
                activeSessionId != null
            ) {
                null
            } else {
                active.also {
                    active = null
                    activeRequestId = null
                }
            }
        }
        if (manager == null) {
            result.success(false)
            return
        }
        worker.execute {
            runCatching { manager.close() }
            stopServiceIfIdle(context)
            mainHandler.post { result.success(true) }
        }
    }

    fun stopAllAsync(context: Context) {
        worker.execute {
            stopAllBlocking()
            stopServiceIfIdle(context.applicationContext)
        }
    }

    fun stopAllBlocking() {
        val manager = synchronized(lock) {
            active.also {
                active = null
                activeSessionId = null
                activeRequestId = null
            }
        }
        runCatching { manager?.close() }
    }

    private fun stopServiceIfIdle(context: Context) {
        synchronized(lock) {
            if (active == null) DirectTorrentPlaybackService.stop(context)
        }
    }
}
