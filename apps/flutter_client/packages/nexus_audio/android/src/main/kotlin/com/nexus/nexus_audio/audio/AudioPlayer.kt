package com.nexus.nexus_audio.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import com.nexus.nexus_audio.model.StreamInfo

/**
 * Configures AudioTrack from an ABP StreamInfo header and plays raw PCM.
 */
class AudioPlayer private constructor(
    private val audioTrack: AudioTrack
) {
    companion object {
        fun create(streamInfo: StreamInfo, usageAlarm: Boolean = false): AudioPlayer {
            val encoding = when (streamInfo.format) {
                StreamInfo.FORMAT_S16LE -> AudioFormat.ENCODING_PCM_16BIT
                StreamInfo.FORMAT_S32LE -> AudioFormat.ENCODING_PCM_32BIT
                StreamInfo.FORMAT_F32LE -> AudioFormat.ENCODING_PCM_FLOAT
                else -> throw IllegalArgumentException("Unsupported format: ${streamInfo.format}")
            }

            val channelMask = when (streamInfo.channels) {
                1 -> AudioFormat.CHANNEL_OUT_MONO
                2 -> AudioFormat.CHANNEL_OUT_STEREO
                else -> throw IllegalArgumentException("Unsupported channels: ${streamInfo.channels}")
            }

            val minBuf = AudioTrack.getMinBufferSize(streamInfo.rate, channelMask, encoding)
            val bufferSize = minBuf * 4

            val usage = if (usageAlarm) AudioAttributes.USAGE_ALARM else AudioAttributes.USAGE_MEDIA

            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(usage)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(streamInfo.rate)
                        .setEncoding(encoding)
                        .setChannelMask(channelMask)
                        .build()
                )
                .setBufferSizeInBytes(bufferSize)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()

            return AudioPlayer(track)
        }
    }

    fun play() {
        audioTrack.play()
    }

    fun write(data: ByteArray, offset: Int = 0, length: Int = data.size) {
        var written = 0
        while (written < length) {
            val n = audioTrack.write(data, offset + written, length - written)
            if (n <= 0) break
            written += n
        }
    }

    fun stop() {
        try {
            audioTrack.stop()
        } catch (_: Exception) {
        }
        try {
            audioTrack.release()
        } catch (_: Exception) {
        }
    }
}
