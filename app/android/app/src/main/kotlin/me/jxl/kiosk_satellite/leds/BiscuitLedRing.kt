package me.jxl.kiosk_satellite.leds

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Parcel
import android.util.Log

/**
 * The 12-light ring of an Echo Dot (2nd generation) on its LineageOS build.
 *
 * The ring belongs to the ROM's `biscuit-ledd` daemon, which only the system
 * may talk to. The ROM's BiscuitService relays for apps through an exported
 * binder, `com.amazon.biscuit.service.IBiscuitService`, whose `setFrame`
 * takes the whole ring as 72 hex digits (RRGGBB per light). The interface
 * ships with the ROM, not as a library, so it is called by its transaction
 * codes. Calls block on the daemon, so they run on a thread of their own,
 * and only the newest frame waiting is sent: a slow ring skips frames
 * rather than falling behind.
 */
class BiscuitLedRing private constructor(private val context: Context) : LedDevice {
    companion object {
        private const val TAG = "BiscuitLedRing"
        private const val PACKAGE = "com.amazon.biscuit.service"
        private const val DESCRIPTOR = "com.amazon.biscuit.service.IBiscuitService"
        private const val TRANSACTION_SET_FRAME = 2
        private const val TRANSACTION_CLEAR = 5

        fun probe(context: Context): BiscuitLedRing? {
            val resolved = try {
                context.packageManager.resolveService(intent(), 0)
            } catch (_: Exception) {
                null
            }
            return if (resolved == null) null else BiscuitLedRing(context)
        }

        private fun intent() = Intent(DESCRIPTOR).setPackage(PACKAGE)
    }

    override val id = "biscuit_ring"
    override val name = "Echo Dot light ring"
    override val pixels = 12
    override val layout = "ring"

    private val thread = HandlerThread("biscuit-led").apply { start() }
    private val handler = Handler(thread.looper)
    private val lock = Any()
    private var binder: IBinder? = null
    private var bound = false

    /** The newest frame not yet sent: hex, or "" for clear. */
    private var pending: String? = null
    private var last: String? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            // A frame asked for before the bind landed, or the ring as it
            // was before the service restarted, which is painted again.
            synchronized(lock) {
                binder = service
                if (pending == null) pending = last
                last = null
            }
            handler.post(::drain)
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            synchronized(lock) { binder = null }
        }
    }

    private fun ensureBound() {
        if (bound) return
        bound = try {
            context.bindService(intent(), connection, Context.BIND_AUTO_CREATE)
        } catch (e: Exception) {
            Log.w(TAG, "could not bind the light ring service: $e")
            false
        }
    }

    override fun frame(colors: IntArray) {
        val hex = StringBuilder(pixels * 6)
        for (i in 0 until pixels) {
            val c = colors.getOrElse(i) { 0 }
            hex.append(String.format("%06X", c and 0xFFFFFF))
        }
        submit(hex.toString())
    }

    override fun clear() = submit("")

    override fun invalidate() {
        handler.post { last = null }
    }

    private fun submit(frame: String) {
        synchronized(lock) { pending = frame }
        handler.post {
            ensureBound()
            drain()
        }
    }

    private fun drain() {
        val (service, frame) = synchronized(lock) {
            val f = pending ?: return
            val b = binder ?: return
            pending = null
            b to f
        }
        if (frame == last) return
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(DESCRIPTOR)
            val code = if (frame.isEmpty()) {
                TRANSACTION_CLEAR
            } else {
                data.writeString(frame)
                TRANSACTION_SET_FRAME
            }
            service.transact(code, data, reply, 0)
            reply.readException()
            last = frame
        } catch (e: Exception) {
            Log.w(TAG, "light ring call failed: $e")
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    override fun release() {
        handler.post {
            if (bound) {
                try {
                    context.unbindService(connection)
                } catch (_: Exception) {
                }
            }
            bound = false
            thread.quitSafely()
        }
    }
}
