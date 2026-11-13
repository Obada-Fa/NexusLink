package com.nexus.nexus_audio

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.nexus.nexus_audio.pc.PcPairing
import com.nexus.nexus_audio.pc.PcStream
import com.nexus.nexus_audio.pc.PcStreamEngine
import com.nexus.nexus_audio.pc.PcStreamService
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.sample
import kotlinx.coroutines.launch

/**
 * `nexus/audio` (methods) and `nexus/audio/events` (events) over [PcStreamEngine]; contract in
 * docs/NEXUS-APP-PHASE1.md §5. Permissions are asked by Dart; this only checks them. The pairing comes
 * in with every call and is never stored here; only the "wanted streams" prefs (for [restore]) live in Kotlin.
 */
class NexusAudioPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener,
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var app: Context
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var activity: ActivityPluginBinding? = null
    private var eventScope: CoroutineScope? = null

    /** Calls waiting on the one MediaProjection consent dialog that is up (a second start joins the first). */
    private val pendingConsent = mutableListOf<MethodChannel.Result>()
    private var consentPairing: PcPairing? = null

    // -- FlutterPlugin --------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        app = binding.applicationContext
        PcStreamEngine.init(app)
        methods = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        methods = null
        events = null
        eventScope?.cancel()
        eventScope = null
        finishConsent { it.error(Wire.CONSENT_DENIED, "The app closed before phone audio sharing was allowed.", null) }
        // The streams keep running: they belong to the process and its foreground service, not to this engine.
    }

    // -- ActivityAware --------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activity?.removeActivityResultListener(this)
        activity = null
    }

    // -- methods --------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> start(call, result)
                "stop" -> {
                    PcStreamEngine.stop(Wire.parseStream(call.argument<Any?>("stream")), user = true)
                    result.success(null)
                }
                "stopAll" -> {
                    PcStreamEngine.stopAll(user = true)
                    result.success(null)
                }
                "state" -> result.success(Wire.stateMap(PcStreamEngine.streams.value, PcStreamEngine.micLevel.value))
                "restore" -> {
                    val pairing = Wire.parsePairing(call.argument<Any?>("pairing"))
                    val before = PcStreamEngine.activeKinds
                    PcStreamEngine.restore(pairing, micGranted())
                    result.success((PcStreamEngine.activeKinds - before).isNotEmpty())
                }
                "forgetWanted" -> {
                    PcStreamEngine.forgetWanted()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Wire.BadArgs) {
            result.error(Wire.BAD_ARGS, e.message, null)
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val kind = Wire.parseStream(call.argument<Any?>("stream"))
        val pairing = Wire.parsePairing(call.argument<Any?>("pairing"))
        when (kind) {
            PcStream.MIC -> {
                if (!micGranted()) return result.error(Wire.MIC_PERMISSION, "Microphone access (RECORD_AUDIO) is not granted.", null)
                PcStreamEngine.start(kind, pairing)
                result.success(null)
            }
            PcStream.PLAY_HERE -> {
                PcStreamEngine.start(kind, pairing)
                result.success(null)
            }
            PcStream.SEND_DEVICE -> startDeviceAudio(pairing, result)
        }
    }

    /** Asks for MediaProjection consent; the result goes to [PcStreamService], which starts the stream. */
    private fun startDeviceAudio(pairing: PcPairing, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return result.error(Wire.UNSUPPORTED, "Sharing phone audio needs Android 10 or newer.", null)
        }
        // Playback capture records through AudioRecord, so it needs RECORD_AUDIO like the mic does.
        if (!micGranted()) return result.error(Wire.MIC_PERMISSION, "Microphone access (RECORD_AUDIO) is needed to capture phone audio.", null)
        if (PcStreamEngine.streams.value[PcStream.SEND_DEVICE]?.on == true) return result.success(null)
        consentPairing = pairing // the newest call's pairing wins
        pendingConsent += result
        if (pendingConsent.size > 1) return // the dialog is already up

        val act: Activity = activity?.activity ?: return finishConsent {
            it.error(Wire.CONSENT_DENIED, "No visible screen to ask for phone audio sharing.", null)
        }
        try {
            val mpm = act.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            act.startActivityForResult(mpm.createScreenCaptureIntent(), REQUEST_PROJECTION)
        } catch (e: Exception) {
            finishConsent { it.error(Wire.CONSENT_DENIED, "Android couldn't ask for phone audio sharing: ${e.message}", null) }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PROJECTION) return false
        val pairing = consentPairing
        consentPairing = null
        if (resultCode != Activity.RESULT_OK || data == null || pairing == null) {
            PcStreamEngine.fail(PcStream.SEND_DEVICE, "Phone audio sharing was not allowed.")
            finishConsent { it.error(Wire.CONSENT_DENIED, "Phone audio sharing was not allowed.", null) }
            return true
        }
        try {
            // In memory, not in the Intent, so the token never passes through the system.
            PcStreamEngine.projectionPairing = pairing
            PcStreamService.startProjection(app, resultCode, data)
            finishConsent { it.success(null) }
        } catch (e: Exception) {
            PcStreamEngine.projectionPairing = null
            PcStreamEngine.fail(PcStream.SEND_DEVICE, "Android didn't hand over phone audio. Try again.")
            finishConsent { it.error(Wire.CONSENT_DENIED, "Android didn't hand over phone audio: ${e.message}", null) }
        }
        return true
    }

    private fun finishConsent(reply: (MethodChannel.Result) -> Unit) {
        val waiting = pendingConsent.toList()
        pendingConsent.clear()
        waiting.forEach { runCatching { reply(it) } }
    }

    private fun micGranted(): Boolean =
        ContextCompat.checkSelfPermission(app, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    // -- events ---------------------------------------------------------------

    @OptIn(FlowPreview::class)
    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventScope?.cancel()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        eventScope = scope
        scope.launch { PcStreamEngine.streams.collect { sink.success(Wire.streamsEvent(it)) } }
        // micLevel changes every 20 ms chunk while the mic captures, and its fall-off never quite reaches 0.
        // Rounded to 0.01, repeats dropped, then sampled: <= 15 events/s, none while the room is silent.
        scope.launch {
            PcStreamEngine.micLevel.map(Wire::quantizeLevel).distinctUntilChanged()
                .sample(Wire.MIC_LEVEL_PERIOD_MS).collect { sink.success(Wire.micLevelEvent(it)) }
        }
        scope.launch { PcStreamEngine.notices.collect { sink.success(Wire.noticeEvent(it)) } }
    }

    override fun onCancel(arguments: Any?) {
        eventScope?.cancel()
        eventScope = null
    }

    companion object {
        const val METHOD_CHANNEL = "nexus/audio"
        const val EVENT_CHANNEL = "nexus/audio/events"
        /** Arbitrary, but unlikely to clash with the host app's other activity results. */
        const val REQUEST_PROJECTION = 0x4E41
    }
}
