package com.example.flutter_pear_example

import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * JVM-only unit tests for [QrScannerActivity]'s ZXing decode path
 * (flutter_pear-64q: swapped from ML Kit) -- no Android framework or camera
 * involved, just a real QR code encoded via ZXing's own [QRCodeWriter] and
 * fed back through [QrScannerActivity.decodeQrFromYPlane] as a synthetic
 * luminance plane, the same shape CameraX hands [QrScannerActivity] a real
 * frame in.
 */
class QrScannerActivityTest {
    private fun encodeToYPlane(text: String, size: Int): ByteArray {
        val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size)
        val data = ByteArray(size * size)
        for (y in 0 until size) {
            for (x in 0 until size) {
                // ZXing's BitMatrix: true = a "black" (dark) module. Real
                // camera luminance: dark ink reads as a LOW value, white
                // paper as a HIGH value -- so black -> 0, white -> 255.
                data[y * size + x] = (if (matrix.get(x, y)) 0 else 255).toByte()
            }
        }
        return data
    }

    @Test
    fun `decodes an unrotated QR code`() {
        val size = 200
        val yPlane = encodeToYPlane("flutter_pear-invite-code", size)
        val decoded = QrScannerActivity.decodeQrFromYPlane(yPlane, size, size, 0)
        assertEquals("flutter_pear-invite-code", decoded)
    }

    @Test
    fun `decodes a QR code the camera delivered rotated 90 degrees`() {
        val size = 200
        val yPlane = encodeToYPlane("rotated-payload", size)
        // Simulates CameraX handing analyzeFrame a frame captured in an
        // orientation 90 degrees off from upright -- exactly what
        // rotationDegrees exists to correct for.
        val cameraFrame = QrScannerActivity.rotateYPlane90(yPlane, size, size)
        val decoded = QrScannerActivity.decodeQrFromYPlane(cameraFrame, size, size, 90)
        assertEquals("rotated-payload", decoded)
    }

    @Test
    fun `decodes a QR code the camera delivered rotated 270 degrees`() {
        val size = 200
        val yPlane = encodeToYPlane("two-seventy-payload", size)
        var cameraFrame = yPlane
        repeat(3) { cameraFrame = QrScannerActivity.rotateYPlane90(cameraFrame, size, size) }
        val decoded = QrScannerActivity.decodeQrFromYPlane(cameraFrame, size, size, 270)
        assertEquals("two-seventy-payload", decoded)
    }

    @Test
    fun `returns null, not an exception, when no QR code is present`() {
        val size = 200
        val blankFrame = ByteArray(size * size) { 255.toByte() } // plain white frame
        val decoded = QrScannerActivity.decodeQrFromYPlane(blankFrame, size, size, 0)
        assertNull(decoded)
    }

    @Test
    fun `rotateYPlane90 applied four times returns the original image`() {
        val width = 5
        val height = 3
        val original = ByteArray(width * height) { it.toByte() }
        var rotated = original
        var w = width
        var h = height
        repeat(4) {
            rotated = QrScannerActivity.rotateYPlane90(rotated, w, h)
            val swap = w
            w = h
            h = swap
        }
        assertArrayEquals(original, rotated)
    }
}
