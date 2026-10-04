package com.nexuslink.nexuslink

import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import androidx.work.workDataOf

/** Explicit, non-exported entry point for phone and bridged watch actions. */
class NotificationActionReceiver:BroadcastReceiver() {
    override fun onReceive(context:Context,intent:Intent) {
        val prefs=context.getSharedPreferences("live",0)
        val operation=intent.getStringExtra("operationId")?:return
        val tag="action:$operation"
        val notificationManager=context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        fun report(state:String) {
            notificationManager.notify(tag,9002,NotificationCompat.Builder(context,"task_attention")
                .setSmallIcon(android.R.drawable.stat_notify_sync).setContentTitle("NexusLink action")
                .setContentText(state).setOnlyAlertOnce(true).setAutoCancel(true).build())
        }
        if(!prefs.getBoolean("requested",false)){report("Rejected: live activity has stopped");return}
        if(!prefs.getBoolean("actions",false)){report("Rejected: notification actions are off");return}
        val locked=(context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked
        if(locked && !prefs.getBoolean("actionsLocked",false)){report("Rejected: unlock the phone to act");return}
        val action=intent.getStringExtra("action")?:return
        val text=if(action=="reply")RemoteInput.getResultsFromIntent(intent)?.getCharSequence("replyText")?.toString()?.trim() else null
        if(action=="reply" && (text.isNullOrEmpty() || text.toByteArray(Charsets.UTF_8).size>8192)){
            report("Rejected: reply must contain at most 8 KiB of text");return
        }
        val row=PendingNotificationAction(
            operation,intent.getStringExtra("hostId")?:return,intent.getStringExtra("url")?:return,
            intent.getStringExtra("task")?:return,intent.getStringExtra("turn")?:return,
            intent.getLongExtra("source",0),action,intent.getStringExtra("request"),text,
            "queued",System.currentTimeMillis(),null)
        val store=ActivityStore(context)
        val fresh=try{store.claimAction(row)}catch(e:IllegalArgumentException){report("Rejected: ${e.message}");store.close();return}
        if(!fresh){report("Already ${store.action(operation)?.state ?: "handled"}");store.close();return}
        store.close()
        report("Sending")
        val work=OneTimeWorkRequest.Builder(NotificationActionWorker::class.java)
            .setInputData(workDataOf("operationId" to operation)).addTag("live-action").build()
        WorkManager.getInstance(context).enqueueUniqueWork("action:$operation",ExistingWorkPolicy.KEEP,work)
    }
}
