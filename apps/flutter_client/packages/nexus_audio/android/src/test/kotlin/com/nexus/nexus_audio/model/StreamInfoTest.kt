package com.nexus.nexus_audio.model

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream

class StreamInfoTest {

    @Test
    fun headerRoundTrip() {
        val info = StreamInfo(
            format = StreamInfo.FORMAT_S16LE,
            channels = 2,
            rate = 48000,
            streamType = StreamInfo.STREAM_PARTY
        )
        val header = info.header()
        assertEquals(StreamInfo.HEADER_SIZE, header.size)

        val parsed = StreamInfo.fromInputStream(ByteArrayInputStream(header))
        assertEquals(info.format, parsed.format)
        assertEquals(info.channels, parsed.channels)
        assertEquals(info.rate, parsed.rate)
        assertEquals(info.streamType, parsed.streamType)
    }

    @Test
    fun labels() {
        val party = StreamInfo(
            format = StreamInfo.FORMAT_S16LE,
            channels = 1,
            rate = 44100,
            streamType = StreamInfo.STREAM_PARTY
        )
        assertEquals("s16le", party.formatLabel())
        assertEquals("party", party.streamTypeLabel())
    }
}
