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
 * Keeps Dart's opaque loopback web proxy alive while another installed player
 * reads it. No provider URL, request header, title, or account data enters the
 * service or its notification.
 */
class ExternalPlaybackProxyService : Service() {
    override fun onCreate() {
        super.onCreate()
        createChannel()
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
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "External playback",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown only while an external player reads a TetoTV web stream."
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun notification(): Notification {
        val contentIntent = packageManager.getLaunchIntentForPackage(packageName)?.let { intent ->
            PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.tetotv_ic_notification)
            .setContentTitle("TetoTV external playback")
            .setContentText("Keeping the selected web stream available")
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "tetotv_external_playback"
        private const val NOTIFICATION_ID = 7321

        fun start(context: Context): Boolean = try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, ExternalPlaybackProxyService::class.java),
            )
            true
        } catch (_: RuntimeException) {
            false
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ExternalPlaybackProxyService::class.java))
        }
    }
}

object ExternalPlaybackProxyPolicy {
    fun isTetoWebProxyUri(rawUri: String?): Boolean {
        val uri = runCatching { java.net.URI(rawUri.orEmpty()) }.getOrNull() ?: return false
        return uri.scheme.equals("http", ignoreCase = true) &&
            uri.host == "127.0.0.1" &&
            uri.port in 1..65535 &&
            uri.rawPath.orEmpty().matches(OPAQUE_ROUTE) &&
            uri.rawQuery == null &&
            uri.rawFragment == null
    }

    private val OPAQUE_ROUTE = Regex(
        "^/tetotv-web/v1/[A-Za-z0-9_-]{32}/[A-Za-z0-9_-]{32}$",
    )
}
