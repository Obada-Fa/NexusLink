package com.nexus.nexus_audio.model

import java.io.IOException
import java.io.InputStream

/**
 * ABP v1 stream header.
 *
 * Wire format (12 bytes, big-endian):
 *   0..1  magic      b"AU"
 *   2     version    0x01
 *   3     format     0=s16le, 1=s32le, 2=f32le
 *   4     channels
 *   5..8  rate       32-bit unsigned BE
 *   9     streamType 0=speakers, 1=mic, 2=bridge
 *   10..11 reserved
 */
data class StreamInfo(
    val format: Int,
    val channels: Int,
    val rate: Int,
    val streamType: Int
) {
    companion object {
        const val HEADER_SIZE = 12

        const val FORMAT_S16LE = 0
        const val FORMAT_S32LE = 1
        const val FORMAT_F32LE = 2

        const val STREAM_SPEAKERS = 0
        const val STREAM_MIC = 1
        const val STREAM_BRIDGE = 2
        const val STREAM_DEVICE_AUDIO = 3
        const val STREAM_PARTY = 4

        private const val MAGIC = 0x4155 // "AU"
        private const val VERSION = 1

        @Throws(IOException::class)
        fun fromInputStream(input: InputStream): StreamInfo {
            val header = ByteArray(HEADER_SIZE)
            var read = 0
            while (read < HEADER_SIZE) {
                val n = input.read(header, read, HEADER_SIZE - read)
                if (n == -1) throw IOException("Connection closed before header")
                read += n
            }

            val magic = ((header[0].toInt() and 0xFF) shl 8) or (header[1].toInt() and 0xFF)
            val version = header[2].toInt() and 0xFF
            val format = header[3].toInt() and 0xFF
            val channels = header[4].toInt() and 0xFF
            val rate = ((header[5].toInt() and 0xFF) shl 24) or
                    ((header[6].toInt() and 0xFF) shl 16) or
                    ((header[7].toInt() and 0xFF) shl 8) or
                    (header[8].toInt() and 0xFF)
            val streamType = header[9].toInt() and 0xFF

            if (magic != MAGIC) throw IOException("Bad header magic: 0x${magic.toString(16)}")
            if (version != VERSION) throw IOException("Unsupported protocol version: $version")

            return StreamInfo(format, channels, rate, streamType)
        }
    }

    fun header(): ByteArray {
        return ByteArray(HEADER_SIZE).apply {
            this[0] = 'A'.code.toByte()
            this[1] = 'U'.code.toByte()
            this[2] = VERSION.toByte()
            this[3] = format.toByte()
            this[4] = channels.toByte()
            this[5] = (rate shr 24).toByte()
            this[6] = (rate shr 16).toByte()
            this[7] = (rate shr 8).toByte()
            this[8] = (rate and 0xFF).toByte()
            this[9] = streamType.toByte()
            this[10] = 0.toByte()
            this[11] = 0.toByte()
        }
    }

    fun formatLabel(): String = when (format) {
        FORMAT_S16LE -> "s16le"
        FORMAT_S32LE -> "s32le"
        FORMAT_F32LE -> "f32le"
        else -> "format-$format"
    }

    fun streamTypeLabel(): String = when (streamType) {
        STREAM_SPEAKERS -> "speakers"
        STREAM_MIC -> "mic"
        STREAM_BRIDGE -> "bridge"
        STREAM_DEVICE_AUDIO -> "device_audio"
        STREAM_PARTY -> "party"
        else -> "stream-$streamType"
    }
}
