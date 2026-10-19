package me.jxl.kiosk_satellite

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Button presses on a device without a screen, from [HeadlessKeyService] to
 * the gestures in Dart.
 *
 * Dart configures which keys it wants and which presses of each it listens
 * for: "single", "double" (two presses within [DOUBLE_MS]) and "long" (held
 * for [LONG_MS]). Those keys are taken from the system and every other key
 * is left alone. A completed press goes to Dart as `press`. A single press
 * of a volume key that Dart did not ask for still moves the media volume,
 * so mapping a double press of Volume up does not cost the button its
 * everyday job.
 *
 * Detection waits for a second press only when a double press is wanted,
 * so a key with single presses alone fires on release.
 *
 * The microphone button is the exception on some speaker ROMs: the
 * LineageOS build for the Echo Dot takes KEYCODE_MUTE in the framework,
 * mutes the microphone at the hardware and broadcasts the change, so the
 * key never reaches any app. The system microphone mute is followed
 * instead, both ways: a change reaches Dart as `micMute`, and Dart sets it
 * when Voice Satellite is muted from anywhere else.
 */
object HardwareKeys {
    private const val TAG = "HardwareKeys"
    private const val CHANNEL = "kiosk_satellite/hardware_keys"
    private const val LONG_MS = 700L
    private const val DOUBLE_MS = 350L

    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var audio: AudioManager? = null

    /** Key code to the presses Dart listens for. Main thread only. */
    private var wanted: Map<Int, Set<String>> = emptyMap()

    private class KeyState {
        var longFired = false
        var longTask: Runnable? = null
        var singleTask: Runnable? = null
    }

    private val states = HashMap<Int, KeyState>()

    fun attach(context: Context, messenger: BinaryMessenger) {
        audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        // Listed in Accessibility settings only where it has a job.
        if (Headless.active(context)) {
            if (Headless.actionBroadcast) {
                // An earlier version may have enabled the service: both
                // would hand over every press, so it goes.
                setService(context, false)
                watchActionButton(context)
            } else {
                setService(context, true)
            }
            watchMicMute(context)
            BiscuitVolumeButtons.attach(context) { direction ->
                main.post { channel?.invokeMethod("volumeKey", mapOf("direction" to direction)) }
            }
        }
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "configure" -> {
                        configure(call.argument<Map<String, List<String>>>("keys"))
                        result.success(null)
                    }
                    "status" -> result.success(
                        mapOf(
                            "listening" to (HeadlessKeyService.running || broadcastButtons),
                            "switchedOn" to (broadcastButtons || switchedOn(context)),
                        ),
                    )
                    // Dart's answer to whether the volume buttons steer a
                    // player or a group right now.
                    "claimVolumeButtons" -> {
                        BiscuitVolumeButtons.claim(call.arguments as? Boolean ?: false)
                        result.success(null)
                    }
                    // Set even when the mute reads the same: the Dot's
                    // audio HAL reports it unreliably.
                    "setMicMuted" -> {
                        val muted = call.argument<Boolean>("muted") == true
                        try {
                            audio?.isMicrophoneMute = muted
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /**
     * Whether the button service is switched on in Android's settings,
     * running or not. Android 7 only starts a service whose component was
     * enabled at runtime after a reboot or the next app update, so it can
     * be switched on and still not run.
     */
    private fun switchedOn(context: Context): Boolean {
        val resolver = context.contentResolver
        val on = try {
            Settings.Secure.getInt(resolver, Settings.Secure.ACCESSIBILITY_ENABLED) == 1
        } catch (e: Settings.SettingNotFoundException) {
            false
        }
        if (!on) return false
        val ours = ComponentName(context, HeadlessKeyService::class.java)
        val list = Settings.Secure.getString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
        return list.split(':').any { ComponentName.unflattenFromString(it.trim()) == ours }
    }

    private fun setService(context: Context, enabled: Boolean) {
        try {
            context.packageManager.setComponentEnabledSetting(
                ComponentName(context, HeadlessKeyService::class.java),
                if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
        } catch (e: Exception) {
            Log.w(TAG, "could not switch the button service: $e")
        }
    }

    /** Whether the Action button arrives as the ROM's broadcast. */
    private var broadcastButtons = false

    /**
     * The Kiosk Satellite Edition ROM's Action button: every press and
     * release, also while the device sleeps, fed to the same press logic as
     * the accessibility service's keys.
     */
    private fun watchActionButton(context: Context) {
        context.registerReceiver(
            object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    val at = intent.getLongExtra("eventTime", SystemClock.uptimeMillis())
                    val action = if (intent.getBooleanExtra("down", false)) {
                        KeyEvent.ACTION_DOWN
                    } else {
                        KeyEvent.ACTION_UP
                    }
                    onKey(KeyEvent(at, at, action, KeyEvent.KEYCODE_HELP, 0))
                }
            },
            IntentFilter(BISCUIT_ACTION_BUTTON),
        )
        broadcastButtons = true
    }

    private fun watchMicMute(context: Context) {
        val filter = IntentFilter(BISCUIT_MIC_MUTE_CHANGED)
        if (Build.VERSION.SDK_INT >= 28) {
            filter.addAction(AudioManager.ACTION_MICROPHONE_MUTE_CHANGED)
        }
        context.registerReceiver(
            object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    // The ROM's broadcast is sticky: registering replays
                    // the last change, and at start the setting is what
                    // Dart pushes, not what happened before.
                    if (isInitialStickyBroadcast) return
                    val muted = if (intent.hasExtra(BISCUIT_EXTRA_MUTED)) {
                        intent.getBooleanExtra(BISCUIT_EXTRA_MUTED, false)
                    } else {
                        audio?.isMicrophoneMute ?: return
                    }
                    channel?.invokeMethod("micMute", mapOf("muted" to muted))
                }
            },
            filter,
        )
    }

    /** What the Echo Dot's LineageOS framework broadcasts when its
     *  microphone button (or any app) changes the microphone mute. */
    private const val BISCUIT_ACTION_BUTTON = "com.amazon.biscuit.service.ACTION_BUTTON"
    private const val BISCUIT_MIC_MUTE_CHANGED =
        "com.amazon.biscuit.service.MICROPHONE_MUTE_CHANGED"
    private const val BISCUIT_EXTRA_MUTED =
        "com.amazon.biscuit.service.EXTRA_MICROPHONE_MUTED"

    private fun configure(keys: Map<String, List<String>>?) {
        val next = HashMap<Int, Set<String>>()
        keys?.forEach { (code, presses) ->
            code.toIntOrNull()?.let { next[it] = presses.toSet() }
        }
        for ((code, state) in states) {
            if (next[code] == wanted[code]) continue
            state.longTask?.let(main::removeCallbacks)
            state.singleTask?.let(main::removeCallbacks)
        }
        states.keys.retainAll(next.keys)
        wanted = next
    }

    /** From the service, on the main thread. True takes the key. */
    fun onKey(event: KeyEvent): Boolean {
        val code = event.keyCode
        val presses = wanted[code] ?: return false
        val state = states.getOrPut(code) { KeyState() }
        when (event.action) {
            KeyEvent.ACTION_DOWN -> {
                if (event.repeatCount != 0) return true
                state.longFired = false
                if ("long" in presses) {
                    val task = Runnable {
                        state.longTask = null
                        state.longFired = true
                        // A press then a hold is a hold.
                        state.singleTask?.let(main::removeCallbacks)
                        state.singleTask = null
                        emit(code, "long")
                    }
                    state.longTask = task
                    main.postDelayed(task, LONG_MS)
                }
            }
            KeyEvent.ACTION_UP -> {
                state.longTask?.let(main::removeCallbacks)
                state.longTask = null
                if (state.longFired) {
                    state.longFired = false
                    return true
                }
                if ("double" !in presses) {
                    single(code, presses)
                    return true
                }
                val pending = state.singleTask
                if (pending != null) {
                    main.removeCallbacks(pending)
                    state.singleTask = null
                    emit(code, "double")
                } else {
                    val task = Runnable {
                        state.singleTask = null
                        single(code, presses)
                    }
                    state.singleTask = task
                    main.postDelayed(task, DOUBLE_MS)
                }
            }
        }
        return true
    }

    private fun single(code: Int, presses: Set<String>) {
        if ("single" !in presses &&
            (code == KeyEvent.KEYCODE_VOLUME_UP || code == KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            try {
                audio?.adjustStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    if (code == KeyEvent.KEYCODE_VOLUME_UP) AudioManager.ADJUST_RAISE
                    else AudioManager.ADJUST_LOWER,
                    0,
                )
            } catch (e: Exception) {
                Log.w(TAG, "volume step failed: $e")
            }
            return
        }
        emit(code, "single")
    }

    private fun emit(code: Int, press: String) {
        channel?.invokeMethod("press", mapOf("keyCode" to code, "press" to press))
    }
}
