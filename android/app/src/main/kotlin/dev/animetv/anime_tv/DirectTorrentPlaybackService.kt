package dev.animetv.anime_tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Runs the stop decision and Android's start-id check as one operation. The
 * framework returns false when a newer start was issued, preserving that newer
 * playback lease even if it interleaves with an older stop command.
 */
internal fun shouldStopDirectTorrentService(
    action: String?,
    startId: Int,
    stopSelfResult: (Int) -> Boolean,
): Boolean = action == DirectTorrentPlaybackService.ACTION_STOP && stopSelfResult(startId)

/**
 * Keeps peer networking and the loopback MPV stream alive only while a direct
 * torrent playback lease is active. It never restarts itself after process
 * death; abandoned cache directories are pruned on the next explicit start.
 */
class DirectTorrentPlaybackService : Service() {
    override fun onCreate() {
        super.onCreate()
        createChannel()
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification(),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                } else {
                    0
                },
            )
        } catch (error: Throwable) {
            throw error
        }
        // Persist diagnostics only after satisfying Android's foreground
        // deadline; storage I/O must never delay service promotion.
        AnonymousCrashStore.recordBreadcrumb(this, "direct_torrent_service_created")
        AnonymousCrashStore.recordBreadcrumb(this, "direct_torrent_service_foreground")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        shouldStopDirectTorrentService(intent?.action, startId) { commandStartId ->
            stopSelfResult(commandStartId)
        }
        // Do not remove the foreground notification here. Framework teardown
        // removes it when the accepted stop completes. If a newer START races
        // in and cancels teardown, the surviving service remains foreground.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        DirectTorrentBridge.stopAllAsync(applicationContext)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        AnonymousCrashStore.recordBreadcrumb(this, "direct_torrent_service_destroyed")
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Direct torrent playback",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown only while TetoTV streams directly from torrent peers."
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun notification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let { intent ->
            PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("TetoTV direct torrent")
            .setContentText("Streaming through public peers")
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    companion object {
        internal const val ACTION_START =
            "dev.animetv.anime_tv.action.START_DIRECT_TORRENT_PLAYBACK"
        internal const val ACTION_STOP =
            "dev.animetv.anime_tv.action.STOP_DIRECT_TORRENT_PLAYBACK"
        private const val CHANNEL_ID = "tetotv_direct_torrent"
        private const val NOTIFICATION_ID = 7319

        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, DirectTorrentPlaybackService::class.java).setAction(ACTION_START),
            )
        }

        fun stop(context: Context) {
            // Queue STOP behind the corresponding START. A fresh service still
            // promotes in onCreate before processing STOP, satisfying Android's
            // foreground-service contract even for immediate cancellation.
            runCatching {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, DirectTorrentPlaybackService::class.java).setAction(ACTION_STOP),
                )
            }
        }
    }
}
