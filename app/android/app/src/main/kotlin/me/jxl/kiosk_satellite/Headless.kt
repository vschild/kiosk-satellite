package me.jxl.kiosk_satellite

import android.content.Context
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.os.PowerManager
import android.util.Log
import android.view.Display
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterJNI

/**
 * Whether this device has a screen at all.
 *
 * Speaker hardware running Android (an Echo Dot on LineageOS) has no panel,
 * and the platform reports a stub display in its place: 1x1 pixels, state
 * OFF. The kiosk runs headless there. No Activity is ever started, the
 * engine renders nothing and needs no GPU context (the Dot's driver cannot
 * even choose an EGL configuration, which aborts a normal engine start),
 * and the keep-alive service carries the process from boot on. Voice,
 * audio and the remote admin are what remain.
 *
 * Decided once per process from the default display, before the engine
 * exists, so every native path and the Dart side read the same answer.
 */
object Headless {
    private const val TAG = "Headless"

    /** No real panel is this small; the stub displays report 1x1. */
    private const val MAX_STUB_PX = 64

    @Volatile private var cached: Boolean? = null

    fun active(context: Context): Boolean =
        cached ?: detect(context).also {
            cached = it
            if (it) Log.i(TAG, "no screen on this device; running headless")
        }

    private fun detect(context: Context): Boolean = try {
        val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val display = dm.getDisplay(Display.DEFAULT_DISPLAY)
        if (display == null) {
            true
        } else {
            val size = Point()
            @Suppress("DEPRECATION")
            display.getRealSize(size)
            maxOf(size.x, size.y) < MAX_STUB_PX
        }
    } catch (e: Exception) {
        Log.w(TAG, "display probe failed: $e")
        false
    }

    private var awake: PowerManager.WakeLock? = null

    /**
     * Keep Android in its awake state. A device without a screen still
     * sleeps on the display timeout like any other, and asleep, the window
     * manager drops every button but power before anything can hear it, so
     * the speaker's buttons would only work for a minute after each boot.
     * A screen wake lock holds the stub display "on"; there is no panel to
     * light, and on the Dot it costs SurfaceFlinger a few percent of one
     * core. Taken again whenever the device is put to sleep anyway (a
     * power key, `input keyevent SLEEP`): a held lock does not wake it.
     */
    @Suppress("DEPRECATION", "WakelockTimeout")
    fun stayAwake(context: Context) {
        if (!active(context)) return
        try {
            awake?.let { if (it.isHeld) it.release() }
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            awake = pm.newWakeLock(
                PowerManager.SCREEN_DIM_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "ks:headless",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "could not keep the device awake: $e")
        }
    }

    fun releaseAwake() {
        awake?.let { if (it.isHeld) it.release() }
        awake = null
    }

    /**
     * The Kiosk Satellite Edition ROM for the Echo Dot broadcasts every press
     * and release of the Action button, also while the device sleeps
     * (`ro.biscuit.action_broadcast`). The button then needs no
     * accessibility service.
     */
    val actionBroadcast: Boolean by lazy { property("ro.biscuit.action_broadcast") == "1" }

    /**
     * The same ROM lets an app claim the volume buttons from BiscuitService
     * (`ro.biscuit.volume_claim`): presses then arrive as a broadcast instead
     * of changing the volume, so they can steer a player elsewhere.
     */
    val volumeClaim: Boolean by lazy { property("ro.biscuit.volume_claim") == "1" }

    /** A system property, empty when it is not set. */
    fun property(name: String): String = runCatching {
        Class.forName("android.os.SystemProperties")
            .getMethod("get", String::class.java, String::class.java)
            .invoke(null, name, "") as String
    }.getOrDefault("")

    /** The engine's shell arguments. Impeller has no software backend, so
     *  it stays off for the Skia software renderer [useSoftwareRenderer]
     *  turns on. */
    val engineArgs = arrayOf("--enable-impeller=false")

    /**
     * Make the engine render in software. Below API 29 the engine always
     * picks Skia on OpenGL ES, and it aborts the process when no EGL
     * configuration exists, which is the case on the Dot. The software
     * switch is the way out, but the embedding drops it from release
     * builds as a debugging flag before the shell sees it, so it is added
     * at the one call below that filter: the JNI init that hands the
     * final arguments to the shell. Must run before anything reads the
     * injector, which means before the engine is built.
     */
    fun useSoftwareRenderer() {
        FlutterInjector.setInstance(
            FlutterInjector.Builder()
                .setFlutterJNIFactory(object : FlutterJNI.Factory() {
                    override fun provideFlutterJNI(): FlutterJNI = SoftwareJni()
                })
                .build(),
        )
    }

    private class SoftwareJni : FlutterJNI() {
        override fun init(
            context: Context,
            args: Array<String>,
            bundlePath: String?,
            appStoragePath: String,
            engineCachesPath: String,
            initTimeMillis: Long,
            apiLevel: Int,
        ) = super.init(
            context,
            args + "--enable-software-rendering",
            bundlePath,
            appStoragePath,
            engineCachesPath,
            initTimeMillis,
            apiLevel,
        )
    }
}
