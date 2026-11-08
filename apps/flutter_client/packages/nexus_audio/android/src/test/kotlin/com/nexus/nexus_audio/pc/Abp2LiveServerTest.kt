package com.nexus.nexus_audio.pc

import com.nexus.nexus_audio.model.StreamInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * End to end against the real PC server (`ubuntu/abp2.py serve`), with fake capture/playback commands.
 * Skipped unless ABP2_TEST_PORT and ABP2_TEST_CODE are set; see android/scripts/live-abp2-test.sh.
 *
 *   ABP2_TEST_HOST (default 127.0.0.1), ABP2_TEST_PORT, ABP2_TEST_CODE (a fresh invite secret),
 *   ABP2_TEST_SPEAKERS_OUT / ABP2_TEST_MIC_OUT (files the fake playback commands write),
 *   ABP2_TEST_REVOKE (shell command; "{id}" is replaced by the device id).
 */
class Abp2LiveServerTest {
    private val env = System.getenv()
    private val host = env["ABP2_TEST_HOST"] ?: "127.0.0.1"

    private class Sink : PcmSink {
        val out = ByteArrayOutputStream()
        override fun write(buf: ByteArray, off: Int, len: Int) = synchronized(out) { out.write(buf, off, len) }
        override fun close() {}
        fun size() = synchronized(out) { out.size() }
    }

    private class Source(override val info: StreamInfo, private val fill: Byte) : PcmSource {
        override fun clear() {}
        override fun poll(timeoutMs: Long): ByteArray? { Thread.sleep(10); return ByteArray(441 * info.channels * 2) { fill } }
    }

    private suspend fun waitFor(what: String, ms: Long = 8_000, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + ms
        while (!cond()) {
            if (System.currentTimeMillis() > end) throw AssertionError("timed out waiting for $what")
            delay(50)
        }
    }

    @Test fun pairSubscribePublishConcurrentlyThenRevoke() = runBlocking {
        val port = env["ABP2_TEST_PORT"]?.toIntOrNull()
        val code = env["ABP2_TEST_CODE"]
        assumeTrue("set ABP2_TEST_PORT and ABP2_TEST_CODE to run against a live server", port != null && code != null)
        port!!

        // 1. Pair (trust on first use, as with a typed code).
        val e = Abp2.enroll(host, port, code!!, "JVM test", pin = null)
        assertEquals(64, e.fingerprint.length)
        val pairing = PcPairing("test-pc", listOf("10.255.255.1", host), port, e.fingerprint, e.deviceId, e.token)

        // 2. Raw subscribe: ok, then the 12-byte v1 header, then PCM; the phone sends nothing.
        Abp2.openSubscribe(host, port, e.fingerprint, e.deviceId, e.token).use { s ->
            val info = StreamInfo.fromInputStream(s.getInputStream())
            assertEquals(StreamInfo(StreamInfo.FORMAT_S16LE, 2, 44100, StreamInfo.STREAM_SPEAKERS), info)
            val buf = ByteArray(4096)
            var got = 0
            while (got < 4096) got += s.getInputStream().read(buf, got, 4096 - got).also { check(it > 0) }
            assertTrue(buf.all { it == 1.toByte() || it == 2.toByte() }) // the fake capture's pattern
        }

        // 3. All three toggles at once, as sessions (the first host is unreachable: it must fall through).
        val statuses = ConcurrentHashMap<PcStream, StreamStatus>()
        val sink = Sink()
        val play = PcStreamSession(PcStream.PLAY_HERE, pairing, sinkFactory = { sink }, onStatus = { statuses[PcStream.PLAY_HERE] = it })
        val mic = PcStreamSession(PcStream.MIC, pairing, source = Source(StreamInfo(0, 1, 44100, StreamInfo.STREAM_MIC), 7),
            onStatus = { statuses[PcStream.MIC] = it })
        val dev = PcStreamSession(PcStream.SEND_DEVICE, pairing, source = Source(StreamInfo(0, 2, 48000, StreamInfo.STREAM_DEVICE_AUDIO), 5),
            onStatus = { statuses[PcStream.SEND_DEVICE] = it })
        val jobs = listOf(play, mic, dev).map { s -> async(Dispatchers.IO) { s.run() } }
        waitFor("all three live", 15_000) { statuses.size == 3 && statuses.values.all { it.phase == Phase.LIVE } }
        waitFor("PC audio on the phone") { sink.size() > 44100 }
        delay(500)
        mic.close(); dev.close()
        assertNull(withTimeout(5_000) { jobs[1].await() })
        assertNull(withTimeout(5_000) { jobs[2].await() })
        env["ABP2_TEST_MIC_OUT"]?.let { f ->
            waitFor("mic playback file") { File(f).length() > 0 }
            assertTrue(File(f).readBytes().all { it == 7.toByte() })
        }
        env["ABP2_TEST_SPEAKERS_OUT"]?.let { f ->
            waitFor("speakers playback file") { File(f).length() > 0 }
            assertTrue(File(f).readBytes().all { it == 5.toByte() })
        }

        // 4. Revoke while PC audio plays: the stream drops, the reconnect is refused, the loop stops with "pair again".
        val revoke = env["ABP2_TEST_REVOKE"]
        if (revoke != null) {
            val p = ProcessBuilder("sh", "-c", revoke.replace("{id}", e.deviceId)).redirectErrorStream(true).start()
            assertTrue(p.waitFor(10, TimeUnit.SECONDS) && p.exitValue() == 0)
            val stop = withTimeout(15_000) { jobs[0].await() }
            assertTrue("expected pair-again stop, got $stop", stop != null && stop.pairAgain)
        } else {
            play.close()
            assertNull(withTimeout(5_000) { jobs[0].await() })
        }
    }

    @Test fun wrongTokenIsUnauthenticated() = runBlocking {
        val port = env["ABP2_TEST_PORT"]?.toIntOrNull()
        val fp = env["ABP2_TEST_FP"]
        assumeTrue(port != null && fp != null)
        val q = LinkedBlockingQueue<StreamStatus>()
        val s = PcStreamSession(PcStream.PLAY_HERE, PcPairing("pc", listOf(host), port!!, fp!!, "nope", "nope"),
            sinkFactory = { Sink() }, onStatus = { q.put(it) })
        val stop = withTimeout(10_000) { s.run() }
        assertTrue(stop!!.pairAgain)
    }
}
