package com.example.flutter_pear_example

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * E7.2's hand-rolled native QR scanner -- a full-screen Activity started by
 * [MainActivity]'s "scanQrCode" method channel handler via the Activity
 * Result API. Not a Flutter plugin, not exported: this is app-owned Kotlin
 * (see `build.gradle.kts`'s comment for why that's the safe path under this
 * project's toolchain).
 *
 * Binds a CameraX [Preview] (to a full-screen [PreviewView]) and
 * [ImageAnalysis] (latest-frame-only backpressure, analyzed on
 * [cameraExecutor] rather than the main thread -- ZXing's decode is
 * synchronous, real per-frame CPU work) to this Activity's lifecycle via
 * [ProcessCameraProvider]. Each analyzed frame's Y (luminance) plane is
 * decoded via ZXing's [MultiFormatReader] scoped to [BarcodeFormat.QR_CODE]
 * only -- see [decodeQrFromYPlane] (flutter_pear-64q: swapped from ML Kit,
 * whose barcode-scanning artifact is proprietary despite this file's own
 * build.gradle.kts previously mislabeling it Apache-2.0; ZXing's `core`
 * artifact is Apache-2.0 and, being a plain JVM library with no Android
 * Gradle module of its own, carries none of the AGP9/Kotlin-plugin risk
 * documented there). On the first successfully decoded QR code, the raw
 * text is returned as the `"result"` extra on `RESULT_OK` and the activity
 * finishes. If the user backs out without a successful scan, the result is
 * the standard `RESULT_CANCELED` with no data.
 *
 * Extends [ComponentActivity] (rather than plain `android.app.Activity`)
 * specifically because [androidx.camera.lifecycle.ProcessCameraProvider.bindToLifecycle]
 * requires a [androidx.lifecycle.LifecycleOwner], which only `ComponentActivity`
 * (and its subclasses) implement.
 */
class QrScannerActivity : ComponentActivity() {
    // Guards against overlapping analyzer callbacks both decoding a barcode
    // and both trying to finish() this activity.
    private val resultDelivered = AtomicBoolean(false)

    // ZXing's decode() is synchronous and, per frame, real CPU work (more so
    // with TRY_HARDER below) -- unlike ML Kit's Task-based process(), which
    // offloads internally. Runs the analyzer on this dedicated thread
    // instead of the main executor so decoding never competes with the
    // preview's own UI-thread work (jank/ANR risk). Shut down in
    // onDestroy() so repeated scans don't leak one thread per Activity
    // instance.
    private val cameraExecutor = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Defensive only -- MainActivity's scanQrCode() already refuses to
        // launch this activity without permission. Must not crash if it
        // somehow happens anyway (e.g. permission revoked mid-flight).
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }

        val previewView = PreviewView(this).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        setContentView(previewView)

        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener(
            {
                val cameraProvider = cameraProviderFuture.get()

                val preview = Preview.Builder().build().also {
                    it.surfaceProvider = previewView.surfaceProvider
                }

                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                analysis.setAnalyzer(cameraExecutor, ::analyzeFrame)

                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    preview,
                    analysis,
                )
            },
            ContextCompat.getMainExecutor(this),
        )
    }

    private fun analyzeFrame(imageProxy: ImageProxy) {
        if (resultDelivered.get()) {
            // Already finishing -- no point decoding further frames, but
            // every ImageProxy must still be closed or CameraX's
            // backpressure strategy stalls.
            imageProxy.close()
            return
        }
        // Decoding isn't guaranteed exception-free (an unexpected
        // Image/plane state, for instance) -- if it throws before the
        // finally below runs, this ImageProxy would never close, and
        // STRATEGY_KEEP_ONLY_LATEST means that single unclosed frame
        // permanently stalls all future frame delivery (the camera appears
        // frozen).
        try {
            val text = decodeQrFromYPlane(
                extractYPlaneBytes(imageProxy.planes[0], imageProxy.width, imageProxy.height),
                imageProxy.width,
                imageProxy.height,
                imageProxy.imageInfo.rotationDegrees,
            )
            if (text != null) handleResult(text)
        } catch (_: Exception) {
            // Transient decode failure -- next frame retries, same contract
            // ML Kit's addOnFailureListener had.
        } finally {
            imageProxy.close()
        }
    }

    private fun handleResult(value: String) {
        if (!resultDelivered.compareAndSet(false, true)) return
        // analyzeFrame runs on cameraExecutor now, not the main thread --
        // setResult()/finish() are Activity calls, meant to run on the main
        // thread like any other.
        runOnUiThread {
            val data = Intent().putExtra("result", value)
            setResult(RESULT_OK, data)
            finish()
        }
    }

    override fun onDestroy() {
        cameraExecutor.shutdown()
        super.onDestroy()
    }

    companion object {
        /**
         * Copies [plane]'s bytes into a tightly-packed `width * height`
         * array, stripping any row-stride padding YUV_420_888 buffers may
         * include beyond [width] bytes per row (not guaranteed equal on
         * every device/resolution). Assumes [plane]'s pixel stride is 1 (a
         * single luminance byte per pixel, with no interleaving) -- true
         * for every real Y plane this project has seen, and required by
         * CameraX's own YUV_420_888 documentation for ImageAnalysis output,
         * but not a type-enforced guarantee. Exposed for
         * [QrScannerActivityTest].
         */
        internal fun extractYPlaneBytes(
            plane: ImageProxy.PlaneProxy,
            width: Int,
            height: Int,
        ): ByteArray {
            val buffer = plane.buffer
            val rowStride = plane.rowStride
            if (rowStride == width) {
                val data = ByteArray(buffer.remaining())
                buffer.get(data)
                return data
            }
            val data = ByteArray(width * height)
            val row = ByteArray(rowStride)
            for (y in 0 until height) {
                // Reads the full rowStride every time (not
                // buffer.remaining(), which would silently blend stale
                // bytes from a PRIOR row into `row` if a read ever came up
                // short) -- if the buffer genuinely has fewer bytes than
                // expected, this throws BufferUnderflowException, which
                // analyzeFrame's catch-all already treats as "skip this
                // frame," a safe failure mode instead of silent corruption.
                buffer.get(row, 0, rowStride)
                System.arraycopy(row, 0, data, y * width, width)
            }
            return data
        }

        /**
         * Rotates the tightly-packed `width * height` single-channel image
         * [yPlane] clockwise by [rotationDegrees] (must be a multiple of
         * 90 -- CameraX never reports anything else) and decodes a QR code
         * from it via ZXing, or returns null if none is found. Exposed
         * top-level (well, as a companion function) so it's unit-testable
         * without a running camera/Activity -- see [QrScannerActivityTest].
         */
        internal fun decodeQrFromYPlane(
            yPlane: ByteArray,
            width: Int,
            height: Int,
            rotationDegrees: Int,
        ): String? {
            var data = yPlane
            var w = width
            var h = height
            repeat((rotationDegrees / 90) % 4) {
                data = rotateYPlane90(data, w, h)
                val swap = w
                w = h
                h = swap
            }
            val source = PlanarYUVLuminanceSource(data, w, h, 0, 0, w, h, false)
            val bitmap = BinaryBitmap(HybridBinarizer(source))
            val reader = MultiFormatReader().apply {
                setHints(
                    mapOf(
                        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                        // ZXing's classical decoder is materially less
                        // tolerant of blur/skew/uneven lighting than ML
                        // Kit's ML-based detector was -- this trades some
                        // extra per-frame CPU (absorbed by cameraExecutor,
                        // not the UI thread) for real-world scan
                        // reliability holding a phone up to another
                        // phone's screen.
                        DecodeHintType.TRY_HARDER to true,
                    ),
                )
            }
            return try {
                reader.decode(bitmap).text
            } catch (_: NotFoundException) {
                null
            }
        }

        /**
         * Rotates a tightly-packed `width * height` single-channel image 90
         * degrees clockwise.
         */
        internal fun rotateYPlane90(data: ByteArray, width: Int, height: Int): ByteArray {
            val rotated = ByteArray(data.size)
            var i = 0
            for (x in 0 until width) {
                for (y in height - 1 downTo 0) {
                    rotated[i++] = data[y * width + x]
                }
            }
            return rotated
        }
    }
}
