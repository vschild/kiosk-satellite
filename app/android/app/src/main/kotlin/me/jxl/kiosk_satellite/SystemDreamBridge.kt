package me.jxl.kiosk_satellite

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Dart's handle on [SystemDream]. Lives on the application context so a
 * dream that has paused the Activity can still be stopped, and so the
 * dreaming broadcasts arrive while the kiosk is covered.
 */
class SystemDreamBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val dreaming = intent.action == SystemDream.ACTION_DREAMING_STARTED
            Log.i(TAG, if (dreaming) "dream started" else "dream stopped")
            if (!dreaming) SystemDream.holding = false
            main.post { channel.invokeMethod("dreaming", dreaming) }
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(SystemDream.readStatus(context))
                "start" -> {
                    val started = SystemDream.start(context)
                    result.success(started)
                    // Reflection can dream without pausing us. Tell Dart
                    // immediately when the service admits it is dreaming.
                    if (started["method"] == "reflection" &&
                        SystemDream.isDreaming(context) == true
                    ) {
                        main.post { channel.invokeMethod("dreaming", true) }
                    }
                }
                "stop" -> result.success(SystemDream.stop(context))
                "openSettings" -> result.success(SystemDream.openSettings(context))
                else -> result.notImplemented()
            }
        }
        val filter = IntentFilter().apply {
            addAction(SystemDream.ACTION_DREAMING_STARTED)
            addAction(SystemDream.ACTION_DREAMING_STOPPED)
        }
        ContextCompat.registerReceiver(
            context,
            receiver,
            filter,
            ContextCompat.RECEIVER_EXPORTED,
        )
    }

    companion object {
        private const val TAG = "SystemDreamBridge"
        const val CHANNEL = "kiosk_satellite/system_dream"
    }
}
