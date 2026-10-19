package me.jxl.kiosk_satellite.plugins

import android.util.Log
import androidx.camera.core.ImageProxy

/** What a plugin asked openCamera for, checked. */
data class PluginCameraRequest(
    val width: Int,
    val height: Int,
    val fps: Int,
    val facing: String,
    val format: String,
    val timeoutMs: Long,
) {
    companion object {
        val SIZES = mapOf("320x240" to (320 to 240), "640x480" to (640 to 480), "1280x720" to (1280 to 720))

        fun parse(options: Map<String, Any?>): PluginCameraRequest {
            require(options.keys.all { it in setOf("size", "fps", "facing", "format", "timeoutSeconds") }) { "Unknown camera option" }
            val (width, height) = SIZES[(options["size"] ?: "640x480") as? String] ?: throw IllegalArgumentException("Camera size must be 320x240, 640x480 or 1280x720")
            val format = options["format"] ?: "luminance"
            require(format == "luminance" || format == "nv21") { "Camera format must be luminance or nv21" }
            return PluginCameraRequest(
                width, height,
                whole(options["fps"], 5, 1..15, "Camera fps must be 1 to 15"),
                facing(options["facing"]),
                format as String,
                whole(options["timeoutSeconds"], 60, 5..600, "Camera timeoutSeconds must be 5 to 600") * 1000L,
            )
        }
    }
}

/** What a plugin asked scanBarcode for, checked. */
data class PluginBarcodeRequest(
    val formats: List<String>,
    val facing: String,
    val timeoutMs: Long,
    val title: String?,
    val message: String?,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "formats" to formats, "facing" to facing, "timeoutMs" to timeoutMs, "title" to title, "message" to message,
    )

    companion object {
        val FORMATS = setOf(
            "qr_code", "aztec", "data_matrix", "pdf417", "ean_13", "ean_8", "upc_a", "upc_e",
            "code_128", "code_39", "code_93", "codabar", "itf",
        )

        fun parse(options: Map<String, Any?>): PluginBarcodeRequest {
            require(options.keys.all { it in setOf("formats", "facing", "timeoutSeconds", "title", "message") }) { "Unknown barcode option" }
            val formats = when (val value = options["formats"]) {
                null -> emptyList()
                is Collection<*> -> value.map { it as? String ?: "" }
                is Array<*> -> value.map { it as? String ?: "" }
                else -> throw IllegalArgumentException("Barcode formats must be a list")
            }
            require(formats.all { it in FORMATS }) { "Unknown barcode format" }
            return PluginBarcodeRequest(
                formats.distinct(),
                facing(options["facing"]),
                whole(options["timeoutSeconds"], 30, 5..120, "Barcode timeoutSeconds must be 5 to 120") * 1000L,
                text(options["title"], 80, "Barcode title"),
                text(options["message"], 200, "Barcode message"),
            )
        }
    }
}

/** Why a camera claim or a scan ended, as the plugin hears it. */
val PLUGIN_CAMERA_REASONS = setOf("closed", "timeout", "busy", "disabled", "permission", "no_camera", "camera_failed")
val PLUGIN_SCAN_ERRORS = setOf("canceled", "timeout", "busy", "disabled", "permission", "no_camera", "camera_failed", "unavailable")

private fun whole(value: Any?, default: Int, range: IntRange, message: String): Int {
    if (value == null) return default
    require(value is Number && value.toDouble() == Math.floor(value.toDouble()) && value.toInt() in range) { message }
    return value.toInt()
}

private fun facing(value: Any?): String {
    val facing = value ?: "default"
    require(facing == "default" || facing == "front" || facing == "back") { "Camera facing must be default, front or back" }
    return facing as String
}

private fun text(value: Any?, limit: Int, name: String): String? {
    if (value == null) return null
    require(value is String && value.length <= limit) { "$name must be at most $limit characters" }
    return value.ifBlank { null }
}

/**
 * Hands analysis frames from the motion camera session to the plugin
 * holding the camera. The session lives with the Activity and the plugins
 * with the process, so they meet here.
 */
object PluginCameraFrames {
    /** Set while a plugin holds the camera. Called on the analyzer thread with each frame and whether it faces the user. */
    @Volatile var sink: ((ImageProxy, Boolean) -> Unit)? = null

    /** A failing frame is a skipped frame: this runs on the analyzer's thread. */
    fun offer(image: ImageProxy, front: Boolean) {
        val target = sink ?: return
        try { target(image, front) } catch (e: Exception) { Log.w("PluginCamera", "frame dropped: $e") }
    }

    /**
     * The frame's pixels, packed without row padding: the Y plane, then for
     * NV21 the V and U samples interleaved at half resolution. Copied, since
     * the image goes back to the camera as soon as the analyzer returns.
     */
    fun copy(image: ImageProxy, nv21: Boolean): ByteArray {
        val width = image.width
        val height = image.height
        val size = width * height
        val out = ByteArray(if (nv21) size + 2 * ((width + 1) / 2) * ((height + 1) / 2) else size)
        val y = image.planes[0]
        copyPlane(y.buffer, y.rowStride, y.pixelStride, width, height, out, 0, 1)
        if (nv21) {
            val chromaWidth = (width + 1) / 2
            val chromaHeight = (height + 1) / 2
            val u = image.planes[1]
            val v = image.planes[2]
            copyPlane(v.buffer, v.rowStride, v.pixelStride, chromaWidth, chromaHeight, out, size, 2)
            copyPlane(u.buffer, u.rowStride, u.pixelStride, chromaWidth, chromaHeight, out, size + 1, 2)
        }
        return out
    }

    internal fun copyPlane(buffer: java.nio.ByteBuffer, rowStride: Int, pixelStride: Int, width: Int, height: Int,
                          out: ByteArray, offset: Int, step: Int) {
        val source = buffer.duplicate()
        var target = offset
        if (pixelStride == 1 && step == 1) {
            for (row in 0 until height) {
                source.position(row * rowStride)
                source.get(out, target, width)
                target += width
            }
            return
        }
        for (row in 0 until height) {
            val start = row * rowStride
            for (column in 0 until width) {
                out[target] = source.get(start + column * pixelStride)
                target += step
            }
        }
    }
}
