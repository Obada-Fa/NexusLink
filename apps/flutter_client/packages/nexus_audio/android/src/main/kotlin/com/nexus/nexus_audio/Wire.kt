package com.nexus.nexus_audio

import com.nexus.nexus_audio.pc.PcPairing
import com.nexus.nexus_audio.pc.PcStream
import com.nexus.nexus_audio.pc.PcStreamEngine
import com.nexus.nexus_audio.pc.Phase
import com.nexus.nexus_audio.pc.StreamStatus

/**
 * Wire format of the `nexus/audio` channels (docs/NEXUS-APP-PHASE1.md §5). Plain Kotlin, no Android
 * classes, so it is unit-tested on the JVM.
 */
object Wire {
    const val MIC_PERMISSION = "MIC_PERMISSION"
    const val CONSENT_DENIED = "CONSENT_DENIED"
    const val UNSUPPORTED = "UNSUPPORTED"
    const val BAD_ARGS = "BAD_ARGS"

    class BadArgs(message: String) : IllegalArgumentException(message)

    fun streamName(kind: PcStream): String = when (kind) {
        PcStream.MIC -> "mic"
        PcStream.PLAY_HERE -> "playHere"
        PcStream.SEND_DEVICE -> "sendDevice"
    }

    fun parseStream(v: Any?): PcStream = when (v) {
        "mic" -> PcStream.MIC
        "playHere" -> PcStream.PLAY_HERE
        "sendDevice" -> PcStream.SEND_DEVICE
        else -> throw BadArgs("unknown stream: $v")
    }

    fun phaseName(p: Phase): String = p.name.lowercase()

    /** `{pcName, hosts: [..], port, fingerprint, deviceId, token}`; anything missing or empty is [BadArgs]. */
    fun parsePairing(v: Any?): PcPairing {
        val m = v as? Map<*, *> ?: throw BadArgs("pairing is missing")
        fun str(key: String): String =
            (m[key] as? String)?.takeIf { it.isNotBlank() } ?: throw BadArgs("pairing.$key is missing")
        val hosts = (m["hosts"] as? List<*>)?.mapNotNull { (it as? String)?.takeIf { h -> h.isNotBlank() } }
        if (hosts.isNullOrEmpty()) throw BadArgs("pairing.hosts is empty")
        val port = when (val p = m["port"]) {
            is Int -> p
            is Long -> p.toInt()
            is Number -> p.toInt()
            else -> throw BadArgs("pairing.port is missing")
        }
        if (port !in 1..65535) throw BadArgs("pairing.port is out of range")
        return PcPairing(str("pcName"), hosts, port, str("fingerprint"), str("deviceId"), str("token"))
    }

    fun streamsMap(streams: Map<PcStream, StreamStatus>): Map<String, Any?> =
        PcStream.entries.associate { k ->
            val st = streams[k] ?: StreamStatus()
            streamName(k) to mapOf("phase" to phaseName(st.phase), "detail" to st.detail)
        }

    fun stateMap(streams: Map<PcStream, StreamStatus>, micLevel: Float): Map<String, Any?> =
        mapOf("streams" to streamsMap(streams), "micLevel" to micLevel.toDouble().coerceIn(0.0, 1.0))

    fun streamsEvent(streams: Map<PcStream, StreamStatus>): Map<String, Any?> =
        mapOf("type" to "streams", "streams" to streamsMap(streams))

    fun micLevelEvent(level: Float): Map<String, Any?> =
        mapOf("type" to "micLevel", "level" to level.toDouble().coerceIn(0.0, 1.0))

    fun noticeEvent(n: PcStreamEngine.Notice): Map<String, Any?> =
        mapOf("type" to "notice", "stream" to streamName(n.kind), "message" to n.text, "pairAgain" to n.pairAgain)

    /** Level rounded to 0.01 (0..1), so the meter's slow fall-off doesn't send an event per chunk. */
    fun quantizeLevel(level: Float): Float = Math.round(level.coerceIn(0f, 1f) * 100f) / 100f

    /** Minimum gap between `micLevel` events: at most 15 per second. */
    const val MIC_LEVEL_PERIOD_MS = 67L
}
