package com.nexus.nexus_audio.pc

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjectionManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.nexus.nexus_audio.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * One foreground notification (with Stop) while any PC stream is on. Its foreground-service types follow the
 * live streams: microphone for the mic, mediaPlayback for PC audio, mediaProjection for device audio
 * (Android 14 checks each type against what the app is doing).
 *
 * In the Nexus app it sits next to the app's own LiveActivityService: its own channel ([CHANNEL_ID]) and
 * notification id ([NOTIFICATION_ID]); tapping it opens the host app through its launch intent.
 */
class PcStreamService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var watch: Job? = null
    private var lastStartId = 0
    private var currentTypes = -1
    private var hasProjection = false
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        PcStreamEngine.init(this)
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        when (intent?.action) {
            ACTION_STOP -> {
                goForeground() // a start must always end in startForeground, even when it is a stop
                PcStreamEngine.stopAll(user = true)
            }
            ACTION_PROJECTION -> startProjection(intent)
            else -> goForeground()
        }
        if (watch == null) {
            watch = scope.launch { PcStreamEngine.streams.collect { onStreams(it) } }
        }
        return START_NOT_STICKY
    }

    private fun startProjection(intent: Intent) {
        val code = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        else @Suppress("DEPRECATION") intent.getParcelableExtra(EXTRA_DATA)
        val pairing = PcStreamEngine.projectionPairing
        PcStreamEngine.projectionPairing = null
        // Android 14: the service must already run with the mediaProjection type before getMediaProjection().
        hasProjection = true
        if (code != Activity.RESULT_OK || data == null || pairing == null || !goForeground()) {
            hasProjection = false
            goForeground()
            PcStreamEngine.fail(PcStream.SEND_DEVICE, if (pairing == null) "Pair with your PC first." else "Phone audio sharing was not allowed.")
            return
        }
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val projection = try { mpm.getMediaProjection(code, data) } catch (e: Exception) { null }
        if (projection == null) {
            hasProjection = false
            goForeground()
            PcStreamEngine.fail(PcStream.SEND_DEVICE, "Android didn't hand over phone audio. Try again.")
            return
        }
        PcStreamEngine.startDeviceAudio(pairing, projection)
    }

    private fun onStreams(streams: Map<PcStream, StreamStatus>) {
        if (streams[PcStream.SEND_DEVICE]?.on != true) hasProjection = false
        if (streams.values.none { it.on }) {
            releaseLocks()
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            currentTypes = -1 // if a new start arrives before we're destroyed, it must call startForeground again
            stopSelf(lastStartId)
            return
        }
        acquireLocks()
        goForeground()
    }

    /** (Re)enters the foreground with the types the live streams need. False when Android refused. */
    private fun goForeground(): Boolean {
        val streams = PcStreamEngine.streams.value
        val types = typesFor(streams)
        val n = buildNotification(streams)
        return try {
            if (types != currentTypes) {
                ServiceCompat.startForeground(this, NOTIFICATION_ID, n, types)
                currentTypes = types
            } else {
                getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, n)
            }
            true
        } catch (e: Exception) {
            // SecurityException/ForegroundServiceStartNotAllowedException: e.g. mic permission missing.
            if (streams[PcStream.MIC]?.on == true && (types and micType()) != 0) {
                PcStreamEngine.fail(PcStream.MIC, "Android didn't allow the mic in the background. Open Nexus and try again.")
            }
            try {
                ServiceCompat.startForeground(this, NOTIFICATION_ID, n, playbackType())
                currentTypes = playbackType()
            } catch (_: Exception) { }
            false
        }
    }

    private fun typesFor(streams: Map<PcStream, StreamStatus>): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0
        var t = 0
        if (streams[PcStream.MIC]?.on == true) t = t or micType()
        if (streams[PcStream.PLAY_HERE]?.on == true) t = t or playbackType()
        if (hasProjection) t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        return if (t == 0) playbackType() else t
    }

    private fun micType() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
    private fun playbackType() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK else 0

    private fun buildNotification(streams: Map<PcStream, StreamStatus>): Notification {
        val pcName = PcStreamEngine.pcName ?: "your PC"
        val text = notificationText(streams).ifBlank { "Starting…" }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
        val open = launch?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val stop = PendingIntent.getService(
            this, 1, Intent(this, PcStreamService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.nexus_audio_ic_stat)
            .setContentTitle("Audio · $pcName")
            .setContentText(text)
            .setContentIntent(open)
            .addAction(0, "Stop", stop)
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return // the plugin's minSdk follows Flutter's (24)
        val ch = NotificationChannel(CHANNEL_ID, "PC audio", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shown while Nexus streams audio to or from your PC"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "NexusAudio:PcStreams").apply {
                    setReferenceCounted(false); acquire(12 * 60 * 60 * 1000L)
                }
        }
        if (wifiLock == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifiLock = runCatching { wm.createWifiLock(mode, "NexusAudio:PcStreams").apply { setReferenceCounted(false); acquire() } }.getOrNull()
        }
    }

    private fun releaseLocks() {
        runCatching { wakeLock?.takeIf { it.isHeld }?.release() }
        runCatching { wifiLock?.takeIf { it.isHeld }?.release() }
        wakeLock = null
        wifiLock = null
    }

    override fun onDestroy() {
        releaseLocks()
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val CHANNEL_ID = "nexus_audio_streams"
        const val NOTIFICATION_ID = 2001
        const val ACTION_STOP = "com.nexus.nexus_audio.action.STOP_PC_STREAMS"
        const val ACTION_PROJECTION = "com.nexus.nexus_audio.action.PC_PROJECTION"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_DATA = "data"

        /** Starts (or refreshes) the service; call from a user action while the app is visible. */
        fun ensure(ctx: Context) {
            try {
                ContextCompat.startForegroundService(ctx, Intent(ctx, PcStreamService::class.java))
            } catch (e: Exception) {
                // Background start refused: the streams keep running, just without the notification.
            }
        }

        /** Hands a MediaProjection consent result to the service, which starts the device-audio stream. */
        fun startProjection(ctx: Context, resultCode: Int, data: Intent) {
            ContextCompat.startForegroundService(
                ctx,
                Intent(ctx, PcStreamService::class.java).setAction(ACTION_PROJECTION)
                    .putExtra(EXTRA_RESULT_CODE, resultCode).putExtra(EXTRA_DATA, data)
            )
        }

        fun notificationText(streams: Map<PcStream, StreamStatus>): String =
            PcStream.entries.mapNotNull { k ->
                val st = streams[k] ?: return@mapNotNull null
                val name = when (k) {
                    PcStream.MIC -> "Mic → PC"
                    PcStream.PLAY_HERE -> "PC audio → phone"
                    PcStream.SEND_DEVICE -> "Phone audio → PC"
                }
                when (st.phase) {
                    Phase.OFF -> null
                    Phase.LIVE -> name
                    Phase.CONNECTING -> "$name (connecting)"
                    Phase.RETRYING -> "$name (reconnecting)"
                }
            }.joinToString(" · ")
    }
}
