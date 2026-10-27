package com.nexuslink.nexuslink

import android.Manifest
import android.app.DownloadManager
import android.content.*
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.provider.OpenableColumns
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import okhttp3.*
import okio.BufferedSink
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private lateinit var channel:MethodChannel
    private val executor=Executors.newSingleThreadExecutor()
    private val client=OkHttpClient.Builder().build()
    private var uploadResult:MethodChannel.Result?=null
    private var uploadArgs:Map<String,Any?>?=null
    private var conflictingUri:Uri?=null
    private var conflictingArgs:Map<String,Any?>?=null
    private var permissionResult:MethodChannel.Result?=null
    private var permissionArgs:Map<String,Any?>?=null
    private var saveAsResult:MethodChannel.Result?=null
    private var saveAsArgs:Map<String,Any?>?=null
    private val prefs get()=getSharedPreferences("transfers",0)
    private val downloads get()=getSystemService(DOWNLOAD_SERVICE) as DownloadManager
    override fun configureFlutterEngine(engine:FlutterEngine) {
        super.configureFlutterEngine(engine)
        channel=MethodChannel(engine.dartExecutor.binaryMessenger,"nexuslink/workspace")
        channel.setMethodCallHandler { call,result ->
            val args=call.arguments as? Map<String,Any?> ?: emptyMap()
            fun text(key:String)=args[key] as? String ?: ""
            try {
                when(call.method) {
                    "credential.get" -> result.success(Credentials.get(this,text("host")))
                    "credential.set" -> { Credentials.put(this,text("host"),text("value"));result.success(null) }
                    "credential.remove" -> { Credentials.remove(this,text("host"));result.success(null) }
                    "download.start" -> {
                        if(Build.VERSION.SDK_INT<29 && checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)!=PackageManager.PERMISSION_GRANTED) {
                            permissionResult=result;permissionArgs=args;requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),45)
                        } else enqueue(args,result)
                    }
                    "download.saveAs" -> {
                        if(saveAsResult!=null)throw Exception("A Save as picker is already open")
                        saveAsResult=result;saveAsArgs=args
                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT)
                            .setType("application/octet-stream")
                            .addCategory(Intent.CATEGORY_OPENABLE)
                            .putExtra(Intent.EXTRA_TITLE,text("name")),46)
                    }
                    "download.list" -> result.success(listDownloads())
                    "download.cancel" -> { val id=(args["id"] as Number).toLong();downloads.remove(id);prefs.edit().putString("state:$id","canceled").apply();result.success(null) }
                    "download.open" -> { val uri=downloads.getUriForDownloadedFile((args["id"] as Number).toLong())?:throw Exception("Download is not complete"); startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri,downloads.getMimeTypeForDownloadedFile((args["id"] as Number).toLong())).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION));result.success(null) }
                    "download.show" -> { startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS));result.success(null) }
                    "download.share" -> { val id=(args["id"] as Number).toLong();val uri=downloads.getUriForDownloadedFile(id)?:throw Exception("Download is not complete");startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType(downloads.getMimeTypeForDownloadedFile(id)?:"application/octet-stream").putExtra(Intent.EXTRA_STREAM,uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),"Share file"));result.success(null) }
                    "upload.pick" -> { if(uploadResult!=null)throw Exception("An upload picker is already open");uploadResult=result;uploadArgs=args;startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE),44) }
                    "upload.retry" -> { val uri=conflictingUri?:throw Exception("No upload is waiting for overwrite approval");val saved=conflictingArgs?:throw Exception("Upload selection expired");conflictingUri=null;conflictingArgs=null;upload(uri,saved,result,true) }
                    "live.status" -> {
                        val livePrefs=getSharedPreferences("live",0)
                        val notificationManager=getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
                        val channelAvailable=Build.VERSION.SDK_INT<26 || (notificationManager.getNotificationChannel("task_attention")?.importance ?: 0)>0
                        val notificationPermission=Build.VERSION.SDK_INT<33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)==PackageManager.PERMISSION_GRANTED
                        result.success(mapOf(
                            "running" to LiveActivityService.running,
                            "monitoringRequested" to livePrefs.getBoolean("requested",false),
                            "serviceRunning" to LiveActivityService.running,
                            "connectionState" to LiveActivityService.connectionState,
                            "notificationPermission" to notificationPermission,
                            "notificationChannelAvailable" to (notificationManager.areNotificationsEnabled() && channelAvailable),
                            "overlay" to Settings.canDrawOverlays(this),
                            "overlayPermission" to Settings.canDrawOverlays(this),
                            "bubble" to livePrefs.getBoolean("bubble",false),
                            "bubbleRequested" to livePrefs.getBoolean("bubble",false),
                            "bubbleVisible" to LiveActivityService.bubbleVisible,
                            "bubbleHiddenReason" to LiveActivityService.bubbleHiddenReason,
                            "notificationActionsEnabled" to livePrefs.getBoolean("actions",false),
                            "actionsAllowedLocked" to livePrefs.getBoolean("actionsLocked",false),
                            "lastActionableError" to LiveActivityService.lastError
                        ))
                    }
                    "live.permission" -> {startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,Uri.parse("package:$packageName")));result.success(null)}
                    "live.appInfo" -> {startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:$packageName")));result.success(null)}
                    "live.configureActions" -> {
                        val livePrefs=getSharedPreferences("live",0)
                        val locked=args["locked"]==true
                        val enabled=args["enabled"]==true || locked
                        livePrefs.edit().putBoolean("actions",enabled).putBoolean("actionsLocked",enabled && locked).apply()
                        result.success(mapOf("enabled" to enabled,"locked" to (enabled && locked)))
                    }
                    "live.testNotification" -> {
                        val manager=getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
                        if(Build.VERSION.SDK_INT>=26 && manager.getNotificationChannel("task_attention")==null)
                            manager.createNotificationChannel(android.app.NotificationChannel("task_attention","Task updates",android.app.NotificationManager.IMPORTANCE_HIGH))
                        val allowed=(Build.VERSION.SDK_INT<33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)==PackageManager.PERMISSION_GRANTED) && manager.areNotificationsEnabled()
                        if(allowed)manager.notify("watch-test",9003,NotificationCompat.Builder(this,"task_attention")
                            .setSmallIcon(R.mipmap.ic_launcher).setContentTitle("NexusLink watch test")
                            .setContentText("Check whether this appears on your watch.")
                            .setContentIntent(android.app.PendingIntent.getActivity(this,9003,Intent(this,MainActivity::class.java),android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE))
                            .setAutoCancel(true).build())
                        result.success(mapOf("posted" to allowed))
                    }
                    "live.start" -> {
                        val intent=Intent(this,LiveActivityService::class.java).putExtra("host",text("host"))
                        if(args.containsKey("bubble")) intent.putExtra("bubble",args["bubble"]==true)
                        if(Build.VERSION.SDK_INT>=26)startForegroundService(intent) else startService(intent)
                        result.success(null)
                    }
                    "live.stop" -> {
                        // An explicit stop: do not restart after reboot. Alerts stay unless asked.
                        getSharedPreferences("live",0).edit().putBoolean("requested",false).apply()
                        LiveActivityService.clearAlertsOnStop=args["clearAlerts"]==true
                        stopService(Intent(this,LiveActivityService::class.java))
                        result.success(null)
                    }
                    "live.pendingTask" -> {val target=intent.getStringExtra("host");val id=intent.getStringExtra("taskId");intent.removeExtra("taskId");intent.removeExtra("host");result.success(if(target==null)null else mapOf("taskId" to id,"host" to target))}
                    else -> result.notImplemented()
                }
            } catch(e:Exception) { result.error("ANDROID",e.message,null) }
        }
    }
    override fun onNewIntent(intent:Intent) {super.onNewIntent(intent);setIntent(intent);if(::channel.isInitialized)channel.invokeMethod("openTask",mapOf("taskId" to intent.getStringExtra("taskId"),"host" to intent.getStringExtra("host")))}
    override fun onResume(){super.onResume();LiveActivityService.visible=true;LiveActivityService.instance?.updateOverlay();resumeMonitoring()}
    /** Monitoring the user left on but Android stopped (or refused to restart in the background) resumes when the app is opened. */
    private fun resumeMonitoring(){
        val live=getSharedPreferences("live",0)
        val host=live.getString("host","").orEmpty()
        if(LiveActivityService.running || !live.getBoolean("requested",false) || host.isEmpty())return
        if(Credentials.get(this,host)==null)return
        try{
            val intent=Intent(this,LiveActivityService::class.java).putExtra("host",host)
            if(Build.VERSION.SDK_INT>=26)startForegroundService(intent) else startService(intent)
        }catch(e:Exception){LiveActivityService.lastError="Could not resume monitoring: ${e.message}"}
    }
    override fun onPause(){super.onPause();LiveActivityService.visible=false;LiveActivityService.instance?.updateOverlay()}
    private fun enqueue(args:Map<String,Any?>,result:MethodChannel.Result) {
        val name=(args["name"] as String).replace(Regex("[\\\\/\\u0000-\\u001f]"),"_")
        val base=File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),"NexusLink")
        var chosen=name;var index=1
        val reserved=prefs.all.values.filterIsInstance<String>().mapNotNull {try{JSONObject(it).optString("name")}catch(e:Exception){null}}.toSet()
        while(File(base,chosen).exists() || reserved.contains(chosen)) {val dot=name.lastIndexOf('.');chosen=if(dot>0)name.substring(0,dot)+" (${index++})"+name.substring(dot) else "$name (${index++})"}
        val request=DownloadManager.Request(Uri.parse(args["url"] as String))
            .addRequestHeader("Authorization","Bearer ${args["token"]}")
            .setTitle(chosen).setDescription("NexusLink · ${args["host"]}")
            .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS,"NexusLink/$chosen")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
        val id=downloads.enqueue(request)
        prefs.edit().putString("download:$id",JSONObject(mapOf("id" to id,"name" to chosen,"host" to args["host"],"path" to args["path"])).toString()).apply()
        result.success(id)
    }
    private fun listDownloads():List<Map<String,Any?>> = prefs.all.filterKeys{it.startsWith("download:")}.values.mapNotNull { raw ->
        try {
            val row=JSONObject(raw as String);val id=row.getLong("id")
            val result=mutableMapOf<String,Any?>("id" to id,"name" to row.getString("name"),"host" to row.optString("host"),"path" to row.optString("path"),"status" to (prefs.getString("state:$id",null)?:"missing"))
            downloads.query(DownloadManager.Query().setFilterById(id)).use { c -> if(c.moveToFirst()) {
                val status=c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                result["status"]=when(status){DownloadManager.STATUS_SUCCESSFUL->"completed";DownloadManager.STATUS_FAILED->"failed";DownloadManager.STATUS_PAUSED->"paused";DownloadManager.STATUS_PENDING->"pending";else->"running"}
                result["bytes"]=c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR));result["total"]=c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES));result["reason"]=c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
            } };result
        }catch(e:Exception){null}
    }.sortedByDescending{(it["id"] as Number).toLong()}
    override fun onRequestPermissionsResult(requestCode:Int,permissions:Array<out String>,results:IntArray){
        super.onRequestPermissionsResult(requestCode,permissions,results)
        if(requestCode==45){val r=permissionResult;val a=permissionArgs;permissionResult=null;permissionArgs=null;if(r!=null&&a!=null){if(results.firstOrNull()==PackageManager.PERMISSION_GRANTED)enqueue(a,r) else r.error("PERMISSION_DENIED","Storage permission is needed to save in Downloads on this Android version.",null)}}
    }
    override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?){
        super.onActivityResult(requestCode,resultCode,data)
        if(requestCode==46){
            val result=saveAsResult?:return;val args=saveAsArgs?:return
            saveAsResult=null;saveAsArgs=null
            val uri=data?.data
            if(resultCode!=RESULT_OK||uri==null){result.success(null);return}
            saveAs(uri,args,result)
            return
        }
        if(requestCode!=44)return
        val result=uploadResult?:return;val args=uploadArgs?:return;uploadResult=null;uploadArgs=null
        val uri=data?.data;if(resultCode!=RESULT_OK||uri==null){result.success(null);return}
        upload(uri,args,result,false)
    }
    private fun saveAs(uri:Uri,args:Map<String,Any?>,result:MethodChannel.Result){
        executor.execute {
            try {
                client.newCall(Request.Builder().url(args["url"] as String)
                    .header("Authorization","Bearer ${args["token"]}").get().build()).execute().use { response ->
                    if(!response.isSuccessful)throw Exception("Download failed (${response.code})")
                    val body=response.body?:throw Exception("PC returned an empty response")
                    val expected=body.contentLength()
                    val output=contentResolver.openOutputStream(uri,"w")?:throw Exception("Cannot open destination")
                    val copied=output.use { body.byteStream().use { it.copyTo(output,65536) } }
                    if(expected>=0 && copied!=expected)throw Exception("Download was incomplete ($copied of $expected bytes)")
                }
                runOnUiThread{result.success(uri.toString())}
            }catch(e:Exception){
                try{contentResolver.delete(uri,null,null)}catch(_:Exception){}
                runOnUiThread{result.error("DOWNLOAD",e.message,null)}
            }
        }
    }
    private fun upload(uri:Uri,args:Map<String,Any?>,result:MethodChannel.Result,overwrite:Boolean) {
        executor.execute {
            try {
                var name="upload"
                contentResolver.query(uri,null,null,null,null)?.use {c->if(c.moveToFirst())name=c.getString(c.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME))}
                name=name.substringAfterLast('/').substringAfterLast('\\').trim()
                if(name.isEmpty() || name=="." || name=="..")throw Exception("Invalid upload filename")
                val builder=Uri.parse(args["base"] as String).buildUpon().appendPath("files").appendQueryParameter("path",(args["directory"] as String).trimEnd('/')+"/"+name)
                if(overwrite)builder.appendQueryParameter("overwrite","1")
                val url=builder.build().toString()
                val body=object:RequestBody(){override fun contentType():MediaType?=null;override fun writeTo(sink:BufferedSink){contentResolver.openInputStream(uri)!!.use{input->val buffer=ByteArray(65536);while(true){val count=input.read(buffer);if(count<0)break;sink.write(buffer,0,count)}}}}
                client.newCall(Request.Builder().url(url).header("Authorization","Bearer ${args["token"]}").post(body).build()).execute().use{response->
                    if(response.code==409 && !overwrite) {
                        conflictingUri=uri;conflictingArgs=args
                        runOnUiThread{result.success(mapOf("conflict" to true,"name" to name))}
                        return@execute
                    }
                    if(!response.isSuccessful)throw Exception("Upload failed (${response.code}): ${response.body?.string()?.take(300)}")
                }
                runOnUiThread{result.success(name)}
            }catch(e:Exception){runOnUiThread{result.error("UPLOAD",e.message,null)}}
        }
    }
}
