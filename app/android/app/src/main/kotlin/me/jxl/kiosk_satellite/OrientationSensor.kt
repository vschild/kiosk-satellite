package me.jxl.kiosk_satellite

import android.content.Context
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.display.DisplayManager
import android.view.Display
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Where the screen is pointing, for the Celestial screensaver's Point at
 * the sky mode: hold the tablet up and the sky on screen turns with it.
 *
 * The rotation vector sensor fuses the accelerometer, magnetometer and
 * gyroscope. Each event is the screen's own axes in the observer's frame
 * (x east, y north, z up), remapped for the display's rotation so screen
 * right and up stay right and up in landscape: nine floats, right, up and
 * the direction out of the back of the device, which is where the camera
 * of a phone would look. The magnetometer's north is turned to true north
 * with the declination for the latitude and longitude the stream starts
 * with.
 *
 * Two more values follow the nine: the accuracy Android gives the
 * rotation vector and the magnetometer's calibration status (-1 without
 * one), both SensorManager's 0 (unreliable) to 3 (high). A compass that
 * has not been turned around for a while can be far off, which the
 * screensaver answers with a hint to move the device in a figure eight.
 *
 * `support` says whether the device has the sensor. Kiosk-class tablets
 * often lack a magnetometer, and without one there is no north to point
 * at. No permission is needed.
 */
class OrientationSensor(private val context: Context, messenger: BinaryMessenger) {
    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager

    private val methods = MethodChannel(messenger, "kiosk_satellite/orientation")
    private val events = EventChannel(messenger, "kiosk_satellite/orientation_stream")

    private var listener: SensorEventListener? = null
    private var compass: SensorEventListener? = null

    private fun sensor(): Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)

    init {
        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "support" -> result.success(mapOf("supported" to (sensor() != null)))
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                val s = sensor()
                if (s == null) {
                    sink.error("absent", "no rotation vector sensor", null)
                    return
                }
                detach()
                val params = args as? Map<*, *>
                val lat = (params?.get("latitude") as? Number)?.toFloat() ?: 0f
                val lon = (params?.get("longitude") as? Number)?.toFloat() ?: 0f
                val declination = Math.toRadians(
                    GeomagneticField(lat, lon, 0f, System.currentTimeMillis())
                        .declination.toDouble(),
                )
                val cosD = Math.cos(declination)
                val sinD = Math.sin(declination)
                val raw = FloatArray(9)
                val remapped = FloatArray(9)
                // Only the magnetometer's calibration is wanted, which
                // Android reports through onAccuracyChanged.
                var magnetic = -1
                sensorManager.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)?.let { m ->
                    val c = object : SensorEventListener {
                        override fun onSensorChanged(event: SensorEvent) {
                            magnetic = event.accuracy
                        }

                        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
                            magnetic = accuracy
                        }
                    }
                    sensorManager.registerListener(c, m, SensorManager.SENSOR_DELAY_UI)
                    compass = c
                }
                val l = object : SensorEventListener {
                    override fun onSensorChanged(event: SensorEvent) {
                        SensorManager.getRotationMatrixFromVector(raw, event.values)
                        val (x, y) = when (rotation()) {
                            Surface.ROTATION_90 -> SensorManager.AXIS_Y to SensorManager.AXIS_MINUS_X
                            Surface.ROTATION_180 -> SensorManager.AXIS_MINUS_X to SensorManager.AXIS_MINUS_Y
                            Surface.ROTATION_270 -> SensorManager.AXIS_MINUS_Y to SensorManager.AXIS_X
                            else -> SensorManager.AXIS_X to SensorManager.AXIS_Y
                        }
                        SensorManager.remapCoordinateSystem(raw, x, y, remapped)
                        // Columns are the screen's axes in east, north, up.
                        // Turn magnetic north to true north about up.
                        val out = DoubleArray(11)
                        for (col in 0 until 3) {
                            val e = remapped[col].toDouble()
                            val n = remapped[3 + col].toDouble()
                            val u = remapped[6 + col].toDouble()
                            val sign = if (col == 2) -1.0 else 1.0
                            out[col * 3] = sign * (e * cosD + n * sinD)
                            out[col * 3 + 1] = sign * (-e * sinD + n * cosD)
                            out[col * 3 + 2] = sign * u
                        }
                        out[9] = event.accuracy.toDouble()
                        out[10] = magnetic.toDouble()
                        sink.success(out)
                    }

                    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
                }
                sensorManager.registerListener(l, s, SensorManager.SENSOR_DELAY_GAME)
                listener = l
            }

            override fun onCancel(args: Any?) = detach()
        })
    }

    private fun rotation(): Int {
        val displays = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        return displays.getDisplay(Display.DEFAULT_DISPLAY)?.rotation ?: Surface.ROTATION_0
    }

    private fun detach() {
        listener?.let { sensorManager.unregisterListener(it) }
        listener = null
        compass?.let { sensorManager.unregisterListener(it) }
        compass = null
    }
}
