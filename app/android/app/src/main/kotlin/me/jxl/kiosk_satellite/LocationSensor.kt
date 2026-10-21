package me.jxl.kiosk_satellite

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The GPS receiver as a stream of fixes, so a kiosk that travels (a tablet
 * in an RV, issue #363) can tell Home Assistant where it is.
 *
 * `support` says whether the device has a receiver at all and why not
 * when it has none: kiosk-class tablets mostly ship without one, and the
 * settings switch renders disabled with the reason there. `last` is the
 * receiver's last known fix, so the entities have a position the moment
 * the stream starts rather than after the first cold fix. The stream
 * itself asks the GPS provider (never the network one: the point is the
 * receiver, and a Wi-Fi guess in a moving vehicle is worse than nothing)
 * for a fix every `intervalMs`, and forwards each one as a map.
 *
 * `current` is one fix on demand for the Celestial screensaver, which
 * needs a position whether or not the stream runs: the last known fix
 * when there is one, otherwise a single request that gives up after
 * `timeoutMs`. It answers with an `error` of `absent` or `denied` instead
 * of a fix when it cannot ask.
 *
 * `grants` says which of the two location grants the app holds. Android
 * 12 and later let a person allow approximate location only, which the
 * permission rows explain, since the receiver cannot be read with it.
 *
 * All of them need the fine location permission: without it the stream fails at
 * once with `denied` and the Dart side says so under the switch. A
 * receiver switched off in the device settings takes the request and
 * delivers nothing until it is on; the Dart side reads that state from the
 * permission rows.
 */
class LocationSensor(private val context: Context, messenger: BinaryMessenger) {
    private val locationManager =
        context.getSystemService(Context.LOCATION_SERVICE) as LocationManager

    private val methods = MethodChannel(messenger, "kiosk_satellite/location")
    private val events = EventChannel(messenger, "kiosk_satellite/location_stream")

    private var listener: LocationListener? = null

    private fun hasReceiver(): Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_LOCATION_GPS) ||
            locationManager.allProviders.contains(LocationManager.GPS_PROVIDER)

    private fun support(): Map<String, Any?> =
        if (hasReceiver()) {
            mapOf("supported" to true)
        } else {
            mapOf(
                "supported" to false,
                "hint" to "Not available on this device: it has no GPS receiver.",
            )
        }

    private fun granted(): Boolean = holds(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun holds(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun encode(l: Location): Map<String, Any?> = mapOf(
        "latitude" to l.latitude,
        "longitude" to l.longitude,
        "time" to l.time,
        "accuracy" to if (l.hasAccuracy()) l.accuracy.toDouble() else null,
        "altitude" to if (l.hasAltitude()) l.altitude else null,
        "speed" to if (l.hasSpeed()) l.speed.toDouble() else null,
        "provider" to l.provider,
    )

    /** The receiver's last fix, null without one or without the grant. */
    private fun last(): Map<String, Any?>? = try {
        if (!granted() || !hasReceiver()) null
        else locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)?.let(::encode)
    } catch (_: Exception) {
        null
    }

    init {
        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "support" -> result.success(support())
                "last" -> result.success(last())
                "grants" -> result.success(
                    mapOf(
                        "precise" to granted(),
                        "approximate" to holds(Manifest.permission.ACCESS_COARSE_LOCATION),
                    ),
                )
                "current" -> current(
                    ((call.argument<Number>("timeoutMs"))?.toLong() ?: 30_000L),
                    result,
                )
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                if (!hasReceiver()) {
                    sink.error("absent", "no GPS receiver", null)
                    return
                }
                if (!granted()) {
                    sink.error("denied", "location permission not granted", null)
                    return
                }
                detach()
                val interval = ((args as? Map<*, *>)?.get("intervalMs") as? Number)
                    ?.toLong()?.coerceAtLeast(1000L) ?: 60_000L
                val l = object : LocationListener {
                    override fun onLocationChanged(location: Location) {
                        sink.success(encode(location))
                    }

                    // The three below are abstract on Android 9 and older.
                    @Deprecated("Deprecated in Java")
                    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                    override fun onProviderEnabled(provider: String) {}
                    override fun onProviderDisabled(provider: String) {}
                }
                try {
                    locationManager.requestLocationUpdates(
                        LocationManager.GPS_PROVIDER, interval, 0f, l, Looper.getMainLooper(),
                    )
                    listener = l
                } catch (e: SecurityException) {
                    sink.error("denied", e.message ?: "location permission not granted", null)
                } catch (e: Exception) {
                    sink.error("failed", e.message ?: e.javaClass.simpleName, null)
                }
            }

            override fun onCancel(args: Any?) = detach()
        })
    }

    private fun current(timeoutMs: Long, result: MethodChannel.Result) {
        if (!hasReceiver()) return result.success(mapOf("error" to "absent"))
        if (!granted()) return result.success(mapOf("error" to "denied"))
        last()?.let { return result.success(it) }
        val handler = Handler(Looper.getMainLooper())
        var done = false
        lateinit var single: LocationListener
        val timeout = Runnable {
            if (done) return@Runnable
            done = true
            locationManager.removeUpdates(single)
            result.success(null)
        }
        single = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (done) return
                done = true
                handler.removeCallbacks(timeout)
                locationManager.removeUpdates(this)
                result.success(encode(location))
            }

            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
        }
        try {
            locationManager.requestLocationUpdates(
                LocationManager.GPS_PROVIDER, 1000L, 0f, single, Looper.getMainLooper(),
            )
            handler.postDelayed(timeout, timeoutMs)
        } catch (e: SecurityException) {
            done = true
            result.success(mapOf("error" to "denied"))
        } catch (e: Exception) {
            done = true
            result.success(null)
        }
    }

    private fun detach() {
        listener?.let { locationManager.removeUpdates(it) }
        listener = null
    }
}
