package com.nexus.nexus_audio.pc

import android.content.Context
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.nexus.nexus_audio.audio.AudioCapture
import com.nexus.nexus_audio.audio.AudioPlayer
import com.nexus.nexus_audio.model.StreamInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Process-wide owner of the three PC streams, so they outlive the activity (and the Flutter engine) and the
 * notification's Stop action reaches them. [PcStreamService] keeps the process in the foreground while any
 * stream is on. Copied from Nexus Audio; the pairing now comes in per call (no PairingStore here).
 */
object PcStreamEngine {
    private lateinit var app: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _streams = MutableStateFlow(PcStream.entries.associateWith { StreamStatus() })
    val streams: StateFlow<Map<PcStream, StreamStatus>> = _streams.asStateFlow()

    private val _micLevel = MutableStateFlow(0f)
    val micLevel: StateFlow<Float> = _micLevel.asStateFlow()

    /** One-off messages that outlive the stream that raised them, e.g. "pair again". */
    private val _notices = MutableSharedFlow<Notice>(extraBufferCapacity = 16)
    val notices: SharedFlow<Notice> = _notices.asSharedFlow()

    data class Notice(val kind: PcStream, val text: String, val pairAgain: Boolean = false)

    /** Name of the PC the latest start used; the notification shows it. */
    @Volatile var pcName: String? = null
        private set

    /**
     * The pairing a device-audio start is waiting to use, held in memory between the MediaProjection
     * consent and [PcStreamService] receiving the token (so the token never travels in an Intent).
     */
    @Volatile var projectionPairing: PcPairing? = null

    private class Running(val session: PcStreamSession, val job: Job, val cleanup: () -> Unit)
    private val running = mutableMapOf<PcStream, Running>()

    fun init(context: Context) {
        if (!::app.isInitialized) app = context.applicationContext
    }

    val activeKinds: Set<PcStream> get() = _streams.value.filterValues { it.on }.keys

    // -- toggles --------------------------------------------------------------

    /** Starts the mic or the PC-audio stream. Device audio goes through [startDeviceAudio]. */
    @Synchronized
    fun start(kind: PcStream, pairing: PcPairing) {
        require(kind != PcStream.SEND_DEVICE)
        if (running.containsKey(kind)) return
        pcName = pairing.pcName
        Prefs.setWanted(app, kind, true)
        set(kind, StreamStatus(Phase.CONNECTING, "Connecting to ${pairing.pcName}…"))
        PcStreamService.ensure(app)
        when (kind) {
            PcStream.MIC -> startMic(pairing)
            PcStream.PLAY_HERE -> launch(kind, pairing, source = null, sink = { info -> TrackSink(AudioPlayer.create(info)) }) { }
            else -> Unit
        }
    }

    /** Called by [PcStreamService] once it holds the projection and runs with the mediaProjection type. */
    @Synchronized
    fun startDeviceAudio(pairing: PcPairing, projection: MediaProjection) {
        if (running.containsKey(PcStream.SEND_DEVICE)) { projection.stop(); return }
        pcName = pairing.pcName
        Prefs.setWanted(app, PcStream.SEND_DEVICE, true)
        // On before the session's first status, so the service never sees "nothing on" in between.
        set(PcStream.SEND_DEVICE, StreamStatus(Phase.CONNECTING, "Connecting to ${pairing.pcName}…"))
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            projection.stop()
            fail(PcStream.SEND_DEVICE, "Sharing phone audio needs Android 10 or newer.")
            return
        }
        val queue = DropOldestQueue()
        val capture = try {
            AudioCapture.createDeviceAudioCapture(projection, excludeOwnApp = true) { queue.offer(it) }
        } catch (e: Exception) { null }
        if (capture == null || !capture.start()) {
            capture?.stop()
            projection.stop()
            fail(PcStream.SEND_DEVICE, "Android didn't allow capturing phone audio.")
            return
        }
        val cb = object : MediaProjection.Callback() {
            override fun onStop() { stop(PcStream.SEND_DEVICE, user = true, detail = "Android stopped sharing phone audio.") }
        }
        projection.registerCallback(cb, Handler(Looper.getMainLooper()))
        val info = StreamInfo(StreamInfo.FORMAT_S16LE, capture.channels, capture.sampleRate, StreamInfo.STREAM_DEVICE_AUDIO)
        launch(PcStream.SEND_DEVICE, pairing, QueueSource(info, queue), null) {
            capture.stop()
            projection.unregisterCallback(cb)
            projection.stop()
        }
    }

    private fun startMic(pairing: PcPairing) {
        val queue = DropOldestQueue()
        var level = 0f
        val capture = try {
            AudioCapture.createMicCapture(44100, 1) { chunk ->
                level = Levels.smooth(level, Levels.peakS16(chunk))
                _micLevel.value = level
                queue.offer(chunk)
            }
        } catch (e: SecurityException) { null }
        if (capture == null || !capture.start()) {
            capture?.stop()
            fail(PcStream.MIC, "The microphone didn't start. Is mic access allowed for Nexus?")
            return
        }
        val info = StreamInfo(StreamInfo.FORMAT_S16LE, 1, 44100, StreamInfo.STREAM_MIC)
        launch(PcStream.MIC, pairing, QueueSource(info, queue), null) {
            capture.stop()
            _micLevel.value = 0f
        }
    }

    private fun launch(kind: PcStream, pairing: PcPairing, source: PcmSource?, sink: ((StreamInfo) -> PcmSink)?, cleanup: () -> Unit) {
        lateinit var session: PcStreamSession
        fun current() = running[kind]?.session === session
        session = PcStreamSession(kind, pairing, source, sink, onStatus = { st ->
            // Ignore late updates from a session that was already stopped or replaced.
            synchronized(this) { if (current()) set(kind, st) }
        })
        val job = scope.launch {
            val stop = session.run() ?: return@launch
            synchronized(this@PcStreamEngine) {
                if (!current()) return@launch
                if (stop.pairAgain) _notices.tryEmit(Notice(kind, stop.detail, pairAgain = true))
                // The detail stays on the stream too, so a screen that missed the notice still says why.
                stop(kind, user = true, detail = stop.detail)
            }
        }
        running[kind] = Running(session, job, cleanup)
    }

    /**
     * Turns a stream off. [user] means "the person wants it off" (toggle, Stop, auth failure), which also
     * forgets it for the next app start. A stop that comes from the process dying never gets here.
     */
    @Synchronized
    fun stop(kind: PcStream, user: Boolean = true, detail: String? = null) {
        if (user) Prefs.setWanted(app, kind, false)
        val r = running.remove(kind)
        if (r != null) {
            r.session.close()
            r.job.cancel()
            scope.launch { runCatching { r.cleanup() } }
        }
        set(kind, StreamStatus(Phase.OFF, detail))
    }

    @Synchronized
    fun stopAll(user: Boolean = true) {
        PcStream.entries.forEach { if (running.containsKey(it) || _streams.value[it]?.on == true) stop(it, user) }
    }

    /** A device-audio start that never got a projection (consent denied, service failed). */
    @Synchronized
    fun fail(kind: PcStream, detail: String) {
        if (kind == PcStream.SEND_DEVICE) Prefs.setWanted(app, kind, false)
        stop(kind, user = kind != PcStream.SEND_DEVICE, detail = detail)
    }

    private fun set(kind: PcStream, st: StreamStatus) = _streams.update { it + (kind to st) }

    // -- restore on app start -------------------------------------------------

    /** Reconnects what was on when the app was last closed. Returns whether device audio needs a tap. */
    @Synchronized
    fun restore(pairing: PcPairing?, micGranted: Boolean): Boolean {
        val plan = RestorePlan.of(Prefs.wanted(app), pairing != null, micGranted, running.keys)
        if (pairing != null) plan.start.forEach { start(it, pairing) }
        if (plan.deviceAudioHint) Prefs.setWanted(app, PcStream.SEND_DEVICE, false)
        return plan.deviceAudioHint
    }

    fun forgetWanted() = PcStream.entries.forEach { Prefs.setWanted(app, it, false) }

    private object Prefs {
        private fun p(c: Context) = c.getSharedPreferences("pc_streams", Context.MODE_PRIVATE)
        fun setWanted(c: Context, kind: PcStream, on: Boolean) = p(c).edit().putBoolean("want_${kind.name}", on).apply()
        fun wanted(c: Context): Set<PcStream> = PcStream.entries.filter { p(c).getBoolean("want_${it.name}", false) }.toSet()
    }

    private class QueueSource(override val info: StreamInfo, private val q: DropOldestQueue) : PcmSource {
        override fun clear() = q.clear()
        override fun poll(timeoutMs: Long): ByteArray? = q.poll(timeoutMs)
    }

    private class TrackSink(private val player: AudioPlayer) : PcmSink {
        init { player.play() }
        override fun write(buf: ByteArray, off: Int, len: Int) = player.write(buf, off, len)
        override fun close() = player.stop()
    }
}
