package com.nexus.nexus_audio

import com.nexus.nexus_audio.pc.PcStream
import com.nexus.nexus_audio.pc.PcStreamEngine
import com.nexus.nexus_audio.pc.Phase
import com.nexus.nexus_audio.pc.StreamStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class WireTest {
    private val good = mapOf(
        "pcName" to "Desk", "hosts" to listOf("192.168.1.5", "desk.local"), "port" to 8010,
        "fingerprint" to "AB:CD", "deviceId" to "dev1", "token" to "secret"
    )

    @Test fun parsesPairing() {
        val p = Wire.parsePairing(good)
        assertEquals("Desk", p.pcName)
        assertEquals(listOf("192.168.1.5", "desk.local"), p.hosts)
        assertEquals(8010, p.port)
        assertEquals("AB:CD", p.fingerprint)
        assertEquals("dev1", p.deviceId)
        assertEquals("secret", p.token)
    }

    @Test fun portMayArriveAsLong() {
        assertEquals(8010, Wire.parsePairing(good + ("port" to 8010L)).port)
    }

    @Test fun badPairingsAreBadArgs() {
        assertThrows(Wire.BadArgs::class.java) { Wire.parsePairing(null) }
        assertThrows(Wire.BadArgs::class.java) { Wire.parsePairing("nope") }
        assertThrows(Wire.BadArgs::class.java) { Wire.parsePairing(good - "token") }
        assertThrows(Wire.BadArgs::class.java) { Wire.parsePairing(good + ("token" to "")) }
        assertThrows(Wire.BadArgs::class.java) { Wire.parsePairing(good + ("hosts" to emptyList<String>())) }
        assertThrows(Wire.BadArgs::class.java) { Wire.parsePairing(good + ("port" to 0)) }
        assertThrows(Wire.BadArgs::class.java) { Wire.parsePairing(good + ("port" to "8010")) }
    }

    @Test fun pairingToStringHidesToken() {
        assertFalse(Wire.parsePairing(good).toString().contains("secret"))
    }

    @Test fun streamNamesRoundTrip() {
        PcStream.entries.forEach { assertEquals(it, Wire.parseStream(Wire.streamName(it))) }
        assertEquals("playHere", Wire.streamName(PcStream.PLAY_HERE))
        assertThrows(Wire.BadArgs::class.java) { Wire.parseStream("speakers") }
        assertThrows(Wire.BadArgs::class.java) { Wire.parseStream(null) }
    }

    @Test fun stateMapHasAllThreeStreams() {
        val m = Wire.stateMap(mapOf(PcStream.MIC to StreamStatus(Phase.RETRYING, "Lost Desk")), 1.5f)
        @Suppress("UNCHECKED_CAST") val streams = m["streams"] as Map<String, Map<String, Any?>>
        assertEquals(setOf("mic", "playHere", "sendDevice"), streams.keys)
        assertEquals(mapOf("phase" to "retrying", "detail" to "Lost Desk"), streams["mic"])
        assertEquals(mapOf("phase" to "off", "detail" to null), streams["sendDevice"])
        assertEquals(1.0, m["micLevel"]) // clamped
    }

    @Test fun events() {
        assertEquals("streams", Wire.streamsEvent(emptyMap())["type"])
        assertEquals(mapOf("type" to "micLevel", "level" to 0.5), Wire.micLevelEvent(0.5f))
        assertEquals(
            mapOf("type" to "notice", "stream" to "sendDevice", "message" to "Pair again.", "pairAgain" to true),
            Wire.noticeEvent(PcStreamEngine.Notice(PcStream.SEND_DEVICE, "Pair again.", pairAgain = true))
        )
    }

    @Test fun quantizeLevel() {
        assertEquals(0f, Wire.quantizeLevel(1e-20f))
        assertEquals(0f, Wire.quantizeLevel(0.004f))
        assertEquals(0.01f, Wire.quantizeLevel(0.006f))
        assertEquals(0.5f, Wire.quantizeLevel(0.501f))
        assertEquals(1f, Wire.quantizeLevel(3f))
        assertEquals(0f, Wire.quantizeLevel(-1f))
    }

    @Test fun micLevelIsAtMost15PerSecond() {
        assert(1000.0 / Wire.MIC_LEVEL_PERIOD_MS <= 15.0)
    }
}
