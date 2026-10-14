package me.jxl.kiosk_satellite

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import java.lang.reflect.InvocationTargetException

/**
 * Starts the screensaver the user picked in Android's Display settings,
 * the same door Fully Kiosk uses.
 *
 * Through Android 13, SystemUI's Somnambulator activity calls
 * Sandman.startDreamByUserRequest inside the system process, which holds
 * WRITE_DREAM_STATE. A normal app does not, so launching that activity is
 * the path that actually works. Android 14 gutted Somnambulator: it still
 * exists, but onStart only finishes. OEM skins that never took that change
 * still dream. Everyone else needs a privileged caller, which reflection
 * on DreamManager / IDreamManager reaches only when the device grants it.
 *
 * The last resort starts the chosen screensaver's own activity, when the
 * component the system stored is an activity rather than a DreamService.
 */
internal object SystemDream {
    private const val TAG = "SystemDream"

    const val SOMNAMBULATOR_PACKAGE = "com.android.systemui"
    const val SOMNAMBULATOR_CLASS = "com.android.systemui.Somnambulator"

    const val ACTION_DREAMING_STARTED = "android.intent.action.DREAMING_STARTED"
    const val ACTION_DREAMING_STOPPED = "android.intent.action.DREAMING_STOPPED"

    /** Set while a start is in flight or a dream is up, so bringToFront can wake it. */
    @Volatile
    var holding = false

    /**
     * Android 14 (API 34) is where AOSP stopped Somnambulator from dreaming.
     * Older releases try that activity first; newer ones try the privileged
     * call and the configured component before a launcher that is usually a no-op.
     */
    fun attemptOrder(sdk: Int): List<String> =
        if (sdk >= 34) {
            listOf("reflection", "component", "somnambulator")
        } else {
            listOf("somnambulator", "reflection", "component")
        }

    fun outcome(method: String?): Map<String, Any?> =
        if (method == null) {
            mapOf("ok" to false, "code" to "unavailable")
        } else {
            mapOf("ok" to true, "method" to method)
        }

    /** Null when the user has not explicitly switched the screensaver off. */
    fun explicitlyDisabled(raw: String?): Boolean = raw == "0"

    fun somnambulatorIntent(): Intent =
        Intent(Intent.ACTION_MAIN).apply {
            component = ComponentName(SOMNAMBULATOR_PACKAGE, SOMNAMBULATOR_CLASS)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS,
            )
        }

    fun settingsIntent(): Intent =
        Intent(Settings.ACTION_DREAM_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

    fun displaySettingsIntent(): Intent =
        Intent(Settings.ACTION_DISPLAY_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

    fun readStatus(context: Context): Map<String, Any?> {
        val resolver = context.contentResolver
        val raw = Settings.Secure.getString(resolver, Settings.Secure.SCREENSAVER_ENABLED)
        val component = Settings.Secure.getString(
            resolver,
            Settings.Secure.SCREENSAVER_COMPONENTS,
        )
        val first = component?.substringBefore(',')?.trim().orEmpty()
        return mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "enabled" to !explicitlyDisabled(raw),
            "component" to first.ifEmpty { null },
            "label" to componentLabel(context, first),
            "somnambulator" to somnambulatorResolves(context),
        )
    }

    /**
     * Tries each attempt in [attemptOrder] and stops at the first that
     * accepts the launch. A Somnambulator start only means the activity
     * opened; the caller still has to see a dream or a pause before
     * treating it as success.
     */
    fun start(context: Context): Map<String, Any?> {
        val status = readStatus(context)
        if (status["enabled"] != true) {
            holding = false
            return mapOf("ok" to false, "code" to "disabled")
        }
        val component = status["component"] as? String
        var method: String? = null
        for (attempt in attemptOrder(Build.VERSION.SDK_INT)) {
            val ok = when (attempt) {
                "somnambulator" -> launch(context, somnambulatorIntent(), "Somnambulator")
                "reflection" -> startByReflection(context)
                "component" -> launchComponent(context, component)
                else -> false
            }
            if (ok) {
                method = attempt
                break
            }
        }
        holding = method != null
        if (method == "reflection" && isDreaming(context) == true) {
            // The privileged call started it without an activity pause.
            // Nothing else tells Dart, so say so from here.
            Log.i(TAG, "reflection reports the dream is up")
        }
        return outcome(method)
    }

    fun stop(context: Context): Boolean {
        holding = false
        return awaken(context)
    }

    fun awaken(context: Context): Boolean {
        holding = false
        var ok = false
        ok = invokeDreamManager(context, "stopDream") || ok
        ok = invokeDreamManager(context, "awaken") || ok
        ok = invokeIDreamManager("awaken") || ok
        return ok
    }

    fun openSettings(context: Context): Boolean {
        if (launch(context, settingsIntent(), "dream settings")) return true
        return launch(context, displaySettingsIntent(), "display settings")
    }

    fun isDreaming(context: Context): Boolean? = try {
        val manager = context.getSystemService("dream") ?: return null
        val method = manager.javaClass.methods.firstOrNull {
            it.name == "isDreaming" && it.parameterTypes.isEmpty()
        } ?: return null
        method.invoke(manager) as? Boolean
    } catch (e: Throwable) {
        Log.i(TAG, "isDreaming unavailable: ${rootMessage(e)}")
        null
    }

    private fun somnambulatorResolves(context: Context): Boolean = try {
        context.packageManager.getActivityInfo(
            ComponentName(SOMNAMBULATOR_PACKAGE, SOMNAMBULATOR_CLASS),
            0,
        )
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    private fun componentLabel(context: Context, flattened: String): String? {
        if (flattened.isEmpty()) return null
        val name = ComponentName.unflattenFromString(flattened) ?: return null
        val pm = context.packageManager
        return try {
            pm.getServiceInfo(name, 0).loadLabel(pm).toString()
        } catch (_: Exception) {
            try {
                pm.getActivityInfo(name, 0).loadLabel(pm).toString()
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun launchComponent(context: Context, flattened: String?): Boolean {
        val raw = flattened?.substringBefore(',')?.trim().orEmpty()
        if (raw.isEmpty()) return false
        val name = ComponentName.unflattenFromString(raw) ?: return false
        if (name.packageName == SOMNAMBULATOR_PACKAGE &&
            name.className == SOMNAMBULATOR_CLASS
        ) {
            return false
        }
        return launch(
            context,
            Intent(Intent.ACTION_MAIN).setComponent(name).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS,
            ),
            "configured screensaver",
        )
    }

    private fun launch(context: Context, intent: Intent, what: String): Boolean = try {
        context.startActivity(intent)
        Log.i(TAG, "launched $what")
        true
    } catch (e: Exception) {
        Log.i(TAG, "could not launch $what: ${e.message}")
        false
    }

    private fun startByReflection(context: Context): Boolean {
        if (invokeDreamManager(context, "startDream")) return true
        if (invokeSandman(context)) return true
        return invokeIDreamManager("dream")
    }

    private fun invokeDreamManager(context: Context, name: String): Boolean = try {
        val manager = context.getSystemService("dream") ?: return false
        val method = manager.javaClass.methods.firstOrNull {
            it.name == name && it.parameterTypes.isEmpty()
        } ?: return false
        method.invoke(manager)
        Log.i(TAG, "DreamManager.$name accepted")
        true
    } catch (e: Throwable) {
        Log.i(TAG, "DreamManager.$name refused: ${rootMessage(e)}")
        false
    }

    private fun invokeSandman(context: Context): Boolean = try {
        val sandman = Class.forName("android.service.dreams.Sandman")
        val method = sandman.getDeclaredMethod(
            "startDreamByUserRequest",
            Context::class.java,
        )
        method.isAccessible = true
        method.invoke(null, context)
        Log.i(TAG, "Sandman.startDreamByUserRequest accepted")
        true
    } catch (e: Throwable) {
        Log.i(TAG, "Sandman refused: ${rootMessage(e)}")
        false
    }

    private fun invokeIDreamManager(name: String): Boolean = try {
        val serviceManager = Class.forName("android.os.ServiceManager")
        val getService = serviceManager.getMethod("getService", String::class.java)
        val binder = getService.invoke(null, "dream") as? IBinder ?: return false
        val stub = Class.forName("android.service.dreams.IDreamManager\$Stub")
        val asInterface = stub.getMethod("asInterface", IBinder::class.java)
        val manager = asInterface.invoke(null, binder) ?: return false
        val method = manager.javaClass.methods.firstOrNull {
            it.name == name && it.parameterTypes.isEmpty()
        } ?: return false
        method.invoke(manager)
        Log.i(TAG, "IDreamManager.$name accepted")
        true
    } catch (e: Throwable) {
        Log.i(TAG, "IDreamManager.$name refused: ${rootMessage(e)}")
        false
    }

    private fun rootMessage(error: Throwable): String {
        val cause = if (error is InvocationTargetException) {
            error.targetException ?: error
        } else {
            error
        }
        return cause.message ?: cause.javaClass.simpleName
    }
}
