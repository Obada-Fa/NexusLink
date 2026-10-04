package com.nexuslink.nexuslink

import android.app.NotificationManager
import android.app.KeyguardManager
import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.work.Worker
import androidx.work.WorkerParameters
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Delivers once within the short action window; never retries after reconnect. */
class NotificationActionWorker(context:Context,params:WorkerParameters):Worker(context,params) {
    companion object { private val deliveryLock=Any() }
    override fun doWork():Result = synchronized(deliveryLock) {
        val operation=inputData.getString("operationId")?:return@synchronized Result.success()
        val store=ActivityStore(applicationContext)
        try {
            val row=store.action(operation)?:return@synchronized Result.success()
            if(row.state!="queued")return@synchronized Result.success()
            fun report(state:String,reason:String?=null) {
                store.updateAction(operation,state,reason)
                val manager=applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.notify("action:$operation",9002,NotificationCompat.Builder(applicationContext,"task_attention")
                    .setSmallIcon(if(state=="accepted")android.R.drawable.stat_notify_sync else android.R.drawable.stat_notify_error)
                    .setContentTitle("NexusLink action").setContentText(if(reason.isNullOrBlank())state.replaceFirstChar{it.uppercase()} else "$state: $reason")
                    .setOnlyAlertOnce(true).setAutoCancel(true).build())
            }
            val deadline=row.created+30000
            if(System.currentTimeMillis()>=deadline){report("not sent","Action window expired");return@synchronized Result.success()}
            val prefs=applicationContext.getSharedPreferences("live",0)
            if(!prefs.getBoolean("requested",false)){
                report("not sent","Live activity stopped");return@synchronized Result.success()
            }
            if(!prefs.getBoolean("actions",false)){
                report("not sent","Notification actions were disabled");return@synchronized Result.success()
            }
            val locked=(applicationContext.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked
            if(locked && !prefs.getBoolean("actionsLocked",false)){
                report("not sent","Phone is locked");return@synchronized Result.success()
            }
            val credential=Credentials.get(applicationContext,row.url)
            if(credential==null){report("not sent","Pairing is unavailable");return@synchronized Result.success()}
            report("sending")
            val params=JSONObject().put("operationId",row.operation).put("hostId",row.hostId)
                .put("agentSessionId",row.task).put("expectedTurnId",row.turn)
                .put("sourceCursor",row.source).put("action",row.action)
            if(row.request!=null)params.put("requestId",row.request)
            if(row.text!=null)params.put("text",row.text)
            val first=rpcShared(row.url,credential,"activity.action",params,15000)
            val response=first.response
            if(response!=null && !response.has("error")){
                val result=response.optJSONObject("result")
                when(result?.optString("state")){
                    "succeeded"->{report("accepted");return@synchronized Result.success()}
                    "rejected"->{report("rejected",result.optString("reason"));return@synchronized Result.success()}
                    "uncertain"->{report("outcome unknown",result.optString("reason"));return@synchronized Result.success()}
                }
            }
            if(response?.has("error")==true){report("rejected",response.optString("error"));return@synchronized Result.success()}
            if(!first.sent){report("not sent","Host was unavailable");return@synchronized Result.success()}
            val remaining=(deadline-System.currentTimeMillis()).coerceAtMost(10000).coerceAtLeast(0)
            val checked=if(remaining>0)rpcShared(row.url,credential,"activity.actionStatus",JSONObject().put("operationId",operation),remaining).response else null
            val status=checked?.optJSONObject("result")
            when(status?.optString("state")){
                "succeeded"->report("accepted")
                "rejected"->report("rejected",status.optString("reason"))
                else->report("outcome unknown","Check the task on your phone")
            }
            Result.success()
        } finally {store.close()}
    }

    private data class RpcOutcome(val response:JSONObject?,val sent:Boolean)
    private fun rpcShared(url:String,credential:String,method:String,params:JSONObject,waitMs:Long):RpcOutcome {
        val shared=LiveActivityService.instance?.actionRpc(url,method,params,waitMs)
        return if(shared!=null)RpcOutcome(shared.response,shared.sent) else rpc(url,credential,method,params,waitMs)
    }
    private fun rpc(url:String,credential:String,method:String,params:JSONObject,waitMs:Long):RpcOutcome {
        val latch=CountDownLatch(1)
        val answer=AtomicReference<JSONObject?>()
        val sent=AtomicBoolean(false)
        val client=OkHttpClient.Builder().connectTimeout(5,TimeUnit.SECONDS).readTimeout(5,TimeUnit.SECONDS).build()
        val ws=try {client.newWebSocket(Request.Builder().url(url).build(),object:WebSocketListener(){
            override fun onOpen(webSocket:WebSocket,response:Response) {
                webSocket.send(JSONObject().put("type","rpc-request").put("request",JSONObject().put("id","auth").put("method","session.resume")
                    .put("params",JSONObject().put("credential",credential).put("role","monitor"))).toString())
            }
            override fun onMessage(webSocket:WebSocket,text:String) {
                try {
                    val body=JSONObject(text);if(body.optString("type")!="rpc-response")return
                    val response=body.getJSONObject("response")
                    if(response.optString("id")=="auth"){
                        if(response.has("error")){answer.set(response);latch.countDown();return}
                        val request=JSONObject().put("type","rpc-request").put("request",JSONObject().put("id","operation").put("method",method).put("params",params))
                        sent.set(webSocket.send(request.toString()))
                        if(!sent.get())latch.countDown()
                    }else if(response.optString("id")=="operation"){
                        answer.set(response);latch.countDown()
                    }
                }catch(_:Exception){latch.countDown()}
            }
            override fun onFailure(webSocket:WebSocket,t:Throwable,response:Response?){latch.countDown()}
            override fun onClosed(webSocket:WebSocket,code:Int,reason:String){latch.countDown()}
        })}catch(_:Exception){return RpcOutcome(null,false)}
        latch.await(waitMs,TimeUnit.MILLISECONDS)
        ws.cancel()
        client.dispatcher.executorService.shutdown()
        return RpcOutcome(answer.get(),sent.get())
    }
}
