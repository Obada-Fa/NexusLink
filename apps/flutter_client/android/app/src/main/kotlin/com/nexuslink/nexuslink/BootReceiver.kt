package com.nexuslink.nexuslink

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Restarts PC monitoring after a reboot or app update, but only when the user
 * had it switched on ("requested") and this phone is still paired. Starting a
 * connectedDevice foreground service from these broadcasts is an allowed
 * background-start exemption on Android 12-15.
 */
class BootReceiver:BroadcastReceiver() {
    override fun onReceive(context:Context,intent:Intent) {
        if(intent.action!=Intent.ACTION_BOOT_COMPLETED && intent.action!=Intent.ACTION_MY_PACKAGE_REPLACED)return
        val prefs=context.getSharedPreferences("live",0)
        val host=prefs.getString("host","").orEmpty()
        if(!prefs.getBoolean("requested",false) || host.isEmpty())return
        if(Credentials.get(context,host)==null)return
        val start=Intent(context,LiveActivityService::class.java).putExtra("host",host)
        try {
            if(Build.VERSION.SDK_INT>=26)context.startForegroundService(start) else context.startService(start)
        } catch(e:Exception) {
            // Android refused; MainActivity resumes monitoring the next time the app opens.
            LiveActivityService.lastError="Monitoring could not restart after reboot: ${e.message}"
        }
    }
}
