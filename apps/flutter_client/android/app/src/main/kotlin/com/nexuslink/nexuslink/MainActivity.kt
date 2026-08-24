package com.nexuslink.nexuslink

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nexuslink/ntfy")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val topic = call.argument<String>("topic").orEmpty()
                        if (topic.isBlank()) {
                            result.error("bad_topic", "missing ntfy topic", null)
                        } else {
                            NtfyListenerService.start(this, topic)
                            result.success(true)
                        }
                    }
                    "stop" -> {
                        NtfyListenerService.stop(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        NtfyListenerService.setUiResumed(this, true)
    }

    override fun onPause() {
        NtfyListenerService.setUiResumed(this, false)
        super.onPause()
    }
}
