package com.aukmind.tincan

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log

/**
 * Keeps the process alive while the app is in the background so the
 * transport holds its relay connection and messages still arrive.
 *
 * It does no work of its own — the Go transport is already running in
 * this process, idling on one connection with keepalives — so the cost
 * is that idle connection, not this service.
 */
class TincanService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var stopper: Runnable? = null

    companion object {
        const val CHANNEL_ID = "tincan_background"
        const val NOTIFICATION_ID = 1
        const val EXTRA_STOP_AFTER_MINUTES = "stopAfterMinutes"

        fun start(context: Context, stopAfterMinutes: Int) {
            val intent = Intent(context, TincanService::class.java)
                .putExtra(EXTRA_STOP_AFTER_MINUTES, stopAfterMinutes)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TincanService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (e: Exception) {
            // Out of the daily dataSync allowance, or started from the
            // background where Android refuses it.
            Log.w("Tincan", "background service refused: $e")
            stopSelf()
            return START_NOT_STICKY
        }

        // 0 means stay until told otherwise.
        val minutes = intent?.getIntExtra(EXTRA_STOP_AFTER_MINUTES, 0) ?: 0
        stopper?.let { handler.removeCallbacks(it) }
        stopper = null
        Log.i("Tincan", "background service running, stopAfterMinutes=$minutes")
        if (minutes > 0) {
            val r = Runnable {
                Log.i("Tincan", "background window elapsed, stopping")
                stopSelf()
            }
            stopper = r
            handler.postDelayed(r, minutes * 60_000L)
        }
        // Not sticky: a restart after the process dies would hold the
        // notification up with no transport behind it.
        return START_NOT_STICKY
    }

    // Android 15 ends dataSync services that hit the daily cap here, and
    // crashes the app if they don't stop promptly.
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.i("Tincan", "background allowance used up, stopping")
        stopSelf()
    }

    override fun onDestroy() {
        stopper?.let { handler.removeCallbacks(it) }
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Background connection",
            // Silent: this is a status, not an alert.
            NotificationManager.IMPORTANCE_LOW,
        ).apply { description = "Shown while Tincan can receive messages in the background." }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        val tap = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Tincan is connected")
            .setContentText("Receiving messages in the background")
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentIntent(tap)
            .setOngoing(true)
            .build()
    }
}
