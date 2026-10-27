package com.nexuslink.nexuslink

import android.app.*
import android.content.*
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.os.*
import android.provider.Settings
import android.net.Uri
import android.view.*
import android.widget.*
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import androidx.work.workDataOf
import okhttp3.*
import org.json.*
import kotlin.math.abs
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

data class ScopedRpcResult(val response:JSONObject?,val sent:Boolean)

/** Native metadata-only connection; never loads a Flutter engine or transcript. */
class LiveActivityService:Service() {
    companion object {
        var running=false;var visible=false;var instance:LiveActivityService?=null
        var connectionState="stopped";var bubbleVisible=false;var bubbleHiddenReason="Monitoring stopped"
        var lastError:String?=null
        /** Set by the app before a user stop that should also clear task alerts. */
        @Volatile var clearAlertsOnStop=false
    }
    private val handler=Handler(Looper.getMainLooper())
    private val http=OkHttpClient.Builder().pingInterval(20,java.util.concurrent.TimeUnit.SECONDS).build()
    private var socket:WebSocket?=null
    private var stopped=false
    private var online=false
    private var generation=0
    private var attempts=0
    private var host=""
    private var hostId=""
    private val activityStore by lazy { ActivityStore(this) }
    private var activityV2=false
    private var synchronizing=false
    private var snapshotThrough=0L
    private val bufferedActivity=mutableListOf<JSONObject>()
    private val pendingApprovalIds=mutableSetOf<String>()
    private val scopedResults=mutableMapOf<String,(JSONObject)->Unit>()
    private var bubbleEnabled=false
    private val sessions=mutableMapOf<String,JSONObject>()
    private var overlay:View?=null
    private var panel:View?=null
    private var panelRefresh:(()->Unit)?=null
    private var guiMonitor=false
    private var guiStatus=""
    private var guiSyncedAt=0L
    private val guiSessions=mutableMapOf<String,JSONObject>()
    private val guiSettling=mutableMapOf<String,Pair<String,Long>>()
    private var networkCallback:ConnectivityManager.NetworkCallback?=null
    /** Backoff reconnect; named so a returning network can run it early. */
    private val retry=Runnable{connect()}
    /** Renews the session token on the same socket before it expires. */
    private val refreshAuth=Runnable{
        if(stopped || !online)return@Runnable
        val credential=Credentials.get(this,host)
        if(credential==null){pairingRevoked();return@Runnable}
        request("refresh","session.resume",JSONObject().put("credential",credential).put("role","monitor"))
    }
    private val pollGui=object:Runnable {
        override fun run(){
            if(stopped || !online || !guiMonitor)return
            request("guiMonitor","activity.monitor")
            handler.postDelayed(this,15000)
        }
    }
    private val manager get()=getSystemService(NOTIFICATION_SERVICE) as NotificationManager
    private val windows get()=getSystemService(WINDOW_SERVICE) as WindowManager
    private val prefs get()=getSharedPreferences("live",0)
    private val screenReceiver=object:BroadcastReceiver(){override fun onReceive(c:Context?,i:Intent?){updateOverlay()}}
    override fun onBind(intent:Intent?)=null
    override fun onCreate(){
        super.onCreate();instance=this
        for(operation in activityStore.queuedActions()){
            val work=OneTimeWorkRequest.Builder(NotificationActionWorker::class.java)
                .setInputData(workDataOf("operationId" to operation)).addTag("live-action").build()
            WorkManager.getInstance(this).enqueueUniqueWork("action:$operation",ExistingWorkPolicy.KEEP,work)
        }
        if(Build.VERSION.SDK_INT>=26){
            try{manager.deleteNotificationChannel("live_activity")}catch(e:Exception){}
            val liveChannel=NotificationChannel("live_activity_v2","PC live activity",NotificationManager.IMPORTANCE_DEFAULT).apply{
                description="NexusLink task status"
                setSound(null,null)
                enableVibration(false)
                setShowBadge(true)
            }
            manager.createNotificationChannel(liveChannel)
            val attentionChannel=NotificationChannel("task_attention","Task updates",NotificationManager.IMPORTANCE_HIGH)
            manager.createNotificationChannel(attentionChannel)
        }
        val filter=IntentFilter().apply{addAction(Intent.ACTION_SCREEN_OFF);addAction(Intent.ACTION_USER_PRESENT);addAction(Intent.ACTION_CONFIGURATION_CHANGED)}
        if(Build.VERSION.SDK_INT>=33)registerReceiver(screenReceiver,filter,Context.RECEIVER_NOT_EXPORTED) else registerReceiver(screenReceiver,filter)
        // When the network comes back, reconnect now instead of waiting out the backoff.
        if(Build.VERSION.SDK_INT>=24){
            val callback=object:ConnectivityManager.NetworkCallback(){
                override fun onAvailable(network:Network){handler.post{
                    if(!stopped && !online && connectionState=="reconnecting" && host.isNotEmpty()){
                        attempts=0;handler.removeCallbacks(retry);connect()
                    }
                }}
            }
            try{(getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager).registerDefaultNetworkCallback(callback);networkCallback=callback}
            catch(e:Exception){lastError="Network change updates are unavailable: ${e.message}"}
        }
    }
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        if(intent?.action=="stop"){userStop();return START_NOT_STICKY}
        host=intent?.getStringExtra("host")?:prefs.getString("host","").orEmpty()
        // A null intent is Android restarting a sticky service it had to kill:
        // only resume if the user still wants monitoring.
        if(intent==null && (!prefs.getBoolean("requested",false) || host.isEmpty())){stopSelf();return START_NOT_STICKY}
        bubbleEnabled=if(intent?.hasExtra("bubble")==true) intent.getBooleanExtra("bubble",false) else prefs.getBoolean("bubble",false)
        prefs.edit().putString("host",host).putBoolean("bubble",bubbleEnabled).putBoolean("requested",true).apply()
        running=true;stopped=false;connectionState="connecting"
        if(!enterForeground()){stopSelf();return START_NOT_STICKY}
        connect();updateOverlay();return START_STICKY
    }
    /** Android 12+ may refuse a background (re)start; never crash on it. */
    private fun enterForeground():Boolean = try {
        if(Build.VERSION.SDK_INT>=29)startForeground(9000,notification(),ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(9000,notification())
        true
    } catch(e:Exception){
        lastError="Android did not allow monitoring to start in the background. Open NexusLink to resume it."
        false
    }
    /** The user turned monitoring off: do not restart it after boot or a crash. */
    private fun userStop(){prefs.edit().putBoolean("requested",false).apply();stopSelf()}
    private fun pairingRevoked(){
        lastError="This phone is no longer paired with your PC."
        prefs.edit().putBoolean("requested",false).apply()
        try{
            manager.notify("pairing",9004,builder("task_attention").setSmallIcon(android.R.drawable.stat_notify_error)
                .setContentTitle("NexusLink monitoring stopped")
                .setContentText("This phone is no longer paired with your PC. Open NexusLink to pair again.")
                .setContentIntent(openTask()).setAutoCancel(true).build())
        }catch(e:Exception){}
        stopSelf()
    }
    private fun scheduleAuthRefresh(expires:Long){
        handler.removeCallbacks(refreshAuth)
        val lead=if(expires>0)expires-System.currentTimeMillis()-5*60*1000L else 50*60*1000L
        handler.postDelayed(refreshAuth,lead.coerceAtLeast(30000L))
    }
    /** Drop this socket and reconnect with backoff (fresh authentication). */
    private fun reconnect(){val gen=generation;socket?.cancel();lost(gen)}
    private fun openTask(id:String?=null):PendingIntent {
        val intent=Intent(this,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP).putExtra("taskId",id).putExtra("host",host)
        return PendingIntent.getActivity(this,id?.hashCode()?:0,intent,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    private fun builder(channel:String)=if(Build.VERSION.SDK_INT>=26)Notification.Builder(this,channel) else Notification.Builder(this)
    private fun notification():Notification {
        val cards=sessionOverview()
        val working=cards.count{it.running}
        val waiting=cards.count{it.priority==0}
        val failed=cards.count{it.priority==1}
        val stop=PendingIntent.getService(this,1,Intent(this,LiveActivityService::class.java).setAction("stop"),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val iconRes:Int
        val titleText:String
        val bodyText:String
        val subText:String

        if(!online){
            iconRes=android.R.drawable.stat_notify_sync
            titleText="NexusLink (offline)"
            bodyText="PC offline · reconnecting…"
            subText="offline"
        } else if(waiting>0){
            iconRes=android.R.drawable.stat_notify_error
            titleText="NexusLink (waiting for you)"
            bodyText=if(working>0)"$waiting conversation(s) waiting for you · $working working" else "$waiting conversation(s) waiting for you"
            subText="waiting for you"
        } else if(failed>0){
            iconRes=android.R.drawable.stat_notify_error
            titleText="NexusLink (needs attention)"
            bodyText=if(working>0)"$failed conversation(s) need attention · $working working" else "$failed task(s) need attention"
            subText="attention"
        } else if(working>0){
            iconRes=android.R.drawable.stat_notify_sync
            titleText="NexusLink (working)"
            bodyText=if(working==1)"1 task running on PC" else "$working tasks running on PC"
            subText="working"
        } else {
            iconRes=R.mipmap.ic_launcher
            titleText="NexusLink (idle)"
            bodyText="PC connected · No agents currently running"
            subText="idle"
        }

        return builder("live_activity_v2")
            .setSmallIcon(iconRes)
            .setContentTitle(titleText)
            .setContentText(bodyText)
            .setSubText(subText)
            .setOngoing(true)
            .setLocalOnly(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(openTask())
            .addAction(Notification.Action.Builder(null,"Open monitor",openTask()).build())
            .addAction(Notification.Action.Builder(null,"Stop live activity",stop).build()).build()
    }
    private fun request(id:String,method:String,params:JSONObject=JSONObject()) {socket?.send(JSONObject().put("type","rpc-request").put("request",JSONObject().put("id",id).put("method",method).put("params",params)).toString())}
    fun actionRpc(url:String,method:String,params:JSONObject,waitMs:Long):ScopedRpcResult? {
        if(url!=host)return null
        if(!online)return ScopedRpcResult(null,false)
        val id="watch:${java.util.UUID.randomUUID()}"
        val latch=CountDownLatch(1)
        val answer=AtomicReference<JSONObject?>()
        val sent=AtomicReference(false)
        handler.post {
            if(!online || stopped){latch.countDown();return@post}
            scopedResults[id]={result->answer.set(result);latch.countDown()}
            sent.set(socket?.send(JSONObject().put("type","rpc-request").put("request",JSONObject().put("id",id).put("method",method).put("params",params)).toString())==true)
            if(sent.get()!=true){scopedResults.remove(id);latch.countDown()}
        }
        latch.await(waitMs,TimeUnit.MILLISECONDS)
        handler.post{scopedResults.remove(id)}
        return ScopedRpcResult(answer.get(),sent.get()==true)
    }
    private fun connect(){
        if(stopped||host.isEmpty())return
        val credential=Credentials.get(this,host)?:run{pairingRevoked();return}
        handler.removeCallbacks(pollGui);handler.removeCallbacks(refreshAuth);handler.removeCallbacks(retry)
        guiMonitor=false;guiSettling.clear();guiSessions.clear()
        val gen=++generation;online=false;connectionState="connecting";socket?.cancel()
        socket=http.newWebSocket(Request.Builder().url(host).build(),object:WebSocketListener(){
            override fun onOpen(ws:WebSocket,response:Response){handler.post{if(gen==generation)request("auth","session.resume",JSONObject().put("credential",credential).put("role","monitor"))}}
            override fun onMessage(ws:WebSocket,text:String){handler.post{if(gen==generation)try{message(JSONObject(text))}catch(e:Exception){lastError="Activity update failed: ${e.message ?: e.javaClass.simpleName}"}}}
            override fun onClosed(ws:WebSocket,code:Int,reason:String){handler.post{lost(gen)}}
            override fun onFailure(ws:WebSocket,t:Throwable,response:Response?){handler.post{lost(gen)}}
        })
        handler.postDelayed({if(!stopped&&gen==generation&&!online){socket?.cancel();lost(gen)}},15000)
    }
    private fun lost(gen:Int){
        if(stopped||gen!=generation)return
        generation++;online=false;connectionState="reconnecting";manager.notify(9000,notification());updateOverlay()
        handler.removeCallbacks(refreshAuth)
        val delay=(1000L shl attempts.coerceAtMost(5)).coerceAtMost(30000L);attempts++
        handler.removeCallbacks(retry);handler.postDelayed(retry,delay)
    }
    private fun message(msg:JSONObject){
        if(msg.optString("type")=="rpc-response"){
            val response=msg.getJSONObject("response")
            scopedResults.remove(response.optString("id"))?.let{it(response);return}
            if(response.has("error")){
                lastError=response.optString("error")
                val id=response.optString("id")
                if(response.optString("code")=="UNAUTHENTICATED"){
                    // Refused credential: pairing was removed on the PC. Any other
                    // request: only the session token lapsed, so re-authenticate.
                    if(id=="auth" || id=="refresh")pairingRevoked() else reconnect()
                    return
                }
                if(id=="refresh"){reconnect();return}
                if(response.optString("id")=="capabilities" || response.optString("id")=="snapshotV2"){
                    activityV2=false;synchronizing=false
                    request("sub","session.subscribe",JSONObject().put("topics",JSONArray().put("agents")))
                    request("snapshot","activity.snapshot",JSONObject().put("cursor",prefs.getLong("cursor:$hostId",0)))
                }
                return
            }
            when(response.optString("id")){
                "guiMonitor"->applyGuiMonitor(response.getJSONObject("result"))
                "auth"->{
                    online=true;connectionState="connected";lastError=null;attempts=0
                    val result=response.getJSONObject("result")
                    hostId=result.optString("hostId",host)
                    request("capabilities","session.getCapabilities")
                    scheduleAuthRefresh(result.optLong("expires",0L))
                }
                "refresh"->scheduleAuthRefresh(response.optJSONObject("result")?.optLong("expires",0L)?:0L)
                "capabilities"->{
                    val features=response.optJSONObject("result")?.optJSONArray("features")?:JSONArray()
                    guiMonitor=(0 until features.length()).any{features.optString(it)=="activity.monitor.v1"}
                    if(guiMonitor){handler.removeCallbacks(pollGui);handler.post(pollGui)}
                    activityV2=(0 until features.length()).any{features.optString(it)=="activity.v2"}
                    request("sub","session.subscribe",JSONObject().put("topics",if(activityV2)JSONArray().put("agents").put("activity") else JSONArray().put("agents")))
                    if(activityV2){synchronizing=true;bufferedActivity.clear();snapshotThrough=0;request("snapshotV2","activity.snapshotV2",JSONObject().put("cursor",activityStore.cursor(hostId)))}
                    else request("snapshot","activity.snapshot",JSONObject().put("cursor",prefs.getLong("cursor:$hostId",0)))
                }
                "snapshotV2"->{applySnapshotV2(response.getJSONObject("result"))}
                "snapshot"->{val result=response.getJSONObject("result");sessions.clear();val rows=result.optJSONArray("sessions")?:JSONArray();for(i in 0 until rows.length()){val row=rows.getJSONObject(i);sessions[row.getString("agentSessionId")]=row};val events=result.optJSONArray("events")?:JSONArray();var cursor=prefs.getLong("cursor:$hostId",0);for(i in 0 until events.length()){val row=events.getJSONObject(i);event(row);cursor=row.getLong("cursor")};prefs.edit().putLong("cursor:$hostId",cursor).apply();if(events.length()==200)request("snapshot","activity.snapshot",JSONObject().put("cursor",cursor))}
            }
        }else when(msg.optString("type")){
            "agent-session-update"->{val s=msg.getJSONObject("session");sessions[s.getString("agentSessionId")]=s}
            "agent-session-deleted"->sessions.remove(msg.getString("agentSessionId"))
            "agent-event"->if(!activityV2)event(msg)
            "activity-update"->{val record=msg.getJSONObject("record");if(synchronizing)bufferedActivity.add(record) else activityRecord(record,true)}
        }
        manager.notify(9000,notification());updateOverlay()
    }
    private fun approvalTag(task:String,turn:String,request:String)="approval:$hostId:$task:$turn:$request"

    private fun actionIntent(record:JSONObject,action:String):PendingIntent {
        val task=record.optString("agentSessionId")
        val turn=record.optString("turnId")
        val request=record.optString("requestId")
        val source=record.optLong("cursor")
        val identity="$hostId:$task:$turn:$request:$source:$action"
        val operation=java.util.UUID.nameUUIDFromBytes(identity.toByteArray(Charsets.UTF_8)).toString()
        val intent=Intent(this,NotificationActionReceiver::class.java).setAction("nexuslink.notification.$action")
            .setData(Uri.parse("nexuslink://notification/${Uri.encode(identity)}"))
            .putExtra("operationId",operation).putExtra("hostId",hostId).putExtra("url",host)
            .putExtra("task",task).putExtra("turn",turn).putExtra("request",request)
            .putExtra("source",source).putExtra("action",action)
        val mutability=if(action=="reply")PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(this,identity.hashCode(),intent,PendingIntent.FLAG_UPDATE_CURRENT or mutability)
    }

    private fun applySnapshotV2(result:JSONObject) {
        if(snapshotThrough==0L) {
            snapshotThrough=result.optLong("throughCursor")
            sessions.clear()
            val rows=result.optJSONArray("sessions")?:JSONArray()
            for(i in 0 until rows.length()){val row=rows.getJSONObject(i);sessions[row.getString("agentSessionId")]=row}
            pendingApprovalIds.clear()
            val approvals=result.optJSONArray("pendingApprovals")?:JSONArray()
            for(i in 0 until approvals.length()){
                val row=approvals.getJSONObject(i);val event=row.optJSONObject("event")?:continue
                pendingApprovalIds.add(approvalTag(row.optString("agentSessionId"),event.optString("turnId"),row.optString("requestId")))
            }
            for((tag,id) in activityStore.tags())if(tag.startsWith("approval:$hostId:") && tag !in pendingApprovalIds)manager.cancel(tag,id)
            if(result.optBoolean("replayGap")){
                lastError="Some historical task alerts could not be recovered after a replay gap."
                manager.notify("gap:$hostId",9001,builder("task_attention").setSmallIcon(android.R.drawable.stat_notify_error)
                    .setContentTitle("NexusLink alerts restored").setContentText(lastError)
                    .setContentIntent(openTask()).setAutoCancel(true).build())
            }
        }
        val events=result.optJSONArray("events")?:JSONArray()
        for(i in 0 until events.length())activityRecord(events.getJSONObject(i))
        val next=result.optLong("nextCursor",activityStore.cursor(hostId))
        if(result.optBoolean("hasMore")){
            request("snapshotV2","activity.snapshotV2",JSONObject().put("cursor",next).put("throughCursor",snapshotThrough))
        }else{
            synchronizing=false
            bufferedActivity.sortedBy{it.optLong("cursor")}.forEach{activityRecord(it,true)}
            bufferedActivity.clear()
            for(card in activityStore.pendingCards(hostId)){
                if(card.tag.startsWith("approval:") && card.tag !in pendingApprovalIds){
                    activityStore.markPosted(card.tag)
                    continue
                }
                try {
                    postActivityCard(JSONObject(card.payload),card.tag,card.id)
                    activityStore.markPosted(card.tag)
                } catch(e:Exception){lastError="Could not restore task alert: ${e.message}"}
            }
        }
    }

    private fun activityRecord(record:JSONObject,live:Boolean=false) {
        val cursor=record.optLong("cursor")
        if(cursor<=activityStore.cursor(hostId))return
        if(record.optString("kind") in listOf("approval-requested","approval-resolved","completed","failed") && sessions[record.optString("agentSessionId")]?.optBoolean("archived")!=true){
            activityStore.rememberUpdate(hostId,"activity:$cursor",record.toString())
        }
        val task=record.optString("agentSessionId")
        val turn=record.optString("turnId")
        val kind=record.optString("kind")
        val request=record.optString("requestId")
        val tag=when(kind){
            "approval-requested","approval-resolved"->approvalTag(task,turn,request)
            "completed","failed"->"$kind:$hostId:$task:$turn"
            else->null
        }
        if(live && kind=="approval-requested" && tag!=null)pendingApprovalIds.add(tag)
        val legacyKind=when(kind){"completed"->"result";"failed"->"error";"approval-requested"->"permission-request";else->""}
        val legacyKey="$hostId:$task:$turn:${record.optLong("eventSeq")}:$legacyKind"
        val previouslyAlerted=legacyKind.isNotEmpty() && prefs.getStringSet("seen",emptySet())?.contains(legacyKey)==true
        val shouldPost=kind in listOf("approval-requested","completed","failed") &&
            (kind!="approval-requested" || tag in pendingApprovalIds) &&
            !previouslyAlerted &&
            sessions[task]?.optBoolean("archived")!=true
        val id=activityStore.commit(hostId,cursor,if(shouldPost)tag else null,if(shouldPost)record.toString() else null)
        if(kind=="approval-resolved" && tag!=null){activityStore.id(tag)?.let{manager.cancel(tag,it)};activityStore.markPosted(tag);pendingApprovalIds.remove(tag)}
        if(!shouldPost || tag==null || id==null)return
        try {
            postActivityCard(record,tag,id)
            activityStore.markPosted(tag)
        } catch(e:Exception){lastError="Could not show task alert: ${e.message}"}
    }

    private fun postActivityCard(record:JSONObject,tag:String,id:Int) {
        val kind=record.optString("kind")
        val task=record.optString("agentSessionId")
        val title=record.optString("title","Task")
        val provider=record.optString("provider")
        val project=record.optString("project").substringAfterLast('/')
        val preview=record.optString("preview")
        val heading=when(kind){"approval-requested"->"Approval required";"failed"->"Task failed";else->"Task completed"}
        val body="${title.take(90)} · ${project.take(40)} · ${provider.take(30)}"
        val card=NotificationCompat.Builder(this,"task_attention")
            .setSmallIcon(if(kind=="completed")R.mipmap.ic_launcher else android.R.drawable.stat_notify_error)
            .setContentTitle(heading).setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText("$body\n${preview.take(2048)}"))
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setAutoCancel(true).setOnlyAlertOnce(true)
            .setGroup("tasks:$hostId").setContentIntent(openTask(task))
        if(prefs.getBoolean("actions",false)){
            if(kind=="approval-requested"){
                if(record.optBoolean("previewComplete") && record.optJSONArray("availableActions")?.toString()?.contains("approve")==true)
                    card.addAction(NotificationCompat.Action.Builder(0,"Approve once",actionIntent(record,"approve")).build())
                card.addAction(NotificationCompat.Action.Builder(0,"Deny",actionIntent(record,"deny")).build())
            }else if(kind=="completed" || kind=="failed"){
                val remoteInput=RemoteInput.Builder("replyText").setLabel("Reply to task").setAllowFreeFormInput(true).build()
                card.addAction(NotificationCompat.Action.Builder(0,"Reply",actionIntent(record,"reply")).addRemoteInput(remoteInput).build())
            }
        }
        card.addAction(NotificationCompat.Action.Builder(0,"Open on phone",openTask(task)).build())
        card.extend(NotificationCompat.WearableExtender().setDismissalId(tag))
        manager.notify(tag,id,card.build())
    }
    private fun event(msg:JSONObject){
        val e=msg.optJSONObject("event")?:return;val kind=e.optString("kind");if(kind !in listOf("result","error","permission-request"))return
        val task=msg.getString("agentSessionId");val key="$hostId:$task:${e.optString("turnId")}:${e.optLong("seq")}:$kind"
        val seen=prefs.getStringSet("seen",emptySet())!!.toMutableSet();if(!seen.add(key))return
        while(seen.size>500)seen.remove(seen.first());prefs.edit().putStringSet("seen",seen).apply()
        val title:String
        val body:String
        val iconRes:Int
        when(kind){
            "permission-request" -> {
                val tool=e.optString("toolName","Action")
                title="Approval required (needs approval)"
                body="Agent wants to run $tool · Tap to review"
                iconRes=android.R.drawable.stat_notify_error
            }
            "error" -> {
                title="Agent needs attention"
                body=e.optString("text","Task encountered an issue").take(120)
                iconRes=android.R.drawable.stat_notify_error
            }
            else -> {
                title="Agent completed"
                body=e.optString("text","The agent has finished working.").take(120)
                iconRes=R.mipmap.ic_launcher
            }
        }
        activityStore.rememberUpdate(hostId,key,JSONObject().put("agentSessionId",task)
            .put("kind",when(kind){"result"->"completed";"error"->"failed";else->"approval-requested"})
            .put("title",sessions[task]?.optString("title")?:title).put("preview",body).put("ts",e.optLong("ts")).toString())
        manager.notify((task+kind).hashCode(),builder("task_attention").setSmallIcon(iconRes)
            .setContentTitle(title).setContentText(body).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setAutoCancel(true).setContentIntent(openTask(task)).build())
    }
    fun updateOverlay(){
        if(Looper.myLooper()!=Looper.getMainLooper()){handler.post{updateOverlay()};return}
        val locked=(getSystemService(KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked
        val screen=(getSystemService(POWER_SERVICE) as PowerManager).isInteractive
        bubbleHiddenReason=when {
            !bubbleEnabled -> "Bubble is off"
            !Settings.canDrawOverlays(this) -> "Display over other apps permission is unavailable"
            visible -> "NexusLink is foregrounded"
            !screen -> "Screen is off"
            locked -> "Phone is locked"
            else -> ""
        }
        if(bubbleHiddenReason.isNotEmpty()){removeOverlay();return}
        val cards=sessionOverview()
        val justFinished=cards.any{it.status=="Finished" && System.currentTimeMillis()-it.updatedAt in 0..120000}
        val working=cards.count{it.running}
        val waiting=cards.count{it.priority==0}
        val failed=cards.count{it.priority==1}

        val label:String
        val textColor:Int

        if(!online){
            label="×"
            textColor=0xFF9CA3AF.toInt()
        } else if(waiting>0){
            label=if(waiting>1)"$waiting" else "!"
            textColor=0xFFFDE68A.toInt()
        } else if(failed>0){
            label=if(failed>1)"$failed" else "!"
            textColor=0xFFFCA5A5.toInt()
        } else if(working>0){
            label=if(working>1)"$working" else "•"
            textColor=0xFF93C5FD.toInt()
        } else if(justFinished){
            label="✓"
            textColor=0xFF6EE7B7.toInt()
        } else {
            label="•"
            textColor=0xFFD1D5DB.toInt()
        }

        val mood=when {
            !online->PetMood.OFFLINE
            waiting>0->PetMood.WAITING
            failed>0->PetMood.ERROR
            working>0->PetMood.WORKING
            justFinished->PetMood.COMPLETE
            else->PetMood.IDLE
        }
        val density=resources.displayMetrics.density
        panelRefresh?.invoke()
        (overlay as? MonitorPetView)?.let{
            it.status(mood,label,textColor)
            it.contentDescription="NexusLink: ${if(!online) "disconnected" else if(waiting>0) "$waiting waiting for you" else if(failed>0) "$failed need attention" else if(working>0) "$working working" else "idle"}. Tap for conversations."
            it.requestLayout()
            val params=it.layoutParams as? WindowManager.LayoutParams
            if(params!=null){
                val maxW=(resources.displayMetrics.widthPixels-it.width).coerceAtLeast(0)
                val maxH=(resources.displayMetrics.heightPixels-it.height).coerceAtLeast((24*density).toInt())
                val x=params.x.coerceIn(0,maxW)
                val y=params.y.coerceIn((24*density).toInt(),maxH)
                if(x!=params.x || y!=params.y){params.x=x;params.y=y;windows.updateViewLayout(it,params)}
            }
            bubbleVisible=true
            bubbleHiddenReason=""
            return
        }

        val params=WindowManager.LayoutParams(
            (104*density).toInt(),
            (104*density).toInt(),
            if(Build.VERSION.SDK_INT>=26)WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply{
            gravity=Gravity.TOP or Gravity.START
            x=prefs.getInt("bubbleX",0).coerceIn(0,(resources.displayMetrics.widthPixels-(104*density).toInt()).coerceAtLeast(0))
            y=prefs.getInt("bubbleY",(60*density).toInt()).coerceIn((24*density).toInt(),(resources.displayMetrics.heightPixels-(104*density).toInt()).coerceAtLeast((24*density).toInt()))
        }

        val view=MonitorPetView(this).apply{
            status(mood,label,textColor)
            setReducedMotion(prefs.getBoolean("petReducedMotion",false))
            faceInward(params.x>resources.displayMetrics.widthPixels/2)
            contentDescription="NexusLink pet. Tap for important updates. Drag to move. Long press for options."
            elevation=10f*density
        }

        var downX=0f
        var downY=0f
        var originX=0
        var originY=0
        var downAt=0L
        var lastTouchX=0f
        var moved=false

        view.setOnTouchListener{_,event->
            when(event.action){
                MotionEvent.ACTION_DOWN->{
                    downX=event.rawX
                    downY=event.rawY
                    originX=params.x
                    originY=params.y
                    downAt=System.currentTimeMillis()
                    lastTouchX=event.rawX;moved=false
                    true
                }
                MotionEvent.ACTION_MOVE->{
                    if(abs(event.rawX-downX)>8*density || abs(event.rawY-downY)>8*density)moved=true
                    if(moved)view.dragBy((event.rawX-lastTouchX)/density)
                    lastTouchX=event.rawX
                    val maxW=(resources.displayMetrics.widthPixels-view.width).coerceAtLeast(0)
                    val maxH=(resources.displayMetrics.heightPixels-view.height).coerceAtLeast(20)
                    params.x=(originX+event.rawX-downX).toInt().coerceIn(0,maxW)
                    params.y=(originY+event.rawY-downY).toInt().coerceIn(20,maxH)
                    windows.updateViewLayout(view,params)
                    true
                }
                MotionEvent.ACTION_UP->{
                    val dx=abs(event.rawX-downX)
                    val dy=abs(event.rawY-downY)
                    view.release()
                    if(!moved && dx<15*density && dy<15*density){
                        if(System.currentTimeMillis()-downAt>500){
                            showPanel(true)
                        } else {
                            view.performClick()
                            if(panel!=null)closePanel() else showPanel(false)
                        }
                    } else {
                        val maxW=(resources.displayMetrics.widthPixels-view.width).coerceAtLeast(0)
                        params.x=if(params.x<maxW/2)0 else maxW
                        view.faceInward(params.x>maxW/2)
                        windows.updateViewLayout(view,params)
                    }
                    prefs.edit().putInt("bubbleX",params.x).putInt("bubbleY",params.y).apply()
                    true
                }
                MotionEvent.ACTION_CANCEL->{view.release();true}
                else->false
            }
        }

        try{
            windows.addView(view,params)
            overlay=view
            bubbleVisible=true
            bubbleHiddenReason=""
        }catch(e:Exception){
            bubbleVisible=false
            bubbleHiddenReason="Overlay creation failed"
            lastError="Overlay creation failed: ${e.message ?: e.javaClass.simpleName}"
        }
    }
    private fun applyGuiMonitor(result:JSONObject){
        guiSyncedAt=System.currentTimeMillis()
        val rows=result.optJSONArray("items")?:JSONArray()
        guiSessions.clear()
        for(i in rows.length()-1 downTo 0){
            val row=rows.getJSONObject(i)
            guiSessions[row.getString("id")]=row
            val state=row.optString("execution")
            val id=row.getString("id")
            // Running token streams stay quiet: retain state transitions and saved idle updates.
            val signature=state+":"+if(state=="working") "running" else row.optLong("activityAt").toString()
            val previous=activityStore.seenChat(hostId,id)
            if(previous!=null && signature!=previous && state !in listOf("working","needsReply")){
                val settling=guiSettling[id]
                if(settling==null || settling.first!=signature){guiSettling[id]=signature to SystemClock.elapsedRealtime();continue}
                if(SystemClock.elapsedRealtime()-settling.second<30000)continue
            }
            guiSettling.remove(id)
            if(signature!=previous && (previous!=null || i<5)){
                val kind=when(state){"working"->"started";"needsReply"->"needs-reply";else->"updated"}
                activityStore.rememberUpdate(hostId,"gui:$id:$signature:${row.optLong("activityAt")}",JSONObject()
                    .put("agentSessionId","chat:$id").put("title",row.optString("title","Desktop chat")).put("provider",row.optString("provider"))
                    .put("project",row.optString("project")).put("preview",row.optString("preview")).put("kind",kind).put("ts",row.optLong("activityAt"))
                    .toString())
            }
            activityStore.rememberChat(hostId,id,signature)
        }
        val sources=result.optJSONArray("sources")?:JSONArray()
        guiStatus=(0 until sources.length()).map{sources.getJSONObject(it)}
            .filter{it.optString("source") in listOf("codex","antigravity") && it.optString("state")=="error"}
            .joinToString("\n"){it.optString("source")+": "+it.optString("reason","History unavailable")}
    }

    private fun closePanel(){
        panel?.let{try{windows.removeView(it)}catch(e:Exception){}}
        panel=null;panelRefresh=null
    }

    private fun sessionOverview():List<PetSessionSummary>{
        val linked=guiSessions.values.map{it.optString("sessionId")}.filter{it.isNotEmpty()}.toSet()
        val managed=sessions.values.filter{!it.optBoolean("archived") && !(it.optBoolean("imported") && it.optString("agentSessionId") in linked)}.map{
            petSessionSummary(it.optString("agentSessionId"),it.optString("title"),it.optString("cwd"),
                it.optString("agent"),it.optString("taskState"),it.optBoolean("busy"),
                it.optString("activity"),it.optLong("updatedAt",it.optLong("createdAt"))).copy(preview=it.optString("preview"))
        }
        val gui=guiSessions.values.map{
            petSessionSummary("chat:"+it.optString("id"),it.optString("title"),it.optString("project"),
                it.optString("provider"),it.optString("execution"),it.optString("execution")=="working",
                "",it.optLong("activityAt"),true).copy(preview=it.optString("preview"))
        }
        return (managed+gui).sortedWith(compareBy<PetSessionSummary>{it.priority}.thenByDescending{it.updatedAt})
    }

    private fun showPanel(actions:Boolean){
        closePanel()
        val density=resources.displayMetrics.density
        fun dp(value:Int)=(value*density).toInt()
        val list=LinearLayout(this).apply{
            orientation=LinearLayout.VERTICAL;setPadding(dp(16),dp(12),dp(16),dp(12))
            background=GradientDrawable().apply{cornerRadius=dp(16).toFloat();setColor(0xF5141824.toInt())}
        }
        fun close(){closePanel()}
        fun label(text:String)=TextView(this).apply{
            this.text=text;setTextColor(Color.WHITE);textSize=14f
            setPadding(dp(10),dp(10),dp(10),dp(10));minHeight=dp(44)
        }
        fun button(text:String,action:()->Unit){list.addView(label(text).apply{setOnClickListener{action()}})}
        var loadOlder:(()->Unit)?=null
        val scroll=object:ScrollView(this){
            private var downY=0f
            override fun dispatchTouchEvent(event:MotionEvent):Boolean {
                if(event.action==MotionEvent.ACTION_DOWN)downY=event.y
                val handled=super.dispatchTouchEvent(event)
                if(event.action==MotionEvent.ACTION_UP && downY-event.y>dp(40) && !canScrollVertically(1))loadOlder?.invoke()
                return handled
            }
        }
        if(actions){
            button("Play with fox"){(overlay as? MonitorPetView)?.play();close()}
            button(if(prefs.getBoolean("petReducedMotion",false))"Turn animations on" else "Reduce motion"){
                val reduce=!prefs.getBoolean("petReducedMotion",false)
                prefs.edit().putBoolean("petReducedMotion",reduce).apply()
                (overlay as? MonitorPetView)?.setReducedMotion(reduce);close()
            }
            button("Fox artwork · credits"){
                list.removeAllViews()
                list.addView(label(assets.open("pets/fox/CREDITS.txt").bufferedReader().use{it.readText()}))
                list.addView(label(assets.open("pets/fox/LICENSE.txt").bufferedReader().use{it.readText()}))
                button("Close"){close()}
            }
            button("Hide pet"){bubbleEnabled=false;prefs.edit().putBoolean("bubble",false).apply();removeOverlay()}
            button("Stop live activity"){userStop()}
        }else{
            val heading=label("Agent monitor").apply{textSize=21f;typeface=Typeface.DEFAULT_BOLD}
            list.addView(heading)
            val status=label("").apply{minHeight=0;textSize=12f;setTextColor(0xFF94A3B8.toInt())}
            list.addView(status)
            val overview=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL}
            list.addView(overview)
            var recentLimit=5
            var activeLimit=5
            var attentionLimit=5
            var previousOverview=""
            fun refreshOverview(){
                val groups=petConversationGroups(sessionOverview())
                val fingerprint=groups.toString()+online+recentLimit+activeLimit+attentionLimit+(System.currentTimeMillis()/60000)
                if(fingerprint==previousOverview)return
                previousOverview=fingerprint
                overview.removeAllViews()
                fun card(row:PetSessionSummary){
                    val accent=when {row.priority==0->0xFFFBBF24.toInt();row.priority==1->0xFFFCA5A5.toInt();row.running->0xFF6EE7B7.toInt();else->0xFF94A3B8.toInt()}
                    val container=LinearLayout(this).apply{
                        orientation=LinearLayout.VERTICAL
                        setPadding(dp(2),dp(4),dp(2),dp(6))
                        background=GradientDrawable().apply{
                            cornerRadius=dp(14).toFloat();setColor(0xFF1B2432.toInt())
                            setStroke(dp(1),0xFF2B3748.toInt())
                        }
                        layoutParams=LinearLayout.LayoutParams(-1,-2).apply{bottomMargin=dp(8)}
                        setOnClickListener{openTask(row.id).send();close()}
                    }
                    container.addView(label(row.title).apply{
                        typeface=Typeface.DEFAULT_BOLD;textSize=15f;minHeight=0
                        maxLines=2;ellipsize=android.text.TextUtils.TruncateAt.END
                        setPadding(dp(12),dp(8),dp(12),dp(4))
                    })
                    container.addView(label("${row.agent} · ${row.project}").apply{
                        textSize=12f;minHeight=0;setTextColor(0xFFCBD5E1.toInt())
                        setPadding(dp(12),0,dp(12),dp(8));maxLines=1;ellipsize=android.text.TextUtils.TruncateAt.END
                    })
                    if(row.preview.isNotBlank())container.addView(label(row.preview.replace(Regex("\\s+")," ")).apply{
                        textSize=13f;minHeight=0;setTextColor(0xFFCBD5E1.toInt())
                        setPadding(dp(12),0,dp(12),dp(8));maxLines=2;ellipsize=android.text.TextUtils.TruncateAt.END
                    })
                    val state=if(row.running)row.detail else row.status
                    val age=if(row.updatedAt>0)android.text.format.DateUtils.getRelativeTimeSpanString(row.updatedAt).toString() else ""
                    container.addView(label("${if(online && row.running) "● " else ""}$state${if(!online) " · last known" else ""} · $age").apply{
                        textSize=11f;minHeight=0;setTextColor(accent)
                        setPadding(dp(12),0,dp(12),dp(6));maxLines=2;ellipsize=android.text.TextUtils.TruncateAt.END
                    })
                    container.contentDescription="${row.title}, ${row.agent}, ${row.project}, $state. Open conversation"
                    overview.addView(container)
                }
                fun section(title:String,rows:List<PetSessionSummary>,limit:Int,more:()->Unit){
                    overview.addView(label("$title  ·  ${rows.size}").apply{
                        typeface=Typeface.DEFAULT_BOLD;textSize=12f;setTextColor(0xFF94A3B8.toInt())
                    })
                    rows.take(limit).forEach{card(it)}
                    if(rows.size>limit)overview.addView(label("Show more · ${rows.size-limit} remaining").apply{setOnClickListener{more()}})
                }
                if(groups.attention.isNotEmpty())section("NEEDS ATTENTION",groups.attention,attentionLimit){attentionLimit+=5;refreshOverview()}
                section("RUNNING",groups.running,activeLimit){activeLimit+=5;refreshOverview()}
                if(groups.running.isEmpty())overview.addView(label(if(online)"No agents running right now" else "Reconnect to check running agents").apply{
                    textSize=13f;setTextColor(0xFF94A3B8.toInt())
                })
                section("RECENT",groups.recent,recentLimit){recentLimit+=5;refreshOverview()}
                if(groups.recent.isEmpty())overview.addView(label("Recent conversations will appear here").apply{textSize=13f;setTextColor(0xFF94A3B8.toInt())})
            }
            loadOlder={recentLimit+=5;refreshOverview()}
            panelRefresh={
                refreshOverview()
                status.text=when {
                    !online->"Offline · showing last known conversations"
                    guiStatus.isNotEmpty()->"Connected · some agent sources are unavailable"
                    guiMonitor && guiSyncedAt>0->"● Connected · desktop chats refresh every 15s"
                    !guiMonitor->"Connected · update PC host for desktop chats"
                    else->"Connected · syncing conversations…"
                }
            }
            panelRefresh?.invoke()
            button("Open full monitor  →"){openTask().send();close()}

        }
        button("Close"){close()}
        scroll.addView(list)
        val params=WindowManager.LayoutParams(
            minOf(dp(380),resources.displayMetrics.widthPixels-dp(24)),
            minOf(dp(600),resources.displayMetrics.heightPixels-dp(100)),
            if(Build.VERSION.SDK_INT>=26)WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,PixelFormat.TRANSLUCENT).apply{gravity=Gravity.CENTER}
        try{
            windows.addView(scroll,params);panel=scroll
            overlay?.let{pet->val placement=pet.layoutParams;windows.removeView(pet);windows.addView(pet,placement)}
        }catch(e:Exception){panelRefresh=null;lastError="Pet feed could not open: ${e.message ?: e.javaClass.simpleName}"}
    }
    private fun removeOverlay(){panelRefresh=null;overlay?.let{try{windows.removeView(it)}catch(e:Exception){}};overlay=null;bubbleVisible=false;panel?.let{try{windows.removeView(it)}catch(e:Exception){}};panel=null}
    override fun onDestroy(){
        stopped=true;running=false;connectionState="stopped";generation++;socket?.cancel()
        // Android stopping the service (memory, sticky restart) keeps "requested",
        // so it comes back; only an explicit user stop clears it.
        if(!prefs.getBoolean("requested",false))WorkManager.getInstance(this).cancelAllWorkByTag("live-action")
        // Task alerts already posted stay useful after monitoring stops.
        if(clearAlertsOnStop){
            clearAlertsOnStop=false
            for((tag,id) in activityStore.tags())if(hostId.isNotEmpty() && tag.contains(":$hostId:"))manager.cancel(tag,id)
            for(task in sessions.keys)for(kind in listOf("result","error","permission-request"))manager.cancel((task+kind).hashCode())
        }
        networkCallback?.let{try{(getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager).unregisterNetworkCallback(it)}catch(e:Exception){}}
        networkCallback=null
        handler.removeCallbacksAndMessages(null);removeOverlay();activityStore.close();unregisterReceiver(screenReceiver);instance=null;super.onDestroy()
    }
}
