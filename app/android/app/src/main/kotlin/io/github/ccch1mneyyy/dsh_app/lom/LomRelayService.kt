package io.github.ccch1mneyyy.dsh_app.lom

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings

/**
 * Keeps the Lom relay connection alive while the app is in the background
 * (the cloud relay does not queue for offline phones, doc §05). Minimal,
 * modeled on PetOverlayService: its own channel and id, `START_NOT_STICKY`,
 * `FOREGROUND_SERVICE_TYPE_SPECIAL_USE` on API 34+. The Dart side owns
 * the WebSocket and the reconnect schedule; this service only holds the
 * foreground slot. Start/stop via [LomRelayPlugin] (channel `dsh/lom_relay`).
 */
class LomRelayService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification(), foregroundType())
        running = true
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun foregroundType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else {
            0
        }

    private fun buildNotification(): Notification {
        ensureChannel(this)
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(AppStrings.get(this, R.string.lom_running))
            .setOngoing(true)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "lom_relay"
        private const val NOTIFICATION_ID = 4102

        @Volatile
        var running: Boolean = false
            private set

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    AppStrings.get(context, R.string.lom_channel),
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }

        fun ensure(context: Context, on: Boolean) {
            val intent = Intent(context, LomRelayService::class.java)
            if (on) {
                if (running) return
                context.startForegroundService(intent)
            } else {
                context.stopService(intent)
            }
        }
    }
}
