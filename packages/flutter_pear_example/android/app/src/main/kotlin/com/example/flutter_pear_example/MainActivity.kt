package com.example.flutter_pear_example

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/**
 * E7.2: hand-rolled native QR pairing support, owned directly by this app
 * module (see [build.gradle.kts]'s comment for why this isn't a Flutter
 * plugin). Exposes camera-permission status/request and the QR scanner
 * activity to Dart over the "flutter_pear_example/qr_scanner" method
 * channel -- [QrScannerChannel] on the Dart side is the typed wrapper
 * around this exact contract.
 *
 * Also exposes a hand-rolled Storage Access Framework file picker over the
 * "flutter_pear_example/file_picker" method channel (replacing the
 * `file_picker` pub.dev plugin, which hits the same AGP/Kotlin toolchain gap
 * as the QR scanner's plugin alternatives -- see CLAUDE.md / bd
 * `flutter_pear-jqe`). Unlike the camera, SAF needs no runtime permission at
 * all: the system document picker handles the access grant transparently.
 * [FilePickerChannel] on the Dart side is the typed wrapper around this
 * contract.
 *
 * Also exposes open/share for received files over the
 * "flutter_pear_example/share_open" method channel (DES-T1): `ACTION_VIEW`/
 * `ACTION_SEND` via a `FileProvider` content URI, never a bare `file://`
 * path (not accessible to other apps on API 24+). `ShareOpenChannel` on the
 * Dart side is the typed wrapper.
 *
 * Extends [FlutterFragmentActivity] rather than the plain `FlutterActivity`
 * specifically because `registerForActivityResult` (the modern Activity
 * Result API used by [scanQrCode] and [pickFile]) is only available on
 * `androidx.activity.ComponentActivity` -- `FlutterActivity` extends plain
 * `android.app.Activity`, `FlutterFragmentActivity` extends
 * `androidx.fragment.app.FragmentActivity` (a `ComponentActivity`).
 */
class MainActivity : FlutterFragmentActivity() {
    private companion object {
        const val CHANNEL = "flutter_pear_example/qr_scanner"
        const val FILE_PICKER_CHANNEL = "flutter_pear_example/file_picker"
        const val SHARE_OPEN_CHANNEL = "flutter_pear_example/share_open"
        const val CAMERA_PERMISSION_REQUEST_CODE = 4242
        const val PREFS_NAME = "flutter_pear_example_prefs"
        const val PREF_CAMERA_PERMISSION_REQUESTED_BEFORE = "camera_permission_requested_before"
    }

    private lateinit var prefs: SharedPreferences
    private lateinit var scanQrCodeLauncher: ActivityResultLauncher<Intent>
    private lateinit var pickFileLauncher: ActivityResultLauncher<Array<String>>

    // Exactly one of each may be in flight at a time -- all three are only
    // ever set right before starting the async operation they resolve, and
    // cleared (nulled) the moment they're resolved.
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingScanResult: MethodChannel.Result? = null
    private var pendingPickFileResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)

        // Must be registered before the Activity reaches STARTED -- onCreate
        // is the right place, not some later lazy-init path.
        scanQrCodeLauncher =
            registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { activityResult ->
                val result = pendingScanResult
                pendingScanResult = null
                if (result == null) return@registerForActivityResult
                if (activityResult.resultCode == RESULT_OK) {
                    result.success(activityResult.data?.getStringExtra("result"))
                } else {
                    result.success(null)
                }
            }

        pickFileLauncher =
            registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
                val result = pendingPickFileResult
                pendingPickFileResult = null
                if (result == null) return@registerForActivityResult
                if (uri == null) {
                    result.success(null)
                    return@registerForActivityResult
                }
                try {
                    val name = displayNameFor(uri)
                    val file = copyUriToCache(uri, name)
                    result.success(mapOf("path" to file.absolutePath, "name" to name))
                } catch (e: Exception) {
                    result.error("FILE_PICK_FAILED", e.message, null)
                }
            }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkCameraPermission" -> result.success(currentPermissionStatus())
                "requestCameraPermission" -> requestCameraPermission(result)
                "scanQrCode" -> scanQrCode(result)
                "openAppSettings" -> result.success(openAppSettings())
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_PICKER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFile" -> pickFile(result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_OPEN_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openFile" -> openFile(call.argument("path"), result)
                    "shareFile" -> shareFile(call.argument("path"), result)
                    "shareText" -> shareText(call.argument("text"), result)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * "granted" if already granted. Otherwise "notDetermined" if the OS
     * permission dialog has never been shown to the user before (tracked
     * via [PREF_CAMERA_PERMISSION_REQUESTED_BEFORE], since Android itself
     * exposes no such flag). Otherwise "denied" (can ask again) or
     * "permanentlyDenied" (user checked "don't ask again", or the device
     * policy blocks it outright) based on
     * [ActivityCompat.shouldShowRequestPermissionRationale] -- the same
     * heuristic real permission-status libraries use, since Android
     * provides no direct "permanently denied" signal.
     */
    private fun currentPermissionStatus(): String {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return "granted"
        }
        if (!prefs.getBoolean(PREF_CAMERA_PERMISSION_REQUESTED_BEFORE, false)) {
            return "notDetermined"
        }
        return if (ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.CAMERA)) {
            "denied"
        } else {
            "permanentlyDenied"
        }
    }

    private fun requestCameraPermission(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success("granted")
            return
        }
        // A second requestCameraPermission call before the first resolves
        // would otherwise silently orphan it -- only the comment above
        // pendingPermissionResult's declaration enforced "one at a time",
        // not any code. Resolve the superseded one explicitly instead of
        // leaving its Dart-side await hanging forever.
        pendingPermissionResult?.error(
            "SUPERSEDED",
            "A newer requestCameraPermission call replaced this one",
            null,
        )
        // Set BEFORE requesting: onRequestPermissionsResult must be able to
        // tell "denied" from "permanentlyDenied" once the dialog closes, and
        // that heuristic itself depends on this flag already being true.
        prefs.edit().putBoolean(PREF_CAMERA_PERMISSION_REQUESTED_BEFORE, true).apply()
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.CAMERA),
            CAMERA_PERMISSION_REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CAMERA_PERMISSION_REQUEST_CODE) return
        val result = pendingPermissionResult
        pendingPermissionResult = null
        result?.success(currentPermissionStatus())
    }

    private fun scanQrCode(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.error("PERMISSION_DENIED", "Camera permission is not granted", null)
            return
        }
        // See the matching comment in requestCameraPermission() -- don't
        // silently orphan an overlapping call.
        pendingScanResult?.error(
            "SUPERSEDED",
            "A newer scanQrCode call replaced this one",
            null,
        )
        pendingScanResult = result
        scanQrCodeLauncher.launch(Intent(this, QrScannerActivity::class.java))
    }

    override fun onDestroy() {
        // A system-initiated destroy of this (backgrounded) Activity while
        // QrScannerActivity, the permission dialog, or the system document
        // picker is still foreground (e.g. low-memory reclaim, or the
        // "Don't keep activities" dev option) tears this Activity's
        // per-instance FlutterEngine down right along with it. Any Result
        // still pending at that point would otherwise be silently discarded
        // with its Dart-side await left hanging forever with no error --
        // resolve it explicitly first.
        pendingPermissionResult?.error(
            "ACTIVITY_DESTROYED",
            "MainActivity was destroyed while this call was pending",
            null,
        )
        pendingPermissionResult = null
        pendingScanResult?.error(
            "ACTIVITY_DESTROYED",
            "MainActivity was destroyed while this call was pending",
            null,
        )
        pendingScanResult = null
        pendingPickFileResult?.error(
            "ACTIVITY_DESTROYED",
            "MainActivity was destroyed while this call was pending",
            null,
        )
        pendingPickFileResult = null
        super.onDestroy()
    }

    private fun openAppSettings(): Boolean =
        try {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        } catch (_: Exception) {
            false
        }

    private fun pickFile(result: MethodChannel.Result) {
        // See the matching comment in requestCameraPermission() -- don't
        // silently orphan an overlapping call.
        pendingPickFileResult?.error(
            "SUPERSEDED",
            "A newer pickFile call replaced this one",
            null,
        )
        pendingPickFileResult = result
        // "*/*" matches file_picker's default FileType.any behavior -- any
        // file type is selectable.
        pickFileLauncher.launch(arrayOf("*/*"))
    }

    /**
     * Opens [path] via `ACTION_VIEW` against a `FileProvider` content URI
     * (DES-T1) -- never a bare `file://` path, which no other app can read
     * on API 24+. Resolves `false` (never throws to Dart) if no installed
     * app can handle it, so the caller can show a snackbar instead of
     * crashing on an unhandled [ActivityNotFoundException].
     */
    private fun openFile(path: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.error("INVALID_ARGS", "path is required", null)
            return
        }
        val uri = contentUriFor(path)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mimeTypeFor(uri, path))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            startActivity(Intent.createChooser(intent, null))
            result.success(true)
        } catch (_: ActivityNotFoundException) {
            result.success(false)
        }
    }

    /** Shares the file at [path] via `ACTION_SEND` with a content URI. */
    private fun shareFile(path: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.error("INVALID_ARGS", "path is required", null)
            return
        }
        val uri = contentUriFor(path)
        val intent = Intent(Intent.ACTION_SEND)
            .setType(mimeTypeFor(uri, path))
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            startActivity(Intent.createChooser(intent, null))
            result.success(true)
        } catch (_: ActivityNotFoundException) {
            result.success(false)
        }
    }

    /** Shares plain [text] (an invite link, for example) via `ACTION_SEND`. */
    private fun shareText(text: String?, result: MethodChannel.Result) {
        if (text == null) {
            result.error("INVALID_ARGS", "text is required", null)
            return
        }
        val intent = Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, text)
        try {
            startActivity(Intent.createChooser(intent, null))
            result.success(true)
        } catch (_: ActivityNotFoundException) {
            result.success(false)
        }
    }

    /** The `FileProvider` content URI for a path under this app's storage. */
    private fun contentUriFor(path: String): Uri =
        FileProvider.getUriForFile(this, "$packageName.fileprovider", File(path))

    /**
     * Resolves a MIME type for [uri]/[path], preferring whatever the
     * content resolver already knows, falling back to a lookup by file
     * extension, and finally to a generic type -- `ACTION_VIEW`/
     * `ACTION_SEND` both need a type to route to the right handler app.
     */
    private fun mimeTypeFor(uri: Uri, path: String): String {
        contentResolver.getType(uri)?.let { return it }
        val extension = path.substringAfterLast('.', "").lowercase()
        if (extension.isEmpty()) return "*/*"
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "*/*"
    }

    /**
     * Resolves the picked document's original display name via
     * [OpenableColumns.DISPLAY_NAME], falling back to the URI's last path
     * segment, or a generated name if even that isn't usable -- a
     * `content://` URI is not required to expose a meaningful display name.
     */
    private fun displayNameFor(uri: Uri): String {
        var name: String? = null
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) name = cursor.getString(index)
                }
            }
        } catch (_: Exception) {
            // Fall through to the URI-segment / generated fallback below.
        }
        return name ?: uri.lastPathSegment?.substringAfterLast('/') ?: "picked_file"
    }

    /**
     * Copies a picked document's content into a real file under this app's
     * cache directory -- [PearDrive.put] (the Dart caller's eventual
     * destination for this path) streams by local file path, never a
     * `content://` URI, so the SAF-returned URI's bytes must land on disk
     * first.
     *
     * Each pick gets its own randomly-named subdirectory rather than a
     * fixed `picked_files/<name>` path: two picks with the same display
     * name (re-picking the same file, or two files both literally named
     * e.g. `photo.jpg`) would otherwise resolve to the exact same path, so
     * a second pick could truncate the bytes out from under a first pick's
     * still-in-flight [PearDrive.put] (which streams asynchronously by
     * path while Dart awaits it).
     */
    private fun copyUriToCache(uri: Uri, name: String): File {
        val pickDir = File(File(cacheDir, "picked_files"), UUID.randomUUID().toString()).apply { mkdirs() }
        val file = File(pickDir, sanitizeFileName(name))
        val input = contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("openInputStream returned null for $uri")
        input.use { openInput ->
            FileOutputStream(file).use { output ->
                openInput.copyTo(output)
            }
        }
        return file
    }

    /**
     * Reduces an untrusted display name down to a bare file name with no
     * directory components, so it's safe to pass to `File(dir, name)`.
     *
     * [displayNameFor] returns [OpenableColumns.DISPLAY_NAME] verbatim from
     * whichever `DocumentsProvider` handled the pick -- any installed app
     * can register one and set that column to an arbitrary string,
     * including path-traversal segments like `"../../shared_prefs/foo.xml"`.
     * `File(name).name` strips everything but the final path segment (no
     * `/`, no `..` walk), and the residual `"."`/`".."`/blank cases (the
     * name *was* only a dot-segment) fall back to a fixed safe name instead
     * of resolving to this pick's own directory or its parent.
     */
    private fun sanitizeFileName(name: String): String {
        val candidate = File(name).name
        return if (candidate.isBlank() || candidate == "." || candidate == "..") "picked_file" else candidate
    }
}
