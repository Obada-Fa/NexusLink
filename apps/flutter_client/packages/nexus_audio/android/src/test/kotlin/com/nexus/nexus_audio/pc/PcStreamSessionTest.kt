package com.nexus.nexus_audio.pc

import com.nexus.nexus_audio.model.StreamInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/** The reconnect loop over real TCP sockets; the ABP v2 hello is replaced by a plain connect. */
class PcStreamSessionTest {
    private val server = ServerSocket(0, 8, InetAddress.getLoopbackAddress())
    private val pairing = PcPairing("desk", listOf("127.0.0.1"), server.localPort, "FP", "dev", "tok")
    private val statuses: MutableList<StreamStatus> = Collections.synchronizedList(mutableListOf())

    @After fun tearDown() = server.close()

    private fun plainOpen(host: String): Socket = Socket(host, server.localPort)

    private class FakeSource(override val info: StreamInfo) : PcmSource {
        val q = LinkedBlockingQueue<ByteArray>()
        var cleared = 0
        override fun clear() { cleared++ }
        override fun poll(timeoutMs: Long): ByteArray? = q.poll(timeoutMs, TimeUnit.MILLISECONDS)
    }

    private class FakeSink : PcmSink {
        val out = ByteArrayOutputStream()
        val writes = mutableListOf<Int>()
        @Volatile var closed = false
        override fun write(buf: ByteArray, off: Int, len: Int) { synchronized(out) { writes += len; out.write(buf, off, len) } }
        override fun close() { closed = true }
    }

    @Test fun publishSendsHeaderThenPcmAndReconnectsAfterDrop() = runBlocking {
        val info = StreamInfo(StreamInfo.FORMAT_S16LE, 1, 44100, StreamInfo.STREAM_MIC)
        val src = FakeSource(info)
        val sleeps = mutableListOf<Long>()
        val session = PcStreamSession(PcStream.MIC, pairing, source = src, onStatus = { statuses += it },
            open = ::plainOpen, sleep = { sleeps += it })
        val job = async(Dispatchers.IO) { session.run() }

        // First connection: header (written after the queue is cleared), then one chunk; then drop it.
        server.accept().use { c ->
            val inp = c.getInputStream()
            val hdr = ByteArray(12)
            var n = 0
            while (n < 12) n += inp.read(hdr, n, 12 - n)
            assertArrayEquals(info.header(), hdr)
            src.q.put(byteArrayOf(1, 2, 3, 4))
            val pcm = ByteArray(4)
            n = 0
            while (n < 4) n += inp.read(pcm, n, 4 - n)
            assertArrayEquals(byteArrayOf(1, 2, 3, 4), pcm)
        }
        // Keep audio flowing so the session's next writes hit the dead socket and it reconnects.
        val feeding = java.util.concurrent.atomic.AtomicBoolean(true)
        val feeder = thread { while (feeding.get()) { src.q.put(byteArrayOf(9, 9)); Thread.sleep(20) } }
        val second = server.accept()
        val hdr = ByteArray(12)
        var n = 0
        while (n < 12) n += second.getInputStream().read(hdr, n, 12 - n)
        assertArrayEquals(info.header(), hdr)
        assertEquals(listOf(2_000L), sleeps)
        assertTrue(src.cleared >= 2) // stale audio dropped on each (re)connect
        assertTrue(statuses.any { it.phase == Phase.RETRYING && it.detail!!.startsWith("Lost desk") })
        feeding.set(false)
        feeder.join()

        session.close()
        assertNull(withTimeout(5_000) { job.await() })
        second.close()
    }

    @Test fun subscribeReadsHeaderAndFeedsWholeFrames() = runBlocking {
        val info = StreamInfo(StreamInfo.FORMAT_S16LE, 2, 44100, StreamInfo.STREAM_SPEAKERS)
        val sink = FakeSink()
        var sinkInfo: StreamInfo? = null
        val session = PcStreamSession(PcStream.PLAY_HERE, pairing, sinkFactory = { sinkInfo = it; sink },
            onStatus = { statuses += it }, open = ::plainOpen, sleep = { })
        val job = async(Dispatchers.IO) { session.run() }
        val pcm = ByteArray(4001) { (it % 251).toByte() }
        server.accept().use { c ->
            val out = c.getOutputStream()
            out.write(info.header()); out.flush()
            // Odd-sized writes so frames straddle reads.
            var off = 0
            for (n in listOf(3, 500, 1, 1497, 2000)) { out.write(pcm, off, n); out.flush(); off += n; Thread.sleep(5) }
            Thread.sleep(100)
        }
        // After the drop it reconnects; stop there.
        server.accept().use {
            session.close()
            assertNull(withTimeout(5_000) { job.await() })
        }
        assertEquals(info, sinkInfo)
        assertTrue(sink.closed)
        assertTrue(sink.writes.all { it % 4 == 0 })
        assertArrayEquals(pcm.copyOf(4000), sink.out.toByteArray())
        assertTrue(statuses.any { it.phase == Phase.LIVE })
    }

    @Test fun unauthenticatedStopsTheLoop() = runBlocking {
        var attempts = 0
        val session = PcStreamSession(PcStream.PLAY_HERE, pairing, sinkFactory = { FakeSink() }, onStatus = { statuses += it },
            open = { attempts++; throw Abp2.Abp2Exception("UNAUTHENTICATED", "bad credentials") }, sleep = { })
        val stop = withTimeout(5_000) { session.run() }
        assertTrue(stop!!.pairAgain)
        assertEquals(1, attempts)
    }

    @Test fun unreachableTriesEveryHostThenRetries() = runBlocking {
        val tried = mutableListOf<String>()
        var sleeps = 0
        val p = pairing.copy(hosts = listOf("100.64.0.9", "192.168.1.9"))
        lateinit var session: PcStreamSession
        session = PcStreamSession(PcStream.MIC, p, source = FakeSource(StreamInfo(0, 1, 44100, 1)), onStatus = { statuses += it },
            open = { h -> tried += h; throw java.net.ConnectException("refused") },
            sleep = { if (++sleeps == 3) session.close() })
        assertNull(withTimeout(5_000) { session.run() })
        assertEquals(listOf("100.64.0.9", "192.168.1.9").let { it + it + it }, tried)
        assertTrue(statuses.last().detail!!.contains("Can't reach desk"))
    }

    @Test fun unplayableHeaderStops() = runBlocking {
        val session = PcStreamSession(PcStream.PLAY_HERE, pairing, sinkFactory = { FakeSink() }, onStatus = { statuses += it },
            open = ::plainOpen, sleep = { })
        val job = async(Dispatchers.IO) { session.run() }
        server.accept().use { c -> c.getOutputStream().write(StreamInfo(StreamInfo.FORMAT_S16LE, 6, 44100, 0).header()); c.getOutputStream().flush()
            val stop = withTimeout(5_000) { job.await() }
            assertTrue(stop != null && !stop.pairAgain && stop.detail.contains("6 channels"))
        }
    }

    @Test fun stalledWriteIsDetectedAndReconnects() = runBlocking {
        // A peer that accepts but never reads: once the socket buffers fill, a write blocks forever.
        val big = object : PcmSource {
            override val info = StreamInfo(StreamInfo.FORMAT_S16LE, 2, 48000, StreamInfo.STREAM_DEVICE_AUDIO)
            override fun clear() {}
            override fun poll(timeoutMs: Long) = ByteArray(256 * 1024)
        }
        lateinit var session: PcStreamSession
        session = PcStreamSession(PcStream.SEND_DEVICE, pairing, source = big, onStatus = { statuses += it },
            open = ::plainOpen, sleep = { session.close() }, stallNanos = 300_000_000L)
        val job = async(Dispatchers.IO) { session.run() }
        val peer = server.accept()
        assertNull(withTimeout(20_000) { job.await() })
        peer.close()
        assertTrue(statuses.any { it.detail?.contains("stopped answering") == true })
    }
}
