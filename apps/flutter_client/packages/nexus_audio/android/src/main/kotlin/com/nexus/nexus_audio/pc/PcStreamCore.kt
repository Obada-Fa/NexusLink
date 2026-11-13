package com.nexus.nexus_audio.pc

import com.nexus.nexus_audio.model.StreamInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import java.io.IOException
import java.io.InputStream
import java.net.Socket
import java.util.concurrent.TimeUnit
import kotlin.math.abs

// Plain-JVM part of the PC streams: no Android classes here, so it is unit-tested against fakes and the real
// PC server. PcStreamEngine wires it to AudioRecord/AudioTrack and the foreground service.

/** The three independent PC streams on the PC tab. */
enum class PcStream(val label: String) {
    /** Phone mic → PC virtual mic (`publish`, target `virtual-mic`). */
    MIC("Use as PC mic"),
    /** PC speakers → phone (`subscribe`, source `speakers`). */
    PLAY_HERE("Play PC audio here"),
    /** Phone device audio (MediaProjection) → PC speakers (`publish`, target `speakers`). */
    SEND_DEVICE("Play phone audio on PC");

    val isPublish: Boolean get() = this != PLAY_HERE
    val target: String get() = if (this == MIC) "virtual-mic" else "speakers"
    /** Device audio needs a fresh MediaProjection consent, so it is never reconnected on app start. */
    val restorable: Boolean get() = this != SEND_DEVICE
}

enum class Phase { OFF, CONNECTING, LIVE, RETRYING }

data class StreamStatus(val phase: Phase = Phase.OFF, val detail: String? = null) {
    val on: Boolean get() = phase != Phase.OFF
}

/** Why one connection attempt ended. */
sealed class Outcome {
    /** The PC answered the hello with `ok:false`. */
    data class Refused(val code: String, val message: String) : Outcome()
    /** No address answered (network, TLS, timeout). */
    data class Unreachable(val reason: String) : Outcome()
    /** The stream was live and then dropped. */
    data class Dropped(val reason: String) : Outcome()
    /** Something on the phone failed (mic, projection, unsupported format); retrying won't help. */
    data class LocalFailure(val reason: String) : Outcome()
}

sealed class Decision {
    data class Retry(val delayMs: Long, val detail: String) : Decision()
    data class Stop(val detail: String, val pairAgain: Boolean = false) : Decision()
}

object ReconnectPolicy {
    const val RETRY_MS = 2_000L

    fun decide(o: Outcome, pcName: String): Decision = when (o) {
        is Outcome.Refused -> when (o.code) {
            "UNAUTHENTICATED" -> Decision.Stop("$pcName no longer accepts this phone. Pair again.", pairAgain = true)
            "UNSUPPORTED", "BAD_REQUEST" -> Decision.Stop("$pcName can't do this (${o.message}). Update Nexus Audio on the PC.")
            "BUSY" -> Decision.Retry(RETRY_MS, "$pcName is busy (too many streams). Retrying…")
            else -> Decision.Retry(RETRY_MS, "$pcName refused: ${o.message}. Retrying…")
        }
        is Outcome.Unreachable -> Decision.Retry(RETRY_MS, "Can't reach $pcName (${o.reason}). Retrying…")
        is Outcome.Dropped -> Decision.Retry(RETRY_MS, "Lost $pcName (${o.reason}). Retrying…")
        is Outcome.LocalFailure -> Decision.Stop(o.reason)
    }
}

/** Formats `AudioPlayer` can play: s16le/s32le/f32le, mono or stereo, 8–192 kHz. Null when playable. */
fun unplayableReason(info: StreamInfo): String? = when {
    info.format !in listOf(StreamInfo.FORMAT_S16LE, StreamInfo.FORMAT_S32LE, StreamInfo.FORMAT_F32LE) ->
        "the PC sent an unknown sample format (${info.format})"
    info.channels !in 1..2 -> "the PC sent ${info.channels} channels; this phone plays mono or stereo"
    info.rate !in 8_000..192_000 -> "the PC sent an odd sample rate (${info.rate} Hz)"
    else -> null
}

/** "44.1 kHz · stereo", "48 kHz · mono". */
fun describeFormat(info: StreamInfo): String {
    val khz = if (info.rate % 1000 == 0) "${info.rate / 1000}" else "%.1f".format(java.util.Locale.ROOT, info.rate / 1000.0)
    return "$khz kHz · ${if (info.channels == 2) "stereo" else if (info.channels == 1) "mono" else "${info.channels} ch"}"
}

fun bytesPerFrame(info: StreamInfo): Int =
    info.channels * if (info.format == StreamInfo.FORMAT_S16LE) 2 else 4

/** Cuts a byte stream into whole frames so the player never gets half a sample. */
class FrameAligner(private val frameBytes: Int) {
    private val carry = ByteArray(frameBytes)
    private var carried = 0

    init { require(frameBytes > 0) }

    /** Feeds [len] bytes of [buf]; calls [out] with whole frames only (possibly not at all). */
    fun feed(buf: ByteArray, len: Int, out: (ByteArray, Int, Int) -> Unit) {
        var off = 0
        if (carried > 0) {
            val need = frameBytes - carried
            val take = minOf(need, len)
            System.arraycopy(buf, 0, carry, carried, take)
            carried += take
            off = take
            if (carried < frameBytes) return
            out(carry, 0, frameBytes)
            carried = 0
        }
        val whole = (len - off) / frameBytes * frameBytes
        if (whole > 0) out(buf, off, whole)
        val rest = len - off - whole
        if (rest > 0) {
            System.arraycopy(buf, off + whole, carry, 0, rest)
            carried = rest
        }
    }

    val pending: Int get() = carried
}

object Levels {
    /** Peak of a little-endian s16 chunk, 0..1. */
    fun peakS16(chunk: ByteArray, len: Int = chunk.size): Float {
        var peak = 0
        var i = 0
        while (i + 1 < len) {
            val s = (chunk[i].toInt() and 0xFF) or (chunk[i + 1].toInt() shl 8)
            val a = abs(s.toShort().toInt())
            if (a > peak) peak = a
            i += 2
        }
        return (peak / 32768f).coerceIn(0f, 1f)
    }

    /** Meter ballistics: jump up at once, fall back slowly. */
    fun smooth(previous: Float, peak: Float, fall: Float = 0.85f): Float = if (peak >= previous) peak else previous * fall
}

/** What [PcStreamSession] needs from the audio side, so the loop runs on the JVM with fakes. */
interface PcmSource {
    /** The header to publish (format, channels, rate of [poll]'s data). */
    val info: StreamInfo
    /** Drops anything queued while disconnected, so a reconnect starts with fresh audio. */
    fun clear()
    /** Next chunk, or null after [timeoutMs]. */
    fun poll(timeoutMs: Long): ByteArray?
}

interface PcmSink {
    fun write(buf: ByteArray, off: Int, len: Int)
    fun close()
}

/** Restore on app start: which streams to reconnect, and whether to hint that device audio needs a tap. */
data class RestorePlan(val start: Set<PcStream>, val deviceAudioHint: Boolean) {
    companion object {
        fun of(wanted: Set<PcStream>, paired: Boolean, micGranted: Boolean, alreadyOn: Set<PcStream>): RestorePlan {
            if (!paired) return RestorePlan(emptySet(), false)
            val start = wanted.filter { it.restorable && it !in alreadyOn && (it != PcStream.MIC || micGranted) }.toSet()
            return RestorePlan(start, PcStream.SEND_DEVICE in wanted && PcStream.SEND_DEVICE !in alreadyOn)
        }
    }
}

/**
 * One toggle's lifetime: connect (trying each PC address), stream, and reconnect per [ReconnectPolicy]
 * until stopped. [close] unblocks a blocking read or write from another thread.
 */
class PcStreamSession(
    val kind: PcStream,
    private val pairing: PcPairing,
    private val source: PcmSource? = null,
    private val sinkFactory: ((StreamInfo) -> PcmSink)? = null,
    private val onStatus: (StreamStatus) -> Unit,
    private val open: (host: String) -> Socket = { host -> defaultOpen(kind, pairing, host) },
    private val sleep: suspend (Long) -> Unit = { delay(it) },
    private val stallNanos: Long = 6_000_000_000L,
) {
    init {
        require(if (kind.isPublish) source != null else sinkFactory != null)
    }

    @Volatile private var socket: Socket? = null
    @Volatile private var stopped = false
    /** nanoTime when the current publish write began, 0 when not writing. */
    @Volatile private var writeSince = 0L
    @Volatile private var stalled = false

    /** Runs until a [Decision.Stop] (returned) or cancellation/[close] (returns null). */
    suspend fun run(): Decision.Stop? {
        var first = true
        while (currentCoroutineContext().isActive && !stopped) {
            onStatus(StreamStatus(if (first) Phase.CONNECTING else Phase.RETRYING, if (first) "Connecting to ${pairing.pcName}…" else null))
            val outcome = once()
            if (stopped || !currentCoroutineContext().isActive) return null
            when (val d = ReconnectPolicy.decide(outcome, pairing.pcName)) {
                is Decision.Stop -> return d
                is Decision.Retry -> {
                    onStatus(StreamStatus(Phase.RETRYING, d.detail))
                    try { sleep(d.delayMs) } catch (e: CancellationException) { return null }
                }
            }
            first = false
        }
        return null
    }

    fun close() {
        stopped = true
        try { socket?.close() } catch (_: Exception) { }
    }

    private fun once(): Outcome {
        var last: Outcome = Outcome.Unreachable("no address")
        var sock: Socket? = null
        for (host in pairing.hosts) {
            if (stopped) return Outcome.Dropped("stopped")
            try {
                sock = open(host)
                break
            } catch (e: Abp2.Abp2Exception) {
                return Outcome.Refused(e.code, e.message ?: e.code) // the PC answered: other addresses won't differ
            } catch (e: Exception) {
                last = Outcome.Unreachable(describeNetError(e))
            }
        }
        val s = sock ?: return last
        socket = s
        if (stopped) { closeQuietly(s); return Outcome.Dropped("stopped") }
        return try {
            if (kind.isPublish) publish(s) else subscribe(s)
        } finally {
            closeQuietly(s)
            socket = null
        }
    }

    private fun publish(s: Socket): Outcome {
        val src = source!!
        // Java sockets have no write timeout: a link that died without a reset would block a write for many
        // minutes once the send buffer fills. Close the socket when one write stalls, so we reconnect.
        stalled = false
        val dog = Thread({
            try {
                while (socket === s) {
                    Thread.sleep(500)
                    val t = writeSince
                    if (t != 0L && System.nanoTime() - t > stallNanos) { stalled = true; closeQuietly(s); break }
                }
            } catch (_: InterruptedException) { }
        }, "pc-stream-watchdog").apply { isDaemon = true; start() }
        return try {
            val out = s.getOutputStream()
            src.clear()
            write(out, src.info.header())
            onStatus(StreamStatus(Phase.LIVE, null))
            while (!stopped) {
                val chunk = src.poll(500) ?: continue
                write(out, chunk)
            }
            Outcome.Dropped("stopped")
        } catch (e: IOException) {
            Outcome.Dropped(if (stalled) "the PC stopped answering" else describeNetError(e))
        } finally {
            dog.interrupt()
        }
    }

    private fun write(out: java.io.OutputStream, b: ByteArray) {
        writeSince = System.nanoTime()
        try { out.write(b); out.flush() } finally { writeSince = 0L }
    }

    private fun subscribe(s: Socket): Outcome {
        val inp: InputStream = s.getInputStream()
        val info = try {
            StreamInfo.fromInputStream(inp)
        } catch (e: IOException) {
            return Outcome.Dropped(describeNetError(e))
        }
        unplayableReason(info)?.let { return Outcome.LocalFailure("Can't play PC audio: $it.") }
        val sink = try {
            sinkFactory!!(info)
        } catch (e: Exception) {
            return Outcome.LocalFailure("Can't play PC audio: ${e.message ?: e.javaClass.simpleName}.")
        }
        onStatus(StreamStatus(Phase.LIVE, describeFormat(info)))
        val aligner = FrameAligner(bytesPerFrame(info))
        val buf = ByteArray(8192)
        return try {
            while (!stopped) {
                val n = inp.read(buf)
                if (n < 0) return Outcome.Dropped("the PC ended the stream")
                aligner.feed(buf, n) { b, o, l -> sink.write(b, o, l) }
            }
            Outcome.Dropped("stopped")
        } catch (e: IOException) {
            Outcome.Dropped(describeNetError(e))
        } finally {
            sink.close()
        }
    }

    companion object {
        fun defaultOpen(kind: PcStream, p: PcPairing, host: String): Socket =
            if (kind.isPublish) Abp2.openPublish(host, p.port, p.fingerprint, p.deviceId, p.token, kind.target)
            else Abp2.openSubscribe(host, p.port, p.fingerprint, p.deviceId, p.token)

        private fun closeQuietly(s: Socket) = try { s.close() } catch (_: Exception) { }
    }
}

fun describeNetError(e: Throwable): String = when (e) {
    is java.net.SocketTimeoutException -> "no answer"
    is java.net.ConnectException, is java.net.NoRouteToHostException -> "not reachable"
    is java.net.UnknownHostException -> "unknown address"
    is javax.net.ssl.SSLException -> "the PC's identity doesn't match"
    is java.security.cert.CertificateException -> "the PC's identity doesn't match"
    else -> e.message?.takeIf { it.isNotBlank() } ?: e.javaClass.simpleName
}

/** Bounded queue that drops the oldest chunk when full (audio must stay live, not late). */
class DropOldestQueue(capacity: Int = 64) {
    private val q = java.util.concurrent.LinkedBlockingQueue<ByteArray>(capacity)
    fun offer(chunk: ByteArray) { while (!q.offer(chunk)) q.poll() }
    fun poll(timeoutMs: Long): ByteArray? = q.poll(timeoutMs, TimeUnit.MILLISECONDS)
    fun clear() = q.clear()
    val size: Int get() = q.size
}
