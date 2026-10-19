package me.jxl.kiosk_satellite.plugins

import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test

class PluginCameraTest {
    @Test fun cameraOptionsDefaultAndStayInRange() {
        assertEquals(PluginCameraRequest(640, 480, 5, "default", "luminance", 60_000), PluginCameraRequest.parse(emptyMap()))
        assertEquals(
            PluginCameraRequest(1280, 720, 15, "back", "nv21", 600_000),
            PluginCameraRequest.parse(mapOf("size" to "1280x720", "fps" to 15, "facing" to "back", "format" to "nv21", "timeoutSeconds" to 600)),
        )
        // A whole number written as a double is still whole.
        assertEquals(10, PluginCameraRequest.parse(mapOf("fps" to 10.0)).fps)
        for (bad in listOf(
            mapOf("size" to "1920x1080"), mapOf("size" to 640), mapOf("fps" to 0), mapOf("fps" to 16), mapOf("fps" to 2.5),
            mapOf("facing" to "side"), mapOf("format" to "rgb"), mapOf("timeoutSeconds" to 4), mapOf("timeoutSeconds" to 601),
            mapOf("zoom" to 2),
        )) rejects { PluginCameraRequest.parse(bad) }
    }

    @Test fun barcodeOptionsDefaultAndStayInRange() {
        assertEquals(PluginBarcodeRequest(emptyList(), "default", 30_000, null, null), PluginBarcodeRequest.parse(emptyMap()))
        val request = PluginBarcodeRequest.parse(mapOf(
            "formats" to listOf("ean_13", "qr_code", "ean_13"), "facing" to "front", "timeoutSeconds" to 120,
            "title" to "Scan a product", "message" to " ",
        ))
        assertEquals(listOf("ean_13", "qr_code"), request.formats)
        assertEquals(120_000L, request.timeoutMs)
        assertEquals("Scan a product", request.title)
        // A blank message reads as none, so the scanner shows its own.
        assertNull(request.message)
        assertEquals(listOf("upc_a"), PluginBarcodeRequest.parse(mapOf("formats" to arrayOf("upc_a"))).formats)
        for (bad in listOf(
            mapOf("formats" to listOf("ean13")), mapOf("formats" to "qr_code"), mapOf("formats" to listOf(1)),
            mapOf("timeoutSeconds" to 121), mapOf("title" to "x".repeat(81)), mapOf("message" to "x".repeat(201)),
            mapOf("message" to 5), mapOf("torch" to true),
        )) rejects { PluginBarcodeRequest.parse(bad) }
    }

    @Test fun planesArePackedWithoutPadding() {
        // Two rows of three pixels with a row stride of five.
        val luminance = ByteBuffer.wrap(byteArrayOf(1, 2, 3, 0, 0, 4, 5, 6, 0, 0))
        val out = ByteArray(6)
        PluginCameraFrames.copyPlane(luminance, 5, 1, 3, 2, out, 0, 1)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6), out)
        // Interleaved chroma: every other byte, written every other byte.
        val chroma = ByteBuffer.wrap(byteArrayOf(7, 0, 8, 0, 9, 0, 10, 0))
        val interleaved = ByteArray(8)
        PluginCameraFrames.copyPlane(chroma, 4, 2, 2, 2, interleaved, 1, 2)
        assertArrayEquals(byteArrayOf(0, 7, 0, 8, 0, 9, 0, 10), interleaved)
    }

    private fun rejects(action: () -> Unit) {
        try {
            action()
            fail("Expected rejection")
        } catch (_: IllegalArgumentException) {
        }
    }
}
