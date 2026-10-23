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
 * System updates of an Echo Dot on the Kiosk Satellite Edition ROM
 * ([Headless.systemUpdate]).
 *
 * The ROM's BiscuitService checks the image's GitHub releases, and on
 * request downloads the newest, checks its signature and installs it
 * through TWRP, rebooting twice. This bridge hands its status (a JSON
 * object) and the check and install requests between Dart and that
 * binder, and tells Dart when BiscuitService broadcasts a change. The
 * interface ships with the ROM, so it is called by its transaction codes,
 * like the volume buttons (BiscuitVolumeButtons.kt).
 */
class BiscuitSystemUpdate(context: Context, messenger: BinaryMessenger) {
    companion object {
        private const val TAG = "BiscuitSystemUpdate"
        private const val CHANNEL = "kiosk_satellite/system_update"
        private const val PACKAGE = "com.amazon.biscuit.service"
        private const val DESCRIPTOR = "com.amazon.biscuit.service.IBiscuitService"
        private const val TRANSACTION_STATUS = 8
        private const val TRANSACTION_CHECK = 9
        private const val TRANSACTION_INSTALL = 10
        private const val CHANGED = "com.amazon.biscuit.service.SYSTEM_UPDATE_CHANGED"
        private const val BIND_WAIT_MS = 3000L
    }

    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val thread = HandlerThread("biscuit-update").apply { start() }
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
        val supported = Headless.active(this.context) && Headless.systemUpdate
        if (supported) {
            this.context.registerReceiver(
                object : BroadcastReceiver() {
                    override fun onReceive(context: Context, intent: Intent) {
                        main.post { channel.invokeMethod("changed", null) }
                    }
                },
                IntentFilter(CHANGED),
            )
        }
        channel.setMethodCallHandler { call, result ->
            if (!supported) {
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
                    val reply = transact(code)
                    main.post { result.success(reply) }
                } catch (e: Exception) {
                    Log.w(TAG, "${call.method} failed: $e")
                    main.post { result.error("system_update", e.message ?: "$e", null) }
                }
            }
        }
    }

    /** The status JSON for [TRANSACTION_STATUS], true or false for the others. */
    private fun transact(code: Int): Any {
        val service = service() ?: throw IllegalStateException("BiscuitService is not reachable")
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(DESCRIPTOR)
            service.transact(code, data, reply, 0)
            reply.readException()
            return if (code == TRANSACTION_STATUS) reply.readString() ?: "" else reply.readInt() != 0
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    // Binds on first use and again after BiscuitService restarted.
    private fun service(): IBinder? {
        val latch = synchronized(lock) {
            binder?.let { return it }
            connected
        }
        if (!bound) {
            bound = try {
                context.bindService(
                    Intent(DESCRIPTOR).setPackage(PACKAGE),
                    connection,
                    Context.BIND_AUTO_CREATE,
                )
            } catch (e: Exception) {
                Log.w(TAG, "could not bind BiscuitService: $e")
                false
            }
        }
        latch.await(BIND_WAIT_MS, TimeUnit.MILLISECONDS)
        return synchronized(lock) { binder }
    }
}
