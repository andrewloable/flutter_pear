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
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.atomic.AtomicBoolean

/**
 * E7.2's hand-rolled native QR scanner -- a full-screen Activity started by
 * [MainActivity]'s "scanQrCode" method channel handler via the Activity
 * Result API. Not a Flutter plugin, not exported: this is app-owned Kotlin
 * (see `build.gradle.kts`'s comment for why that's the safe path under this
 * project's toolchain).
 *
 * Binds a CameraX [Preview] (to a full-screen [PreviewView]) and
 * [ImageAnalysis] (latest-frame-only backpressure) to this Activity's
 * lifecycle via [ProcessCameraProvider]. Each analyzed frame runs through an
 * ML Kit [com.google.mlkit.vision.barcode.BarcodeScanner] scoped to
 * [Barcode.FORMAT_QR_CODE] only. On the first successfully decoded barcode
 * with a non-null [Barcode.getRawValue], the raw string is returned as the
 * `"result"` extra on `RESULT_OK` and the activity finishes. If the user
 * backs out without a successful scan, the result is the standard
 * `RESULT_CANCELED` with no data.
 *
 * Extends [ComponentActivity] (rather than plain `android.app.Activity`)
 * specifically because [androidx.camera.lifecycle.ProcessCameraProvider.bindToLifecycle]
 * requires a [androidx.lifecycle.LifecycleOwner], which only `ComponentActivity`
 * (and its subclasses) implement.
 */
class QrScannerActivity : ComponentActivity() {
    private val barcodeScanner by lazy {
        BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build(),
        )
    }

    // Guards against overlapping analyzer callbacks both decoding a barcode
    // and both trying to finish() this activity.
    private val resultDelivered = AtomicBoolean(false)

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
                analysis.setAnalyzer(ContextCompat.getMainExecutor(this), ::analyzeFrame)

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
        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            imageProxy.close()
            return
        }
        // fromMediaImage()/process() aren't guaranteed exception-free (an
        // unexpected Image format/state, for instance) -- if either throws
        // before addOnCompleteListener attaches, this ImageProxy would
        // never close, and STRATEGY_KEEP_ONLY_LATEST means that single
        // unclosed frame permanently stalls all future frame delivery (the
        // camera appears frozen). try/catch here guarantees close() always
        // runs.
        try {
            val inputImage =
                InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
            barcodeScanner.process(inputImage)
                .addOnSuccessListener { barcodes -> handleBarcodes(barcodes) }
                .addOnFailureListener { /* transient decode failure -- next frame retries */ }
                .addOnCompleteListener { imageProxy.close() }
        } catch (_: Exception) {
            imageProxy.close()
        }
    }

    private fun handleBarcodes(barcodes: List<Barcode>) {
        if (resultDelivered.get()) return
        val value = barcodes.firstNotNullOfOrNull { it.rawValue } ?: return
        if (!resultDelivered.compareAndSet(false, true)) return
        val data = Intent().putExtra("result", value)
        setResult(RESULT_OK, data)
        finish()
    }

    override fun onDestroy() {
        barcodeScanner.close()
        super.onDestroy()
    }
}
