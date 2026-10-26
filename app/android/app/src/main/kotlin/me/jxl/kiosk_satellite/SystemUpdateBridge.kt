package me.jxl.kiosk_satellite

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The updater service of a Kiosk Satellite Edition ROM. The Echo Dot image
 * runs BiscuitService and the Echo Show images run EchoService. Both keep
 * one contract (status JSON, transaction codes, broadcast) and differ only
 * in their names. A ROM says which it has with a property, read on any
 * device, with a screen or without.
 *
 * BiscuitService always wins: Dot releases 2026.10.7 to 2026.10.9 shipped
 * EchoService by mistake and set both properties. EchoService installs the
 * Show way, into the active slot only, which would leave such a Dot's two
 * slots on different releases. [detect] checks the entries in order.
 */
enum class SystemUpdater(
    val property: String,
    val packageName: String,
    val descriptor: String,
    val changedAction: String,
) {
    BISCUIT(
        "ro.biscuit.ota",
        "com.amazon.biscuit.service",
        "com.amazon.biscuit.service.IBiscuitService",
        "com.amazon.biscuit.service.SYSTEM_UPDATE_CHANGED",
    ),
    ECHO(
        "ro.echo.ota",
        "me.jxl.echo.service",
        "me.jxl.echo.service.IEchoService",
        "me.jxl.echo.service.SYSTEM_UPDATE_CHANGED",
    ),
    ;

    /** The name Dart picks its update source by. */
    val id: String get() = name.lowercase()

    companion object {
        fun detect(property: (String) -> String): SystemUpdater? =
            entries.firstOrNull { property(it.property) == "1" }

        val current: SystemUpdater? by lazy { detect(Headless::property) }
    }
}

/**
 * System updates of a Kiosk Satellite Edition ROM ([SystemUpdater]).
 *
 * The ROM's updater checks the image's GitHub releases, and on request
 * downloads the newest, checks its signature and installs it through TWRP.
 * This bridge hands its status (a JSON object) and the check and install
 * requests between Dart and that binder, and tells Dart when the updater
 * broadcasts a change. The interface ships with the ROM, so it is called by
 * its transaction codes, like the volume buttons (BiscuitVolumeButtons.kt).
 */
class SystemUpdateBridge(
    context: Context,
    messenger: BinaryMessenger,
    private val updater: SystemUpdater? = SystemUpdater.current,
) {
    companion object {
        private const val TAG = "SystemUpdateBridge"
        private const val CHANNEL = "kiosk_satellite/system_update"
        private const val TRANSACTION_STATUS = 8
        private const val TRANSACTION_CHECK = 9
        private const val TRANSACTION_INSTALL = 10
        private const val BIND_WAIT_MS = 3000L
    }

    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val thread = HandlerThread("system-update").apply { start() }
    private val handler = Handler(thread.looper)
    private val lock = Any()
    private var binder: IBinder? = null
    private var bound = false
    private var connected = CountDownLatch(1)

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            synchronized(lock) { binder = service }
            connected.countDown()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            synchronized(lock) {
                binder = null
                connected = CountDownLatch(1)
            }
        }
    }

    private val channel = MethodChannel(messenger, CHANNEL)

    init {
        if (updater != null) {
            this.context.registerReceiver(
                object : BroadcastReceiver() {
                    override fun onReceive(context: Context, intent: Intent) {
                        main.post { channel.invokeMethod("changed", null) }
                    }
                },
                IntentFilter(updater.changedAction),
            )
        }
        channel.setMethodCallHandler { call, result ->
            if (call.method == "updater") {
                result.success(updater?.id)
                return@setMethodCallHandler
            }
            if (updater == null) {
                result.success(null)
                return@setMethodCallHandler
            }
            val code = when (call.method) {
                "status" -> TRANSACTION_STATUS
                "check" -> TRANSACTION_CHECK
                "install" -> TRANSACTION_INSTALL
                else -> {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
            }
            handler.post {
                try {
                    val reply = transact(updater, code)
                    main.post { result.success(reply) }
                } catch (e: Exception) {
                    Log.w(TAG, "${call.method} failed: $e")
                    main.post { result.error("system_update", e.message ?: "$e", null) }
                }
            }
        }
    }

    /** The status JSON for [TRANSACTION_STATUS], true or false for the others. */
    private fun transact(updater: SystemUpdater, code: Int): Any {
        val service = service(updater)
            ?: throw IllegalStateException("${updater.packageName} is not reachable")
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(updater.descriptor)
            service.transact(code, data, reply, 0)
            reply.readException()
            return if (code == TRANSACTION_STATUS) reply.readString() ?: "" else reply.readInt() != 0
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    // Binds on first use and again after the updater restarted.
    private fun service(updater: SystemUpdater): IBinder? {
        val latch = synchronized(lock) {
            binder?.let { return it }
            connected
        }
        if (!bound) {
            bound = try {
                context.bindService(
                    Intent(updater.descriptor).setPackage(updater.packageName),
                    connection,
                    Context.BIND_AUTO_CREATE,
                )
            } catch (e: Exception) {
                Log.w(TAG, "could not bind ${updater.packageName}: $e")
                false
            }
        }
        latch.await(BIND_WAIT_MS, TimeUnit.MILLISECONDS)
        return synchronized(lock) { binder }
    }
}
