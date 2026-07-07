package tech.loable.flutter_pear_bare

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import java.nio.ByteBuffer
import to.holepunch.bare.kit.IPC
import to.holepunch.bare.kit.Worklet

private const val TAG = "FlutterPearBarePlugin"

/** Subpath (within `flutter_pear`'s Flutter assets) of the bundled pear-end. */
private const val BUNDLE_ASSET_SUBPATH = "assets/pear-end.bundle"
private const val BUNDLE_PACKAGE = "flutter_pear"

// Worklet lifecycle (mirrors WorkletState in bare_worklet.dart). This
// comment block is duplicated VERBATIM in FlutterPearBarePlugin.kt and
// FlutterPearBarePlugin.swift (eng-4A) -- edit both together, never just
// one, or the two hosts silently drift apart.
//
//   stopped --start() (fresh boot)--> running --suspend()--> suspended
//      ^                                 |  ^                    |
//      |                                 |  |--------resume()----|
//      |--------------terminate()--------|
//      |
//      |--onWorkletExit (crash backstop, from EITHER running or suspended)
//
//   Reattach: start() on an already-running worklet (e.g. a Dart hot
//   restart) goes running -> running directly, same generation id, never
//   through stopped. A fresh start() (stopped -> running) always bumps the
//   generation id. onWorkletExit always reports the generation captured
//   when the exit was detected, so a stale straggler from an earlier
//   generation is never misattributed to the current one (flutter_pear-3vh).
//
// iOS-only addition (flutter_pear-ovt.3.4, D11): Dart's own linger Timer
// (lifecycle.dart) was found to freeze entirely while the app is
// backgrounded on the simulator, only firing once the app returns to the
// foreground -- too late to have suspended anything for real. The iOS host
// arms BareKit's own suspendWithLinger on didEnterBackgroundNotification,
// which BareKit tracks natively and can act on even if the Dart isolate
// never runs again before the process is reclaimed. The Android host has
// no equivalent observer: its Dart-side timer already suspends correctly,
// so it needs no functional change for D11, only this mirrored comment.

/**
 * Boots a Bare Kit [Worklet] from the bundled pear-end and pipes its [IPC]
 * bidirectionally to Dart over the `flutter_pear_bare/ipc` channel.
 *
 * The worklet and its IPC pipe live in [Companion] (JVM-static), not on the
 * plugin instance: a Flutter hot restart tears down and recreates the Dart
 * VM (and, often, this plugin object) without killing the Android process,
 * so [startWorklet] must detect and reattach to an already-running worklet
 * rather than boot a second one — Bare Kit itself has no such reattach
 * concept, so this class is where that guarantee lives.
 *
 * Also the backstop half of E2.6's crash observation: Bare Kit's [Worklet]
 * exposes no exit/crash callback at all (checked against its actual Java
 * API), so [relayFromWorklet]'s read loop ending unexpectedly (as opposed to
 * via our own [terminateWorklet]) is the only native-level signal available
 * that the worklet is gone, reported to Dart over the `control` channel via
 * `onWorkletExit`. The much more common, detailed case — a JS exception the
 * worklet catches on its own way down — is reported by pear-end itself over
 * the ordinary IPC data channel (see index.js's `Bare.on(...)` handlers);
 * this backstop only fires for whatever's left (a crash too early for that
 * JS handler to have registered, or a native-level abort bypassing JS
 * entirely).
 */
class FlutterPearBarePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var control: MethodChannel
    // StandardMessageCodec, not BinaryCodec: BasicMessageChannel<ByteBuffer>
    // with BinaryCodec silently delivers EMPTY data to Dart on native-to-Dart
    // sends on this Flutter/Android combination (reproduced with a minimal
    // hardcoded buffer, unrelated to bare-kit or buffer lifetime -- matches
    // the long-standing flutter/flutter#19849 class of engine bug).
    // StandardMessageCodec's well-tested byte[]<->Uint8List encoding works
    // correctly both directions; the extra type-tag byte is negligible
    // overhead for these small control-plane frames.
    private lateinit var ipc: BasicMessageChannel<Any?>
    private lateinit var applicationContext: Context
    private lateinit var bundleAssetPath: String

    // False once this instance has been detached (e.g. a hot restart moved
    // on to a new plugin instance/engine) — a read-loop closure captured
    // before detach checks this so it stops forwarding to the now-dead
    // `ipc` channel instead of silently dropping worklet data into the void.
    private var attached = true

    private companion object {
        private var worklet: Worklet? = null
        private var workletIpc: IPC? = null

        // Identifies the CURRENTLY RUNNING worklet process/IPC pair -- bumped
        // only on a fresh boot (startWorklet's worklet == null branch), left
        // unchanged across a reattach (same native worklet, just a new Dart
        // isolate after a hot restart). Echoed to Dart in "start"'s result
        // and stamped on every onWorkletExit call (see reportUnexpectedExit)
        // so bare_worklet.dart can tell a genuine exit of ITS OWN generation
        // apart from a stale straggler about an earlier one that Flutter's
        // engine buffered and replayed to a since-reassigned handler
        // (flutter_pear-3vh).
        private var workletGeneration = 0
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        bundleAssetPath =
            binding.flutterAssets.getAssetFilePathBySubpath(BUNDLE_ASSET_SUBPATH, BUNDLE_PACKAGE)

        control = MethodChannel(binding.binaryMessenger, "flutter_pear_bare/control")
        control.setMethodCallHandler(this)

        ipc = BasicMessageChannel(binding.binaryMessenger, "flutter_pear_bare/ipc", StandardMessageCodec.INSTANCE)
        ipc.setMessageHandler { message, reply ->
            if (message is ByteArray) {
                val buffer = ByteBuffer.allocateDirect(message.size).apply {
                    put(message)
                    flip()
                }
                workletIpc?.write(buffer) { error ->
                    if (error != null) Log.e(TAG, "write to worklet failed", error)
                }
            }
            reply.reply(null)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                try {
                    // E6.3: whether this call reattached to an already-running
                    // worklet (a Dart hot restart) or booted a fresh one is
                    // otherwise invisible to Dart -- both `BareWorklet.start()`
                    // calls look identical from the Dart side. Reporting it
                    // lets Pear.start's attach.info health probe use a SHORT
                    // bound only for the reattach case (where an unresponsive
                    // worklet really is suspicious) and the normal, longer
                    // bound for a genuine cold boot (real JS engine + native
                    // module init that legitimately takes real time).
                    val reattached = startWorklet()
                    result.success(mapOf("reattached" to reattached, "generationId" to workletGeneration))
                } catch (e: Throwable) {
                    // Throwable, not Exception: native/JNI failures (e.g. a
                    // missing or ABI-mismatched libbare-kit.so) surface as
                    // UnsatisfiedLinkError/LinkageError, not Exception. A
                    // genuine native-side crash (segfault) can't be caught
                    // here at all -- that's a platform limit, not one this
                    // catch clause can widen further.
                    result.error("worklet_start_failed", e.message, null)
                }
            }
            "suspend" -> withRunningWorklet(result) { it.suspend() }
            "resume" -> withRunningWorklet(result) { it.resume() }
            "terminate" -> { terminateWorklet(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private inline fun withRunningWorklet(result: MethodChannel.Result, action: (Worklet) -> Unit) {
        val w = worklet
        if (w == null) {
            result.error("worklet_not_started", "no worklet is running", null)
        } else {
            action(w)
            result.success(null)
        }
    }

    /** Returns true if this call reattached to an already-running worklet, false if it booted a fresh one. */
    private fun startWorklet(): Boolean {
        // Hot-restart safe: Dart state resets but the native worklet keeps
        // running — just re-point the read loop at the (new) Dart-side ipc.
        if (worklet != null) {
            relayFromWorklet()
            return true
        }

        // Read via AssetManager (not Worklet's InputStream overload, which
        // calls source.reset() with no preceding mark() — relies on
        // reset()-without-mark() being a no-op "seek to start" for whatever
        // stream type it's handed; safer to own the bytes ourselves).
        val bytes = applicationContext.assets
            .open(bundleAssetPath)
            .use { it.readBytes() }
        val source = ByteBuffer.allocateDirect(bytes.size).apply {
            put(bytes)
            flip()
        }

        val w = try {
            Worklet(null)
        } catch (e: LinkageError) {
            // E4.5: caught here (LinkageError covers both UnsatisfiedLinkError
            // from a direct dlopen failure and ExceptionInInitializerError if
            // bare-kit's Java binding loads its native lib from a static
            // initializer instead) rather than predicted in advance -- a
            // device-capability check (Build.SUPPORTED_ABIS) or a
            // native-library-directory file check were both tried and
            // rejected: SUPPORTED_ABIS reflects what the DEVICE can run, not
            // what's actually packaged in the CURRENTLY INSTALLED app/split,
            // so it can't tell a correctly-targeted install apart from a
            // wrong split landing on an otherwise-compatible multi-ABI
            // device; a nativeLibraryDir file-existence check was confirmed
            // (via a real on-device dump) to always report empty when
            // extractNativeLibs=false (the modern default -- native libs
            // load directly from the APK, never extracted to a directory),
            // which would false-positive-fail every correctly-packaged
            // build using that mode. Reacting to the actual failure, whatever
            // its cause, is the only reliable signal.
            throw UnsupportedOperationException(
                "flutter_pear_bare failed to load its native binaries (${e.message}). " +
                    "flutter_pear_bare only ships native code for arm64-v8a/x86_64 -- this " +
                    "usually means the installed app/split is missing them (e.g. an " +
                    "armeabi-v7a split from `flutter build apk --split-per-abi`, which ships " +
                    "by default alongside the arm64-v8a/x86_64 ones, or a device whose " +
                    "supported ABIs (${android.os.Build.SUPPORTED_ABIS.joinToString(", ")}) " +
                    "flutter_pear_bare doesn't cover). Reinstall the arm64-v8a or x86_64 " +
                    "variant. See packages/flutter_pear/docs/troubleshooting.md#abi-mismatch.", e)
        }
        // argv[0] = this app's private files directory (E4.4): bare-os's
        // cwd() resolves to "/" in this sandbox (confirmed on-device, not
        // the app's own storage), and neither BareKit nor Bare expose a
        // storage-path helper -- argv is the only channel available to hand
        // the JS side a real, writable, per-app location. See index.js's
        // BULK_STORAGE_DIR (the file-path bulk seam, codex #4 LOCKED).
        w.start("/pear-end.bundle", source, arrayOf(applicationContext.filesDir.absolutePath))
        worklet = w
        workletIpc = IPC(w)
        workletGeneration++ // a fresh boot is always a NEW generation (flutter_pear-3vh)
        relayFromWorklet()
        return false
    }

    /**
     * Re-arms the worklet -> Dart read loop. [IPC.read] delivers one chunk
     * per call (synchronously if data is already buffered, otherwise via a
     * one-shot native poll callback), so each successful delivery
     * re-registers itself to keep the stream flowing. A `null` chunk means
     * the worklet closed its IPC end; the loop stops rather than reattach.
     *
     * The continuation is posted back through the main [Handler] rather
     * than called directly: [IPC.read] can deliver synchronously when data
     * is already buffered, and calling this function directly from inside
     * that callback would recurse on the call stack once per chunk with no
     * return in between -- a worklet streaming a continuous burst would
     * eventually blow the stack. Posting breaks each chunk into its own
     * Looper iteration instead.
     */
    private fun relayFromWorklet() {
        val activeIpc = workletIpc ?: return
        // Captured once per arm, alongside `activeIpc` -- see
        // reportUnexpectedExit's doc for why this is what lets Dart reject a
        // stale exit report instead of just this native-side check (which
        // only protects against misattributing a signal to the WRONG
        // in-process companion state, not against Dart itself having since
        // reassigned its handler to a newer generation by the time this
        // control-channel call is actually delivered).
        val activeGeneration = workletGeneration
        activeIpc.read { data, error ->
            // Stale-callback guard: this closure was armed against
            // `activeIpc`. If a restart replaced it with a fresh IPC, or
            // terminate() nulled it out, the companion has moved on --
            // don't re-arm (would touch a closed/freed native handle) and
            // don't forward data for a worklet generation nobody is
            // listening to anymore.
            if (workletIpc !== activeIpc) return@read
            if (error != null) {
                Log.e(TAG, "read from worklet failed", error)
                reportUnexpectedExit("ipc read error: ${error.message}", activeGeneration)
                return@read
            }
            if (data == null) {
                // E2.6 backstop: the worklet's IPC ended without us calling
                // terminate() ourselves (the stale-callback guard above
                // already ruled that case out -- if this were OUR
                // terminateWorklet(), workletIpc would already be a
                // different reference or null by now). Most crashes are
                // already reported in detail by pear-end's own
                // Bare.on('uncaughtException'/'unhandledRejection')
                // handler over the IPC data channel itself (see
                // index.js) before it calls Bare.exit() -- this fires
                // for whatever's left: a crash too early for that JS
                // handler to have registered, or a native-level abort
                // bypassing JS entirely. No detail is available, only
                // that it happened.
                reportUnexpectedExit("worklet IPC ended unexpectedly", activeGeneration)
                return@read
            }
            // StandardMessageCodec sends a ByteArray, not the ByteBuffer
            // bare-kit handed us directly (see the `ipc` field doc).
            val bytes = ByteArray(data.remaining())
            data.get(bytes)
            if (attached) ipc.send(bytes)
            Handler(Looper.getMainLooper()).post { relayFromWorklet() }
        }
    }

    /**
     * Tears down this generation's companion state (so the next [startWorklet]
     * boots fresh instead of "reattaching" to a worklet that's actually
     * gone) and notifies Dart via the control channel with [reason] --
     * loudly, in debug output too, per this project's non-negotiable "a
     * silent worklet crash is the worst-case DevEx."
     *
     * [generation] is [relayFromWorklet]'s own captured `activeGeneration`,
     * NOT the (possibly already-bumped) current [workletGeneration] --
     * stamped on the control-channel call so bare_worklet.dart can tell this
     * exit apart from one about a generation it has since replaced
     * (flutter_pear-3vh). Needed because the buffered-message risk this
     * guards against lives entirely on the DART side (Flutter replaying a
     * message to whichever handler is registered by the time it's actually
     * delivered) -- by the time THIS call runs, native already knows (via
     * the `workletIpc !== activeIpc` check in [relayFromWorklet]) that the
     * signal is genuinely about the still-current native generation, but
     * Dart may have moved on regardless before the call is delivered.
     */
    private fun reportUnexpectedExit(reason: String, generation: Int) {
        Log.e(TAG, "worklet exited unexpectedly: $reason")
        workletIpc = null
        worklet = null
        if (attached) {
            control.invokeMethod("onWorkletExit", mapOf("reason" to reason, "generationId" to generation))
        }
    }

    private fun terminateWorklet() {
        // Capture + null the companion fields BEFORE calling native
        // close()/terminate() (E2.6): if IPC.close() synchronously fires
        // relayFromWorklet's pending read callback with data == null, its
        // stale-callback guard (workletIpc !== activeIpc) must already see
        // workletIpc as null/different so it skips reportUnexpectedExit --
        // this is an intentional stop, not a crash to report.
        val ipcToClose = workletIpc
        val workletToTerminate = worklet
        workletIpc = null
        worklet = null
        // IPC must be torn down before/at Worklet.terminate() — Bare Kit
        // doesn't order this itself, and using an IPC built on an already-
        // terminated Worklet touches freed native memory.
        ipcToClose?.close()
        workletToTerminate?.terminate()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        control.setMethodCallHandler(null)
        ipc.setMessageHandler(null)
    }
}
