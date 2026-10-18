package me.jxl.kiosk_satellite.leds

import android.content.Context

/**
 * Status lights the kiosk can paint, such as the light ring of an Echo Dot.
 *
 * The Dart side (LedManager) decides what to show and renders every frame;
 * a device only has to put a row of colors on its lights. Supporting new
 * hardware means one more implementation here and one more line in
 * [LedDevices.detect], nothing on the Dart side.
 */
interface LedDevice {
    /** Stable id, reported to Dart and the remote admin. */
    val id: String

    /** What the lights are, for people: "Echo Dot light ring". */
    val name: String

    /** How many individually colored lights. */
    val pixels: Int

    /** How they sit: "ring" (pixel 0 follows the last) or "strip". */
    val layout: String

    /** Paint one frame: [colors] holds [pixels] 0xRRGGBB values. */
    fun frame(colors: IntArray)

    /** Turn every light off. */
    fun clear()

    /** Forget what was painted last, so the next frame is sent even when
     *  it is the same: the device drew something of its own over it. */
    fun invalidate() {}

    fun release()
}

object LedDevices {
    /** The lights on this device, or null where there are none we drive. */
    fun detect(context: Context): LedDevice? =
        BiscuitLedRing.probe(context)
}
