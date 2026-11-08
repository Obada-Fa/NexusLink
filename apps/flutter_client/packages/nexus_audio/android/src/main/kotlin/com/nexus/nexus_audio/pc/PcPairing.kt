package com.nexus.nexus_audio.pc

import org.json.JSONArray
import org.json.JSONObject

/** Everything the engine needs to reach one paired PC (secrets included). It comes in per call from Dart; the plugin stores no pairing. */
data class PcPairing(
    val pcName: String,
    val hosts: List<String>,
    val port: Int,
    val fingerprint: String,
    val deviceId: String,
    val token: String
) {
    /** Never prints the token (data-class toString would). */
    override fun toString(): String = "PcPairing(pcName=$pcName, hosts=$hosts, port=$port, deviceId=$deviceId)"

    fun toJson(): String = JSONObject()
        .put("pcName", pcName).put("hosts", JSONArray(hosts)).put("port", port)
        .put("fingerprint", fingerprint).put("deviceId", deviceId).put("token", token).toString()

    companion object {
        fun fromJson(s: String): PcPairing {
            val o = JSONObject(s)
            val h = o.getJSONArray("hosts")
            return PcPairing(
                o.getString("pcName"), List(h.length()) { h.getString(it) }, o.getInt("port"),
                o.getString("fingerprint"), o.getString("deviceId"), o.getString("token")
            )
        }
    }
}
