package com.nexuslink.nexuslink

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object Credentials {
    fun remove(context:Context,host:String) {
        context.getSharedPreferences("devices",0).edit().remove(host).apply()
    }
    private const val alias = "nexuslink.devices.v2"
    private fun key(): SecretKey {
        val store=KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias,null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun put(context: Context, host:String,value:String) {
        val cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key())
        val encrypted=cipher.iv+cipher.doFinal(value.toByteArray())
        context.getSharedPreferences("devices",0).edit().putString(host,Base64.encodeToString(encrypted,Base64.NO_WRAP)).apply()
    }
    fun get(context:Context,host:String):String? {
        val raw=context.getSharedPreferences("devices",0).getString(host,null)?:return null
        return try {
            val bytes=Base64.decode(raw,Base64.NO_WRAP)
            val cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,key(),GCMParameterSpec(128,bytes.copyOfRange(0,12)))
            String(cipher.doFinal(bytes.copyOfRange(12,bytes.size)))
        } catch(e:Exception) { null }
    }
}
