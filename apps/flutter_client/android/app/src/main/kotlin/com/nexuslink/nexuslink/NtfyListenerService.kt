package com.nexuslink.nexuslink

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
import android.os.PowerManager
import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean

class NtfyListenerService : Service() {
    private val running = AtomicBoolean(false)
    private var worker: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            running.set(false)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        val topic = intent?.getStringExtra(EXTRA_TOPIC)
            ?: getSharedPreferences(PREFS, MODE_PRIVATE).getString(KEY_TOPIC, null)
        startAsForeground()
        if (topic.isNullOrBlank()) {
            stopSelf()
            return START_NOT_STICKY
        }
        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit()
            .putString(KEY_TOPIC, topic)
            .apply()
        startLoop(topic)
        return START_STICKY
    }

    override fun onDestroy() {
        running.set(false)
        worker?.interrupt()
        worker = null
        releaseWakeLock()
        super.onDestroy()
    }

    private fun startAsForeground() {
        val notification = listenerNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                LISTENER_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(LISTENER_NOTIFICATION_ID, notification)
        }
        acquireWakeLock()
    }

    private fun startLoop(topic: String) {
        if (running.getAndSet(true)) return
        worker = Thread({
            var backoffMs = 1_000L
            while (running.get()) {
                try {
                    listen(topic)
                    backoffMs = 1_000L
                } catch (e: InterruptedException) {
                    break
                } catch (e: Exception) {
                    Log.w(TAG, "ntfy listen failed: ${e.message}")
                    try {
                        Thread.sleep(backoffMs)
                    } catch (_: InterruptedException) {
                        break
                    }
                    backoffMs = (backoffMs * 2).coerceAtMost(16_000L)
                }
            }
        }, "ntfy-sse").also { it.start() }
    }

    private fun listen(topic: String) {
        val url = URL("https://ntfy.sh/${topic}/sse")
        val conn = (url.openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 90_000
            setRequestProperty("Accept", "text/event-stream")
            setRequestProperty("Cache-Control", "no-cache")
            instanceFollowRedirects = true
        }
        try {
            val code = conn.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("ntfy sse HTTP $code")
            }
            BufferedReader(InputStreamReader(conn.inputStream)).use { reader ->
                var line: String?
                while (running.get()) {
                    line = reader.readLine() ?: break
                    if (!line.startsWith("data:")) continue
                    val data = line.substring(5).trim()
                    handleSseData(data)
                }
            }
        } finally {
            conn.disconnect()
        }
    }

    private fun handleSseData(data: String) {
        if (data.isEmpty() || data == "open" || data == "keepalive") return
        val json = try {
            JSONObject(data)
        } catch (_: Exception) {
            return
        }
        val event = json.optString("event")
        if (event == "open" || event == "keepalive") return

        var src = json
        val message = json.opt("message")
        if (message is String && message.trim().startsWith("{")) {
            src = try {
                JSONObject(message)
            } catch (_: Exception) {
                json
            }
        } else if (message is JSONObject) {
            src = message
        }

        val kind = src.optString("kind")
        if (uiResumed(this) && kind != "test") return

        val title = firstNonEmpty(
            src.optString("title"),
            json.optString("title"),
            "NexusLink",
        )
        val body = firstNonEmpty(
            src.optString("body"),
            if (src === json) json.optString("message") else "",
            title,
        )
        val permission = kind == "permission-request"
        showAlert(title, body, permission)
    }

    private fun showAlert(title: String, body: String, permission: Boolean) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val channelId = if (permission) CHANNEL_PERMISSIONS else CHANNEL_STATUS
        val builder = Notification.Builder(this, channelId)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(pending)
            .setAutoCancel(true)
        if (Build.VERSION.SDK_INT >= 24) {
            builder.setCategory(Notification.CATEGORY_MESSAGE)
        }
        nm.notify(if (permission) 1002 else 1001, builder.build())
    }

    private fun listenerNotification(): Notification {
        val pending = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_LISTENER)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("NexusLink alerts on")
            .setContentText("Waiting for agent updates from your PC")
            .setContentIntent(pending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_LISTENER,
                "Background alerts",
                NotificationManager.IMPORTANCE_MIN,
            ).apply {
                description = "Keeps NexusLink subscribed for agent alerts"
                setShowBadge(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_STATUS,
                "Agent Status",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Notifications when an AI agent finishes working"
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_PERMISSIONS,
                "Agent Permissions",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Notifications when an AI agent requests permission"
            },
        )
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "nexuslink:ntfy").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    companion object {
        private const val TAG = "NtfyListener"
        const val ACTION_START = "com.nexuslink.nexuslink.NTFY_START"
        const val ACTION_STOP = "com.nexuslink.nexuslink.NTFY_STOP"
        const val EXTRA_TOPIC = "topic"
        private const val PREFS = "nexuslink_ntfy"
        private const val KEY_TOPIC = "topic"
        private const val KEY_UI_RESUMED = "ui_resumed"
        private const val LISTENER_NOTIFICATION_ID = 42
        const val CHANNEL_LISTENER = "nexuslink_ntfy_listener"
        const val CHANNEL_STATUS = "agent_status"
        const val CHANNEL_PERMISSIONS = "agent_permissions"

        fun start(context: Context, topic: String) {
            val intent = Intent(context, NtfyListenerService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_TOPIC, topic)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, NtfyListenerService::class.java)
                .setAction(ACTION_STOP)
            try {
                context.startService(intent)
            } catch (_: Exception) {
                context.stopService(Intent(context, NtfyListenerService::class.java))
            }
        }

        fun setUiResumed(context: Context, resumed: Boolean) {
            context.getSharedPreferences(PREFS, MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_UI_RESUMED, resumed)
                .apply()
        }

        fun uiResumed(context: Context): Boolean {
            return context.getSharedPreferences(PREFS, MODE_PRIVATE)
                .getBoolean(KEY_UI_RESUMED, true)
        }

        private fun firstNonEmpty(vararg values: String): String {
            for (value in values) {
                if (value.isNotBlank()) return value
            }
            return ""
        }
    }
}
