package com.nexuslink.nexuslink

import android.app.*
import android.content.*
import android.graphics.Color
import android.graphics.PixelFormat
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
        if(Build.VERSION.SDK_INT>=26){manager.createNotificationChannel(NotificationChannel("live_activity","PC live activity",NotificationManager.IMPORTANCE_LOW));manager.createNotificationChannel(NotificationChannel("task_attention","Task updates",NotificationManager.IMPORTANCE_HIGH))}
        val filter=IntentFilter().apply{addAction(Intent.ACTION_SCREEN_OFF);addAction(Intent.ACTION_USER_PRESENT)}
        if(Build.VERSION.SDK_INT>=33)registerReceiver(screenReceiver,filter,Context.RECEIVER_NOT_EXPORTED) else registerReceiver(screenReceiver,filter)
    }
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        if(intent?.action=="stop"){stopSelf();return START_NOT_STICKY}
        host=intent?.getStringExtra("host")?:prefs.getString("host","").orEmpty()
        bubbleEnabled=intent?.getBooleanExtra("bubble",false)?:prefs.getBoolean("bubble",false)
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
        val attention=sessions.values.count{it.optString("taskState") in listOf("waiting","failed")}
        val stop=PendingIntent.getService(this,1,Intent(this,LiveActivityService::class.java).setAction("stop"),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return builder("live_activity").setSmallIcon(android.R.drawable.stat_notify_sync).setContentTitle("NexusLink live activity")
            .setContentText(if(online)"$working working · $attention need attention" else "PC offline · reconnecting")
            .setOngoing(true).setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PRIVATE).setContentIntent(openTask())
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
        val title=when(kind){"result"->"Agent completed";"error"->"Agent needs attention";else->"Approval required"}
        manager.notify((task+kind).hashCode(),builder("task_attention").setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title).setContentText("Open NexusLink to review this task.").setVisibility(Notification.VISIBILITY_PRIVATE)
            .setAutoCancel(true).setContentIntent(openTask(task)).build())
    }
    fun updateOverlay(){
        if(Looper.myLooper()!=Looper.getMainLooper()){handler.post{updateOverlay()};return}
        val locked=(getSystemService(KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked
        val screen=(getSystemService(POWER_SERVICE) as PowerManager).isInteractive
        if(!bubbleEnabled||!Settings.canDrawOverlays(this)||visible||locked||!screen){removeOverlay();return}
        val states=sessions.values.map{it.optString("taskState")}
        val working=sessions.values.count{it.optBoolean("busy")}
        val label=if(!online)"…" else if("waiting" in states)"!" else if("failed" in states)"!" else if(working>0)working.toString() else if("completed" in states)"✓" else "·"
        val color=if(!online)Color.GRAY else if("waiting" in states)0xFFFFB547.toInt() else if("failed" in states)0xFFEE6666.toInt() else if(working>0)0xFF6C9BFF.toInt() else 0xFF66CC99.toInt()
        (overlay as? TextView)?.let{it.text=label;it.setTextColor(color);return}
        val size=(48*resources.displayMetrics.density).toInt()
        val params=WindowManager.LayoutParams(size,size,if(Build.VERSION.SDK_INT>=26)WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,PixelFormat.TRANSLUCENT).apply{gravity=Gravity.TOP or Gravity.START;x=0;y=prefs.getInt("bubbleY",200)}
        val view=TextView(this).apply{text=label;setTextColor(color);textSize=20f;gravity=Gravity.CENTER;contentDescription="NexusLink task status. Tap to open tasks.";background=android.graphics.drawable.GradientDrawable().apply{shape=android.graphics.drawable.GradientDrawable.OVAL;setColor(0xFF1C2230.toInt())}}
        var downY=0f;var origin=0;var downAt=0L
        view.setOnTouchListener{_,event->when(event.action){MotionEvent.ACTION_DOWN->{downY=event.rawY;origin=params.y;downAt=System.currentTimeMillis();true};MotionEvent.ACTION_MOVE->{params.y=(origin+event.rawY-downY).toInt().coerceIn(40,resources.displayMetrics.heightPixels-size);windows.updateViewLayout(view,params);true};MotionEvent.ACTION_UP->{prefs.edit().putInt("bubbleY",params.y).apply();if(abs(event.rawY-downY)<10){if(System.currentTimeMillis()-downAt>500)showPanel(true) else showPanel(false)};true};else->false}}
        try{windows.addView(view,params);overlay=view}catch(e:Exception){bubbleEnabled=false}
    }
    private fun showPanel(actions:Boolean){
        panel?.let{windows.removeView(it)};panel=null
        val list=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(16,16,16,16);setBackgroundColor(0xFF141821.toInt())}
        fun button(text:String,action:()->Unit){list.addView(TextView(this).apply{
            this.text=text;setTextColor(Color.WHITE);textSize=15f;gravity=Gravity.CENTER_VERTICAL
            val density=resources.displayMetrics.density;setPadding((14*density).toInt(),(10*density).toInt(),(14*density).toInt(),(10*density).toInt())
            minHeight=(48*density).toInt();maxLines=2;ellipsize=android.text.TextUtils.TruncateAt.END
            background=android.graphics.drawable.GradientDrawable().apply{cornerRadius=12*density;setColor(0xFF1C2230.toInt())}
            val margin=(6*density).toInt();layoutParams=LinearLayout.LayoutParams(-1,-2).apply{bottomMargin=margin}
            setOnClickListener{action();panel?.let{windows.removeView(it)};panel=null}
        })}
        if(actions){button("Hide bubble"){bubbleEnabled=false;prefs.edit().putBoolean("bubble",false).apply();removeOverlay()};button("Stop live activity"){stopSelf()}}
        else {
            val active=sessions.values.filter{!it.optBoolean("archived") && (it.optBoolean("busy") || it.optString("taskState") in listOf("waiting","failed"))}
                .sortedWith(compareByDescending<JSONObject>{it.optString("taskState")=="waiting"}.thenByDescending{it.optString("taskState")=="failed"}.thenByDescending{it.optLong("updatedAt")}).take(3)
            if(active.isEmpty())list.addView(TextView(this).apply{text="No active tasks";setTextColor(0xFFA7B0C0.toInt());textSize=15f;setPadding(12,12,12,20)})
            active.forEach{s->button("${s.optString("taskState","working")} · ${s.optString("title","Task")}"){openTask(s.getString("agentSessionId")).send()}}
            button("All tasks"){openTask().send()}
        }
        button("Close"){}
        val scroll=ScrollView(this).apply{addView(list)}
        val params=WindowManager.LayoutParams((280*resources.displayMetrics.density).toInt(),WindowManager.LayoutParams.WRAP_CONTENT,if(Build.VERSION.SDK_INT>=26)WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,PixelFormat.TRANSLUCENT).apply{gravity=Gravity.START or Gravity.CENTER_VERTICAL}
        windows.addView(scroll,params);panel=scroll
    }
    private fun removeOverlay(){overlay?.let{try{windows.removeView(it)}catch(e:Exception){}};overlay=null;panel?.let{try{windows.removeView(it)}catch(e:Exception){}};panel=null}
    override fun onDestroy(){stopped=true;running=false;generation++;socket?.cancel();handler.removeCallbacksAndMessages(null);removeOverlay();unregisterReceiver(screenReceiver);instance=null;super.onDestroy()}
}
