package com.nexuslink.nexuslink

import android.app.*
import android.content.*
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
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
    }
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        if(intent?.action=="stop"){stopSelf();return START_NOT_STICKY}
        host=intent?.getStringExtra("host")?:prefs.getString("host","").orEmpty()
        bubbleEnabled=if(intent?.hasExtra("bubble")==true) intent.getBooleanExtra("bubble",false) else prefs.getBoolean("bubble",false)
        prefs.edit().putString("host",host).putBoolean("bubble",bubbleEnabled).apply()
        prefs.edit().putBoolean("requested",true).apply()
        running=true;stopped=false;connectionState="connecting";startForeground(9000,notification())
        connect();updateOverlay();return START_NOT_STICKY
    }
    private fun openTask(id:String?=null):PendingIntent {
        val intent=Intent(this,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP).putExtra("taskId",id).putExtra("host",host)
        return PendingIntent.getActivity(this,id?.hashCode()?:0,intent,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    private fun builder(channel:String)=if(Build.VERSION.SDK_INT>=26)Notification.Builder(this,channel) else Notification.Builder(this)
    private fun notification():Notification {
        val attention=sessions.values.filter{!it.optBoolean("archived")}
        val working=attention.count{it.optBoolean("busy")}
        val waiting=attention.count{it.optString("taskState")=="waiting"}
        val failed=attention.count{it.optString("taskState")=="failed"}
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
            titleText="NexusLink (needs approval)"
            bodyText=if(working>0)"$waiting task(s) awaiting approval · $working working" else "$waiting task(s) awaiting approval"
            subText="needs approval"
        } else if(failed>0){
            iconRes=android.R.drawable.stat_notify_error
            titleText="NexusLink (needs attention)"
            bodyText=if(working>0)"$failed task(s) failed · $working working" else "$failed task(s) need attention"
            subText="attention"
        } else if(working>0){
            iconRes=android.R.drawable.stat_notify_sync
            titleText="NexusLink (working)"
            bodyText=if(working==1)"1 task running on PC" else "$working tasks running on PC"
            subText="working"
        } else {
            iconRes=R.mipmap.ic_launcher
            titleText="NexusLink (idle)"
            bodyText="PC connected · All tasks done"
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
            .addAction(Notification.Action.Builder(null,"Open tasks",openTask()).build())
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
        val credential=Credentials.get(this,host)?:run{stopSelf();return}
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
        val delay=(1000L shl attempts.coerceAtMost(5)).coerceAtMost(30000L);attempts++
        handler.postDelayed({connect()},delay)
    }
    private fun message(msg:JSONObject){
        if(msg.optString("type")=="rpc-response"){
            val response=msg.getJSONObject("response")
            scopedResults.remove(response.optString("id"))?.let{it(response);return}
            if(response.has("error")){
                lastError=response.optString("error")
                if(response.optString("code")=="UNAUTHENTICATED"){stopSelf();return}
                if(response.optString("id")=="capabilities" || response.optString("id")=="snapshotV2"){
                    activityV2=false;synchronizing=false
                    request("sub","session.subscribe",JSONObject().put("topics",JSONArray().put("agents")))
                    request("snapshot","activity.snapshot",JSONObject().put("cursor",prefs.getLong("cursor:$hostId",0)))
                }
                return
            }
            when(response.optString("id")){
                "auth"->{online=true;connectionState="connected";lastError=null;attempts=0;hostId=response.getJSONObject("result").optString("hostId",host);request("capabilities","session.getCapabilities");val gen=generation;handler.postDelayed({if(gen==generation)connect()},45*60*1000L)}
                "capabilities"->{
                    val features=response.optJSONObject("result")?.optJSONArray("features")?:JSONArray()
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
        val attention=sessions.values.filter{!it.optBoolean("archived")}
        val states=attention.map{it.optString("taskState")}
        val working=attention.count{it.optBoolean("busy")}
        val waiting=attention.count{it.optString("taskState")=="waiting"}
        val failed=attention.count{it.optString("taskState")=="failed"}

        val label:String
        val strokeColor:Int
        val textColor:Int

        if(!online){
            label="×"
            strokeColor=0xFF6B7280.toInt()
            textColor=0xFF9CA3AF.toInt()
        } else if(waiting>0){
            label=if(waiting>1)"$waiting" else "!"
            strokeColor=0xFFF59E0B.toInt()
            textColor=0xFFFDE68A.toInt()
        } else if(failed>0){
            label=if(failed>1)"$failed" else "!"
            strokeColor=0xFFEF4444.toInt()
            textColor=0xFFFCA5A5.toInt()
        } else if(working>0){
            label=if(working>1)"$working" else "•"
            strokeColor=0xFF3B82F6.toInt()
            textColor=0xFF93C5FD.toInt()
        } else if("completed" in states){
            label="✓"
            strokeColor=0xFF10B981.toInt()
            textColor=0xFF6EE7B7.toInt()
        } else {
            label="•"
            strokeColor=0xFF4B5563.toInt()
            textColor=0xFFD1D5DB.toInt()
        }

        val density=resources.displayMetrics.density
        fun makeBackground(stroke:Int)=GradientDrawable().apply{
            shape=GradientDrawable.OVAL
            setColor(0xF0141824.toInt())
            setStroke((1.5f*density).toInt(),stroke)
        }

        (overlay as? TextView)?.let{
            it.text=label
            it.setTextColor(textColor)
            it.contentDescription="NexusLink: ${if(!online) "disconnected" else if(waiting>0) "$waiting approvals" else if(failed>0) "$failed failures" else if(working>0) "$working working" else "idle"}. Tap for tasks."
            it.background=makeBackground(strokeColor)
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
            (48*density).toInt(),
            (48*density).toInt(),
            if(Build.VERSION.SDK_INT>=26)WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply{
            gravity=Gravity.TOP or Gravity.START
            x=prefs.getInt("bubbleX",0).coerceIn(0,(resources.displayMetrics.widthPixels-(48*density).toInt()).coerceAtLeast(0))
            y=prefs.getInt("bubbleY",(60*density).toInt()).coerceIn((24*density).toInt(),(resources.displayMetrics.heightPixels-(48*density).toInt()).coerceAtLeast((24*density).toInt()))
        }

        val view=TextView(this).apply{
            text=label
            setTextColor(textColor)
            textSize=18f
            typeface=Typeface.DEFAULT_BOLD
            gravity=Gravity.CENTER
            contentDescription="NexusLink task status. Tap for tasks. Long press for options."
            background=makeBackground(strokeColor)
            elevation=10f*density
        }

        var downX=0f
        var downY=0f
        var originX=0
        var originY=0
        var downAt=0L

        view.setOnTouchListener{_,event->
            when(event.action){
                MotionEvent.ACTION_DOWN->{
                    downX=event.rawX
                    downY=event.rawY
                    originX=params.x
                    originY=params.y
                    downAt=System.currentTimeMillis()
                    true
                }
                MotionEvent.ACTION_MOVE->{
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
                    if(dx<15 && dy<15){
                        if(System.currentTimeMillis()-downAt>500){
                            showPanel(true)
                        } else {
                            showPanel(false)
                        }
                    } else {
                        val maxW=(resources.displayMetrics.widthPixels-view.width).coerceAtLeast(0)
                        params.x=if(params.x<maxW/2)0 else maxW
                        windows.updateViewLayout(view,params)
                    }
                    prefs.edit().putInt("bubbleX",params.x).putInt("bubbleY",params.y).apply()
                    true
                }
                MotionEvent.ACTION_CANCEL->true
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
    private fun showPanel(actions:Boolean){
        panel?.let{try{windows.removeView(it)}catch(e:Exception){}};panel=null
        val density=resources.displayMetrics.density
        val list=LinearLayout(this).apply{
            orientation=LinearLayout.VERTICAL
            setPadding((16*density).toInt(),(16*density).toInt(),(16*density).toInt(),(16*density).toInt())
            background=GradientDrawable().apply{
                cornerRadius=16f*density
                setColor(0xF5141824.toInt())
                setStroke((1f*density).toInt(),0xFF2A344A.toInt())
            }
        }
        fun button(text:String,action:()->Unit){list.addView(TextView(this).apply{
            this.text=text;setTextColor(Color.WHITE);textSize=14f;gravity=Gravity.CENTER_VERTICAL
            setPadding((14*density).toInt(),(10*density).toInt(),(14*density).toInt(),(10*density).toInt())
            minHeight=(44*density).toInt();maxLines=2;ellipsize=android.text.TextUtils.TruncateAt.END
            background=GradientDrawable().apply{cornerRadius=10f*density;setColor(0xFF1E2536.toInt())}
            val margin=(6*density).toInt();layoutParams=LinearLayout.LayoutParams(-1,-2).apply{bottomMargin=margin}
            setOnClickListener{action();panel?.let{try{windows.removeView(it)}catch(e:Exception){}};panel=null}
        })}
        if(actions){
            button("Hide bubble"){bubbleEnabled=false;prefs.edit().putBoolean("bubble",false).apply();removeOverlay()}
            button("Stop live activity"){stopSelf()}
        } else {
            val active=sessions.values.filter{!it.optBoolean("archived")}
                .sortedWith(compareByDescending<JSONObject>{it.optString("taskState")=="waiting"}
                    .thenByDescending{it.optString("taskState")=="failed"}
                    .thenByDescending{it.optBoolean("busy")}
                    .thenByDescending{it.optString("taskState")=="completed"}
                    .thenByDescending{it.optLong("updatedAt")})
            if(active.isEmpty())list.addView(TextView(this).apply{text="No active tasks";setTextColor(0xFFA7B0C0.toInt());textSize=14f;setPadding(12,12,12,16)})
            active.forEach{s->
                val state=s.optString("taskState",if(s.optBoolean("busy")) "working" else "idle")
                val title=s.optString("title","Task")
                button("$state · $title"){openTask(s.getString("agentSessionId")).send()}
            }
            button("Open NexusLink"){openTask().send()}
        }
        button("Close"){}
        val scroll=ScrollView(this).apply{addView(list)}
        val params=WindowManager.LayoutParams((300*density).toInt(),WindowManager.LayoutParams.WRAP_CONTENT,if(Build.VERSION.SDK_INT>=26)WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,PixelFormat.TRANSLUCENT).apply{
            gravity=Gravity.CENTER
        }
        try{windows.addView(scroll,params);panel=scroll}catch(e:Exception){lastError="Task picker could not open: ${e.message ?: e.javaClass.simpleName}"}
    }
    private fun removeOverlay(){overlay?.let{try{windows.removeView(it)}catch(e:Exception){}};overlay=null;bubbleVisible=false;panel?.let{try{windows.removeView(it)}catch(e:Exception){}};panel=null}
    override fun onDestroy(){
        stopped=true;running=false;connectionState="stopped";generation++;socket?.cancel()
        prefs.edit().putBoolean("requested",false).apply()
        WorkManager.getInstance(this).cancelAllWorkByTag("live-action")
        for((tag,id) in activityStore.tags())if(hostId.isNotEmpty() && tag.contains(":$hostId:"))manager.cancel(tag,id)
        for(task in sessions.keys)for(kind in listOf("result","error","permission-request"))manager.cancel((task+kind).hashCode())
        handler.removeCallbacksAndMessages(null);removeOverlay();activityStore.close();unregisterReceiver(screenReceiver);instance=null;super.onDestroy()
    }
}
