package io.github.ccch1mneyyy.dsh_app.lom

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel `dsh/lom_relay`: `start` / `stop` the [LomRelayService]
 * foreground service that keeps the Lom relay connection alive while the
 * app is backgrounded (doc §05). A no-op without the native side.
 */
class LomRelayPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var context: Context
    private lateinit var methods: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                LomRelayService.ensure(context, true)
                result.success(null)
            }
            "stop" -> {
                LomRelayService.ensure(context, false)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        const val CHANNEL = "dsh/lom_relay"
    }
}
