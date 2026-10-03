package com.nexuslink.nexuslink

import android.app.*
import android.content.*
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.*
import android.provider.Settings
import android.view.*
import android.widget.*
import okhttp3.*
import org.json.*
import kotlin.math.abs

/** Native metadata-only connection; never loads a Flutter engine or transcript. */
class LiveActivityService:Service() {
    companion object { var running=false;var visible=false;var instance:LiveActivityService?=null }
    private val handler=Handler(Looper.getMainLooper())
    private val http=OkHttpClient.Builder().pingInterval(20,java.util.concurrent.TimeUnit.SECONDS).build()
    private var socket:WebSocket?=null
    private var stopped=false
    private var online=false
    private var generation=0
    private var attempts=0
    private var host=""
    private var hostId=""
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
        val filter=IntentFilter().apply{addAction(Intent.ACTION_SCREEN_OFF);addAction(Intent.ACTION_USER_PRESENT)}
        if(Build.VERSION.SDK_INT>=33)registerReceiver(screenReceiver,filter,Context.RECEIVER_NOT_EXPORTED) else registerReceiver(screenReceiver,filter)
    }
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        if(intent?.action=="stop"){stopSelf();return START_NOT_STICKY}
        host=intent?.getStringExtra("host")?:prefs.getString("host","").orEmpty()
        bubbleEnabled=if(intent?.hasExtra("bubble")==true) intent.getBooleanExtra("bubble",false) else prefs.getBoolean("bubble",false)
        prefs.edit().putString("host",host).putBoolean("bubble",bubbleEnabled).apply()
        running=true;stopped=false;startForeground(9000,notification())
        connect();updateOverlay();return START_NOT_STICKY
    }
    private fun openTask(id:String?=null):PendingIntent {
        val intent=Intent(this,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP).putExtra("taskId",id).putExtra("host",host)
        return PendingIntent.getActivity(this,id?.hashCode()?:0,intent,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    private fun builder(channel:String)=if(Build.VERSION.SDK_INT>=26)Notification.Builder(this,channel) else Notification.Builder(this)
    private fun notification():Notification {
        val working=sessions.values.count{it.optBoolean("busy")}
        val waiting=sessions.values.count{it.optString("taskState")=="waiting"}
        val failed=sessions.values.count{it.optString("taskState")=="failed"}
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
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(openTask())
            .addAction(Notification.Action.Builder(null,"Open tasks",openTask()).build())
            .addAction(Notification.Action.Builder(null,"Stop live activity",stop).build()).build()
    }
    private fun request(id:String,method:String,params:JSONObject=JSONObject()) {socket?.send(JSONObject().put("type","rpc-request").put("request",JSONObject().put("id",id).put("method",method).put("params",params)).toString())}
    private fun connect(){
        if(stopped||host.isEmpty())return
        val credential=Credentials.get(this,host)?:run{stopSelf();return}
        val gen=++generation;online=false;socket?.cancel()
        socket=http.newWebSocket(Request.Builder().url(host).build(),object:WebSocketListener(){
            override fun onOpen(ws:WebSocket,response:Response){handler.post{if(gen==generation)request("auth","session.resume",JSONObject().put("credential",credential).put("role","monitor"))}}
            override fun onMessage(ws:WebSocket,text:String){handler.post{if(gen==generation)try{message(JSONObject(text))}catch(e:Exception){}}}
            override fun onClosed(ws:WebSocket,code:Int,reason:String){handler.post{lost(gen)}}
            override fun onFailure(ws:WebSocket,t:Throwable,response:Response?){handler.post{lost(gen)}}
        })
        handler.postDelayed({if(!stopped&&gen==generation&&!online){socket?.cancel();lost(gen)}},15000)
    }
    private fun lost(gen:Int){
        if(stopped||gen!=generation)return
        generation++;online=false;manager.notify(9000,notification());updateOverlay()
        val delay=(1000L shl attempts.coerceAtMost(5)).coerceAtMost(30000L);attempts++
        handler.postDelayed({connect()},delay)
    }
    private fun message(msg:JSONObject){
        if(msg.optString("type")=="rpc-response"){
            val response=msg.getJSONObject("response")
            if(response.has("error")){if(response.optString("code")=="UNAUTHENTICATED")stopSelf();return}
            when(response.optString("id")){
                "auth"->{online=true;attempts=0;hostId=response.getJSONObject("result").optString("hostId",host);request("sub","session.subscribe",JSONObject().put("topics",JSONArray().put("agents")));request("snapshot","activity.snapshot",JSONObject().put("cursor",prefs.getLong("cursor:$hostId",0)));val gen=generation;handler.postDelayed({if(gen==generation)connect()},45*60*1000L)}
                "snapshot"->{val result=response.getJSONObject("result");sessions.clear();val rows=result.optJSONArray("sessions")?:JSONArray();for(i in 0 until rows.length()){val row=rows.getJSONObject(i);sessions[row.getString("agentSessionId")]=row};val events=result.optJSONArray("events")?:JSONArray();var cursor=prefs.getLong("cursor:$hostId",0);for(i in 0 until events.length()){val row=events.getJSONObject(i);event(row);cursor=row.getLong("cursor")};prefs.edit().putLong("cursor:$hostId",cursor).apply();if(events.length()==200)request("snapshot","activity.snapshot",JSONObject().put("cursor",cursor))}
            }
        }else when(msg.optString("type")){
            "agent-session-update"->{val s=msg.getJSONObject("session");sessions[s.getString("agentSessionId")]=s}
            "agent-session-deleted"->sessions.remove(msg.getString("agentSessionId"))
            "agent-event"->event(msg)
        }
        manager.notify(9000,notification());updateOverlay()
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
        if(!bubbleEnabled||!Settings.canDrawOverlays(this)||locked||!screen){removeOverlay();return}
        val states=sessions.values.map{it.optString("taskState")}
        val working=sessions.values.count{it.optBoolean("busy")}
        val waiting=sessions.values.count{it.optString("taskState")=="waiting"}
        val failed=sessions.values.count{it.optString("taskState")=="failed"}

        val label:String
        val strokeColor:Int
        val textColor:Int

        if(!online){
            label="Offline"
            strokeColor=0xFF6B7280.toInt()
            textColor=0xFF9CA3AF.toInt()
        } else if(waiting>0){
            label=if(waiting>1)"⚠️ (needs approval: $waiting)" else "⚠️ (needs approval)"
            strokeColor=0xFFF59E0B.toInt()
            textColor=0xFFFDE68A.toInt()
        } else if(failed>0){
            label=if(failed>1)"⚠️ (attention: $failed)" else "⚠️ (needs attention)"
            strokeColor=0xFFEF4444.toInt()
            textColor=0xFFFCA5A5.toInt()
        } else if(working>0){
            label=if(working>1)"⚡ (working: $working)" else "⚡ (working)"
            strokeColor=0xFF3B82F6.toInt()
            textColor=0xFF93C5FD.toInt()
        } else if("completed" in states){
            label="✓ (done)"
            strokeColor=0xFF10B981.toInt()
            textColor=0xFF6EE7B7.toInt()
        } else {
            label="● (idle)"
            strokeColor=0xFF4B5563.toInt()
            textColor=0xFFD1D5DB.toInt()
        }

        val density=resources.displayMetrics.density
        fun makeBackground(stroke:Int)=GradientDrawable().apply{
            shape=GradientDrawable.RECTANGLE
            cornerRadius=18f*density
            setColor(0xF0141824.toInt())
            setStroke((1.5f*density).toInt(),stroke)
        }

        (overlay as? TextView)?.let{
            it.text=label
            it.setTextColor(textColor)
            it.background=makeBackground(strokeColor)
            it.requestLayout()
            return
        }

        val params=WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if(Build.VERSION.SDK_INT>=26)WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply{
            gravity=Gravity.TOP or Gravity.START
            x=prefs.getInt("bubbleX",(16*density).toInt()).coerceIn(0,(resources.displayMetrics.widthPixels-(100*density).toInt()).coerceAtLeast(0))
            y=prefs.getInt("bubbleY",(60*density).toInt()).coerceIn(20,(resources.displayMetrics.heightPixels-(50*density).toInt()).coerceAtLeast(20))
        }

        val view=TextView(this).apply{
            text=label
            setTextColor(textColor)
            textSize=13f
            typeface=Typeface.DEFAULT_BOLD
            gravity=Gravity.CENTER
            setPadding((14*density).toInt(),(8*density).toInt(),(14*density).toInt(),(8*density).toInt())
            minHeight=(36*density).toInt()
            contentDescription="NexusLink task status. Tap to open tasks."
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
                    prefs.edit().putInt("bubbleX",params.x).putInt("bubbleY",params.y).apply()
                    val dx=abs(event.rawX-downX)
                    val dy=abs(event.rawY-downY)
                    if(dx<15 && dy<15){
                        if(System.currentTimeMillis()-downAt>500){
                            showPanel(true)
                        } else {
                            val waitingTask=sessions.values.firstOrNull{it.optString("taskState")=="waiting"}?.optString("agentSessionId")
                            if(!waitingTask.isNullOrEmpty()){
                                openTask(waitingTask).send()
                            } else if(working>0){
                                val workingTask=sessions.values.firstOrNull{it.optBoolean("busy")}?.optString("agentSessionId")
                                if(!workingTask.isNullOrEmpty()){
                                    openTask(workingTask).send()
                                } else {
                                    openTask().send()
                                }
                            } else {
                                showPanel(false)
                            }
                        }
                    }
                    true
                }
                else->false
            }
        }

        try{
            windows.addView(view,params)
            overlay=view
        }catch(e:Exception){
            bubbleEnabled=false
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
            val active=sessions.values.filter{!it.optBoolean("archived") && (it.optBoolean("busy") || it.optString("taskState") in listOf("waiting","failed"))}
                .sortedWith(compareByDescending<JSONObject>{it.optString("taskState")=="waiting"}.thenByDescending{it.optString("taskState")=="failed"}.thenByDescending{it.optLong("updatedAt")}).take(3)
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
        windows.addView(scroll,params);panel=scroll
    }
    private fun removeOverlay(){overlay?.let{try{windows.removeView(it)}catch(e:Exception){}};overlay=null;panel?.let{try{windows.removeView(it)}catch(e:Exception){}};panel=null}
    override fun onDestroy(){stopped=true;running=false;generation++;socket?.cancel();handler.removeCallbacksAndMessages(null);removeOverlay();unregisterReceiver(screenReceiver);instance=null;super.onDestroy()}
}
