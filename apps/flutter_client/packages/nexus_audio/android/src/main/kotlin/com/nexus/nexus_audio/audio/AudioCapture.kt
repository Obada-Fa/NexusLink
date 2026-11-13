package com.nexus.nexus_audio.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.projection.MediaProjection

class AudioCapture(
    private val recorder: AudioRecord,
    private val chunkMs: Int = 20,
    private val onChunk: (ByteArray) -> Unit
) {
    private var thread: Thread? = null
    private var running = false

    val sampleRate: Int get() = recorder.sampleRate
    val channels: Int get() = recorder.channelCount

    fun start(): Boolean {
        if (recorder.state != AudioRecord.STATE_INITIALIZED) return false
        running = true
        recorder.startRecording()
        val sampleRate = recorder.sampleRate
        val ch = recorder.channelCount
        val chunkBytes = sampleRate * ch * 2 * chunkMs / 1000
        thread = Thread({
            val buffer = ByteArray(if (chunkBytes > 0) chunkBytes else 4096)
            while (running) {
                val read = recorder.read(buffer, 0, buffer.size)
                if (read > 0) {
                    onChunk(buffer.copyOf(read))
                }
            }
        }, "AudioCapture").apply { start() }
        return true
    }

    fun stop() {
        running = false
        thread?.interrupt()
        thread?.join(500)
        thread = null
        try { recorder.stop() } catch (_: Exception) { }
        try { recorder.release() } catch (_: Exception) { }
    }

    companion object {
        fun createMicCapture(
            sampleRate: Int = 44100,
            channels: Int = 1,
            chunkMs: Int = 20,
            onChunk: (ByteArray) -> Unit
        ): AudioCapture? {
            val channelConfig = if (channels == 1) AudioFormat.CHANNEL_IN_MONO else AudioFormat.CHANNEL_IN_STEREO
            val encoding = AudioFormat.ENCODING_PCM_16BIT
            val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelConfig, encoding)
            val chunkBytes = sampleRate * channels * 2 * chunkMs / 1000
            val bufferSize = maxOf(minBuf, chunkBytes * 4)
            val rec = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate, channelConfig, encoding, bufferSize
            )
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                rec.release()
                return null
            }
            return AudioCapture(rec, chunkMs, onChunk)
        }

        @Suppress("NewApi")
        fun createDeviceAudioCapture(
            mediaProjection: MediaProjection,
            chunkMs: Int = 20,
            /** Leave out this app's own playback (e.g. PC audio playing here), so it isn't sent back. */
            excludeOwnApp: Boolean = false,
            onChunk: (ByteArray) -> Unit
        ): AudioCapture? {
            val captureConfig = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .apply { if (excludeOwnApp) excludeUid(android.os.Process.myUid()) }
                .build()

            val channelMask = AudioFormat.CHANNEL_IN_STEREO
            val encoding = AudioFormat.ENCODING_PCM_16BIT
            val sampleRate = 48000
            val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelMask, encoding)
            val chunkBytes = sampleRate * 2 * 2 * chunkMs / 1000
            val bufferSize = maxOf(minBuf, chunkBytes * 4)

            val format = AudioFormat.Builder()
                .setEncoding(encoding)
                .setSampleRate(sampleRate)
                .setChannelMask(channelMask)
                .build()

            val rec = AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(captureConfig)
                .setAudioFormat(format)
                .setBufferSizeInBytes(bufferSize)
                .build()

            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                rec.release()
                return null
            }
            return AudioCapture(rec, chunkMs, onChunk)
        }
    }
}
