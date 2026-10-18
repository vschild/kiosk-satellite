package me.jxl.kiosk_satellite

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import me.jxl.kiosk_satellite.leds.LedDevice
import me.jxl.kiosk_satellite.leds.LedDevices

/**
 * The device's status lights for LedManager in Dart (channel
 * `kiosk_satellite/leds`): `describe` names them, or answers null where
 * there are none, `frame` paints one frame and `clear` turns them off, both repainting
 * even an unchanged frame with `force`.
 */
class LedBridge(context: Context, messenger: BinaryMessenger) {
    private val device: LedDevice? = LedDevices.detect(context)

    init {
        MethodChannel(messenger, "kiosk_satellite/leds").setMethodCallHandler { call, result ->
            val leds = device
            when (call.method) {
                "describe" -> result.success(
                    leds?.let {
                        mapOf(
                            "id" to it.id,
                            "name" to it.name,
                            "pixels" to it.pixels,
                            "layout" to it.layout,
                        )
                    },
                )
                "frame" -> {
                    val colors = call.argument<List<Number>>("colors")
                    if (call.argument<Boolean>("force") == true) leds?.invalidate()
                    if (leds != null && colors != null) {
                        leds.frame(IntArray(colors.size) { colors[it].toInt() })
                    }
                    result.success(null)
                }
                "clear" -> {
                    if (call.argument<Boolean>("force") == true) leds?.invalidate()
                    leds?.clear()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
