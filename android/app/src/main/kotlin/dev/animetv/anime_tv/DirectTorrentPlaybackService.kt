package dev.animetv.anime_tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Keeps peer networking and the loopback MPV stream alive only while a direct
 * torrent playback lease is active. It never restarts itself after process
 * death; abandoned cache directories are pruned on the next explicit start.
 */
class DirectTorrentPlaybackService : Service() {
    override fun onCreate() {
        super.onCreate()
        createChannel()
        startForeground(NOTIFICATION_ID, notification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        DirectTorrentBridge.stopAllAsync(applicationContext)
        super.onTaskRemoved(rootIntent)
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
        private const val CHANNEL_ID = "tetotv_direct_torrent"
        private const val NOTIFICATION_ID = 7319

        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, DirectTorrentPlaybackService::class.java),
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DirectTorrentPlaybackService::class.java))
        }
    }
}
