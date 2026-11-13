package com.nexus.nexus_audio.pc

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/** ABP v2 client (docs/SPEC.md §7 in nexus-utilities): TLS with a pinned certificate, one JSON hello line. */
object Abp2 {
    const val DEFAULT_PORT = 8010

    class Abp2Exception(val code: String, message: String) : Exception(message)

    data class Enrolled(val deviceId: String, val token: String, val fingerprint: String)

    fun fingerprintOf(der: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(der).joinToString("") { "%02X".format(it) }

    /** Pins [pin] when given; otherwise accepts any certificate and records it (trust on first use). */
    private class PinTrust(private val pin: String?) : X509TrustManager {
        @Volatile var seen: String? = null
        override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String?) {
            val fp = fingerprintOf(chain[0].encoded)
            seen = fp
            if (pin != null && !pin.equals(fp, ignoreCase = true)) {
                throw CertificateException("PC certificate does not match the paired one")
            }
        }
        override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String?) =
            throw CertificateException("client certificates are not used")
        override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
    }

    private fun connect(host: String, port: Int, pin: String?): Pair<SSLSocket, String> {
        val trust = PinTrust(pin)
        val ctx = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
        val raw = Socket()
        try {
            raw.connect(InetSocketAddress(host, port), 4000)
            raw.tcpNoDelay = true
            val s = ctx.socketFactory.createSocket(raw, host, port, true) as SSLSocket
            s.soTimeout = 10_000
            s.startHandshake()
            return s to (trust.seen ?: throw Abp2Exception("TLS", "no server certificate"))
        } catch (e: Exception) {
            try { raw.close() } catch (_: Exception) { }
            throw e
        }
    }

    private fun hello(s: SSLSocket, msg: JSONObject): JSONObject {
        s.outputStream.write((msg.toString() + "\n").toByteArray())
        s.outputStream.flush()
        val buf = ByteArrayOutputStream()
        val inp = s.inputStream
        while (buf.size() < 4096) {
            val b = inp.read()
            if (b == -1 || b == '\n'.code) break
            buf.write(b)
        }
        if (buf.size() == 0) throw Abp2Exception("CLOSED", "PC closed the connection")
        val reply = JSONObject(buf.toString(Charsets.UTF_8.name()))
        if (!reply.optBoolean("ok")) {
            val err = reply.optJSONObject("error")
            throw Abp2Exception(err?.optString("code") ?: "ERROR", err?.optString("message") ?: "request refused")
        }
        return reply
    }

    fun enroll(host: String, port: Int, code: String, deviceName: String, pin: String?): Enrolled {
        val (s, fp) = connect(host, port, pin)
        s.use {
            val r = hello(it, JSONObject().put("abp", 2).put("op", "enroll").put("code", code).put("deviceName", deviceName))
            return Enrolled(r.getString("deviceId"), r.getString("token"), fp)
        }
    }

    fun publishHello(deviceId: String, token: String, target: String): JSONObject =
        JSONObject().put("abp", 2).put("op", "publish").put("deviceId", deviceId).put("token", token).put("target", target)

    fun subscribeHello(deviceId: String, token: String, source: String = "speakers"): JSONObject =
        JSONObject().put("abp", 2).put("op", "subscribe").put("deviceId", deviceId).put("token", token).put("source", source)

    /** Opens a publish stream; the caller writes the ABP v1 header and then PCM. */
    fun openPublish(host: String, port: Int, pin: String, deviceId: String, token: String, target: String): SSLSocket =
        openStream(host, port, pin, publishHello(deviceId, token, target), readTimeoutMs = 0)

    /**
     * Opens a subscribe stream; the PC then sends the 12-byte ABP v1 header and raw PCM. The phone sends
     * nothing after the hello. [readTimeoutMs] turns a silent dead link into a SocketTimeoutException
     * (the PC sends audio continuously, silence included).
     */
    fun openSubscribe(host: String, port: Int, pin: String, deviceId: String, token: String, readTimeoutMs: Int = 5_000): SSLSocket =
        openStream(host, port, pin, subscribeHello(deviceId, token), readTimeoutMs)

    private fun openStream(host: String, port: Int, pin: String, msg: JSONObject, readTimeoutMs: Int): SSLSocket {
        val (s, _) = connect(host, port, pin)
        try {
            hello(s, msg)
            s.soTimeout = readTimeoutMs
            return s
        } catch (e: Exception) {
            try { s.close() } catch (_: Exception) { }
            throw e
        }
    }
}
