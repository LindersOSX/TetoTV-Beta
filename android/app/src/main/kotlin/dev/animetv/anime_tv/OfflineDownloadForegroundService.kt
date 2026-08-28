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
 * Keeps Dart's active offline transfers eligible to run after Home/minimize.
 *
 * This service deliberately contains no media title, path, URL, provider, or
 * account data. It is non-sticky: a force-stop or process death ends the work,
 * and TetoTV restores resumable queue state the next time the app is opened.
 */
class OfflineDownloadForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        createChannel()
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification(),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            },
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!hasActiveLeases()) stopSelfResult(startId)
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTimeout(startId: Int, fgsType: Int) {
        clearLeases()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf(startId)
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Offline downloads",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown only while TetoTV saves media for offline viewing."
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
            .setContentTitle("TetoTV downloads")
            .setContentText("Saving media for offline viewing")
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(0, 0, true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "tetotv_offline_downloads"
        private const val NOTIFICATION_ID = 7320
        private val activeLeases = linkedSetOf<String>()

        fun acquire(context: Context, rawLeaseId: String?): Boolean {
            val leaseId = OfflineDownloadLeasePolicy.normalize(rawLeaseId) ?: return false
            synchronized(activeLeases) { activeLeases.add(leaseId) }
            return try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, OfflineDownloadForegroundService::class.java),
                )
                true
            } catch (_: RuntimeException) {
                synchronized(activeLeases) { activeLeases.remove(leaseId) }
                false
            }
        }

        fun release(context: Context, rawLeaseId: String?) {
            val leaseId = OfflineDownloadLeasePolicy.normalize(rawLeaseId) ?: return
            val shouldStop = synchronized(activeLeases) {
                activeLeases.remove(leaseId)
                activeLeases.isEmpty()
            }
            if (shouldStop) {
                context.stopService(Intent(context, OfflineDownloadForegroundService::class.java))
            }
        }

        private fun hasActiveLeases(): Boolean =
            synchronized(activeLeases) { activeLeases.isNotEmpty() }

        private fun clearLeases() {
            synchronized(activeLeases) { activeLeases.clear() }
        }
    }
}
