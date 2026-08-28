package dev.animetv.anime_tv

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.net.toUri
import dev.animetv.anime_tv.security.AppDeepLinkPolicy

class AiringReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val mediaId = intent.getLongExtra("mediaId", 0)
        val episode = intent.getIntExtra("episode", 1)
        if (mediaId <= 0L || episode <= 0) return
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return
        val title = intent.getStringExtra("title") ?: "Anime"
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val automaticRelease = intent.getBooleanExtra("automaticRelease", false)
        val releaseKind = intent.getStringExtra("releaseKind")
        val channelId = if (automaticRelease) "new_episode_notifications" else "airing_reminders"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    if (automaticRelease) "New episodes" else "Airing reminders",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
        val open = Intent(
            Intent.ACTION_VIEW,
            AppDeepLinkPolicy.animeUri(mediaId, episode).toUri(),
            context,
            MainActivity::class.java,
        )
        val kindOffset = when (releaseKind) {
            "dub" -> 2
            "simulcast" -> 1
            else -> 0
        }
        val notificationId = ((mediaId * 31 + episode * 3L + kindOffset) and 0x7fffffff).toInt()
        val pending = PendingIntent.getActivity(
            context,
            notificationId,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val (notificationTitle, notificationText) = when {
            automaticRelease && releaseKind == "dub" ->
                "English dub available: $title" to "Episode $episode is scheduled to be available now."
            automaticRelease ->
                "New episode: $title" to "Episode $episode is scheduled to air now."
            else ->
                "$title is airing soon" to "Episode $episode starts in about 10 minutes."
        }
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.tetotv_ic_notification)
            .setContentTitle(notificationTitle)
            .setContentText(notificationText)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
        manager.notify(notificationId, notification)
    }
}
