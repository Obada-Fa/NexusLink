package com.nexus.nexus_audio.pc

import com.nexus.nexus_audio.model.StreamInfo
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

class PcStreamLogicTest {
    @Test fun subscribeHelloMatchesSpec() {
        val h = Abp2.subscribeHello("dev1", "tok1")
        assertEquals(2, h.getInt("abp"))
        assertEquals("subscribe", h.getString("op"))
        assertEquals("dev1", h.getString("deviceId"))
        assertEquals("tok1", h.getString("token"))
        assertEquals("speakers", h.getString("source"))
        assertFalse(h.has("target"))
    }

    @Test fun publishHelloCarriesTarget() {
        assertEquals("virtual-mic", Abp2.publishHello("d", "t", PcStream.MIC.target).getString("target"))
        val h = Abp2.publishHello("d", "t", PcStream.SEND_DEVICE.target)
        assertEquals("publish", h.getString("op"))
        assertEquals("speakers", h.getString("target"))
        assertFalse(h.has("source"))
    }

    @Test fun streamKinds() {
        assertTrue(PcStream.MIC.isPublish)
        assertTrue(PcStream.SEND_DEVICE.isPublish)
        assertFalse(PcStream.PLAY_HERE.isPublish)
        assertFalse(PcStream.SEND_DEVICE.restorable)
        assertTrue(PcStream.MIC.restorable && PcStream.PLAY_HERE.restorable)
    }

    @Test fun unauthenticatedStopsAndAsksToPairAgain() {
        val d = ReconnectPolicy.decide(Outcome.Refused("UNAUTHENTICATED", "bad credentials"), "desk")
        assertTrue(d is Decision.Stop && d.pairAgain && d.detail.contains("Pair again"))
    }

    @Test fun networkTroubleRetriesEveryTwoSeconds() {
        for (o in listOf(Outcome.Unreachable("x"), Outcome.Dropped("y"), Outcome.Refused("BUSY", "busy"), Outcome.Refused("INTERNAL", "z"))) {
            val d = ReconnectPolicy.decide(o, "desk")
            assertTrue("$o", d is Decision.Retry && d.delayMs == 2_000L)
        }
    }

    @Test fun unsupportedAndLocalFailuresStopWithoutPairAgain() {
        for (o in listOf(Outcome.Refused("UNSUPPORTED", "no"), Outcome.Refused("BAD_REQUEST", "no"), Outcome.LocalFailure("mic"))) {
            val d = ReconnectPolicy.decide(o, "desk")
            assertTrue("$o", d is Decision.Stop && !d.pairAgain)
        }
    }

    @Test fun playableHeaders() {
        assertNull(unplayableReason(StreamInfo(StreamInfo.FORMAT_S16LE, 2, 44100, 0)))
        assertNull(unplayableReason(StreamInfo(StreamInfo.FORMAT_F32LE, 1, 48000, 0)))
        assertTrue(unplayableReason(StreamInfo(7, 2, 44100, 0)) != null)
        assertTrue(unplayableReason(StreamInfo(StreamInfo.FORMAT_S16LE, 6, 44100, 0)) != null)
        assertTrue(unplayableReason(StreamInfo(StreamInfo.FORMAT_S16LE, 2, 1000, 0)) != null)
        assertEquals(4, bytesPerFrame(StreamInfo(StreamInfo.FORMAT_S16LE, 2, 44100, 0)))
        assertEquals(8, bytesPerFrame(StreamInfo(StreamInfo.FORMAT_S32LE, 2, 44100, 0)))
        assertEquals(4, bytesPerFrame(StreamInfo(StreamInfo.FORMAT_F32LE, 1, 44100, 0)))
    }

    @Test fun formatLabels() {
        assertEquals("44.1 kHz · stereo", describeFormat(StreamInfo(0, 2, 44100, 0)))
        assertEquals("48 kHz · mono", describeFormat(StreamInfo(0, 1, 48000, 0)))
    }

    @Test fun frameAlignerOnlyEmitsWholeFramesAndKeepsOrder() {
        val a = FrameAligner(4)
        val out = ByteArrayOutputStream()
        val sizes = mutableListOf<Int>()
        val data = ByteArray(103) { it.toByte() }
        var off = 0
        for (n in listOf(1, 2, 7, 13, 3, 40, 37)) {
            a.feed(data.copyOfRange(off, off + n), n) { b, o, l -> sizes += l; out.write(b, o, l) }
            off += n
        }
        assertTrue(sizes.all { it % 4 == 0 })
        assertEquals(100, out.size())
        assertEquals(3, a.pending)
        assertArrayEquals(data.copyOf(100), out.toByteArray())
    }

    @Test fun peakOfS16() {
        assertEquals(0f, Levels.peakS16(ByteArray(8)), 0f)
        val loud = byteArrayOf(0, 0, 0x00, 0x80.toByte(), 0x10, 0) // 0, -32768, 16
        assertEquals(1f, Levels.peakS16(loud), 0.0001f)
        val half = byteArrayOf(0x00, 0x40) // 16384
        assertEquals(0.5f, Levels.peakS16(half), 0.0001f)
        assertEquals(0.5f, Levels.smooth(0.2f, 0.5f), 0f)
        assertEquals(0.85f * 0.5f, Levels.smooth(0.5f, 0.1f), 0.0001f)
    }

    @Test fun restorePlan() {
        val all = PcStream.entries.toSet()
        RestorePlan.of(all, paired = true, micGranted = true, alreadyOn = emptySet()).let {
            assertEquals(setOf(PcStream.MIC, PcStream.PLAY_HERE), it.start)
            assertTrue(it.deviceAudioHint)
        }
        RestorePlan.of(all, paired = true, micGranted = false, alreadyOn = emptySet()).let {
            assertEquals(setOf(PcStream.PLAY_HERE), it.start)
        }
        RestorePlan.of(setOf(PcStream.MIC), paired = true, micGranted = true, alreadyOn = setOf(PcStream.MIC)).let {
            assertTrue(it.start.isEmpty()); assertFalse(it.deviceAudioHint)
        }
        RestorePlan.of(all, paired = false, micGranted = true, alreadyOn = emptySet()).let {
            assertTrue(it.start.isEmpty()); assertFalse(it.deviceAudioHint)
        }
    }

    @Test fun dropOldestQueueStaysBounded() {
        val q = DropOldestQueue(3)
        for (i in 0 until 5) q.offer(byteArrayOf(i.toByte()))
        assertEquals(3, q.size)
        assertEquals(2, q.poll(10)!![0].toInt())
    }

    @Test fun notificationText() {
        val s = mapOf(
            PcStream.MIC to StreamStatus(Phase.LIVE),
            PcStream.PLAY_HERE to StreamStatus(Phase.RETRYING),
            PcStream.SEND_DEVICE to StreamStatus(),
        )
        assertEquals("Mic → PC · PC audio → phone (reconnecting)", PcStreamService.notificationText(s))
    }
}
