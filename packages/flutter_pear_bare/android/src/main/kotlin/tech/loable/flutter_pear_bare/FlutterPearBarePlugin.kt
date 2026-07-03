package tech.loable.flutter_pear_bare

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

/**
 * M0 scaffold: a native echo that stands in for the Bare Kit worklet — enough to
 * prove the Dart↔IPC round trip and measure latency/throughput. The real worklet
 * swaps in behind these same channels (see [startWorklet]).
 */
class FlutterPearBarePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var control: MethodChannel
    private lateinit var ipc: BasicMessageChannel<ByteBuffer>
    private var started = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        control = MethodChannel(binding.binaryMessenger, "flutter_pear_bare/control")
        control.setMethodCallHandler(this)

        ipc = BasicMessageChannel(binding.binaryMessenger, "flutter_pear_bare/ipc", BinaryCodec.INSTANCE)
        ipc.setMessageHandler { message, reply ->
            // ponytail: echo now; replace with worklet.write(frame) when Bare Kit
            // lands. Send it back native-initiated so it surfaces on Dart `incoming`.
            if (message != null) ipc.send(message)
            reply.reply(null)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> { startWorklet(); result.success(null) }
            "suspend", "resume" -> result.success(null)
            "terminate" -> { started = false; result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun startWorklet() {
        // Hot-restart safe: Dart state resets but we keep the one worklet running.
        if (started) return
        started = true
        // TODO(M1): boot a Bare Kit Worklet from the bundled pear-end and pipe its
        // IPC to `ipc` instead of echoing.
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        control.setMethodCallHandler(null)
        ipc.setMessageHandler(null)
    }
}
