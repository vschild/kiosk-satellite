package me.jxl.kiosk_satellite

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.os.Binder
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Parcel
import android.util.Log

/**
 * The volume buttons of an Echo Dot on the Kiosk Satellite Edition ROM
 * ([Headless.volumeClaim]).
 *
 * The ROM's framework takes the volume buttons before any app sees them and
 * has BiscuitService change the volume. An app can claim them through
 * BiscuitService's binder with a token of its own: while the claim holds,
 * each press arrives as a `VOLUME_BUTTON` broadcast instead, and the claim
 * ends with the token, so a crash never leaves the buttons dead. The
 * interface ships with the ROM, so it is called by its transaction code,
 * like the light ring (leds/BiscuitLedRing.kt).
 */
object BiscuitVolumeButtons {
    private const val TAG = "BiscuitVolumeButtons"
    private const val PACKAGE = "com.amazon.biscuit.service"
    private const val DESCRIPTOR = "com.amazon.biscuit.service.IBiscuitService"
    private const val TRANSACTION_CLAIM_VOLUME_BUTTONS = 7
    private const val VOLUME_BUTTON = "com.amazon.biscuit.service.VOLUME_BUTTON"

    private val thread by lazy { HandlerThread("biscuit-volume").apply { start() } }
    private val handler by lazy { Handler(thread.looper) }
    private val token = Binder()

    private var context: Context? = null
    private var binder: IBinder? = null
    private var bound = false

    /** What Dart last asked for. Read again after the service restarts. */
    @Volatile private var wanted = false

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            handler.post {
                binder = service
                send()
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            handler.post { binder = null }
        }
    }

    /** Listen for the presses; [onPress] gets "up" or "down". */
    fun attach(context: Context, onPress: (String) -> Unit) {
        if (!Headless.volumeClaim || this.context != null) return
        this.context = context.applicationContext
        context.registerReceiver(
            object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    val direction = intent.getStringExtra("direction")
                    if (direction == "up" || direction == "down") onPress(direction)
                }
            },
            IntentFilter(VOLUME_BUTTON),
        )
    }

    fun claim(claimed: Boolean) {
        if (context == null) return
        wanted = claimed
        handler.post {
            if (!bound) bind()
            send()
        }
    }

    private fun bind() {
        val ctx = context ?: return
        bound = try {
            ctx.bindService(
                Intent(DESCRIPTOR).setPackage(PACKAGE),
                connection,
                Context.BIND_AUTO_CREATE,
            )
        } catch (e: Exception) {
            Log.w(TAG, "could not bind BiscuitService: $e")
            false
        }
    }

    private fun send() {
        val service = binder ?: return
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(DESCRIPTOR)
            data.writeStrongBinder(token)
            data.writeInt(if (wanted) 1 else 0)
            service.transact(TRANSACTION_CLAIM_VOLUME_BUTTONS, data, reply, 0)
            reply.readException()
        } catch (e: Exception) {
            Log.w(TAG, "volume button claim failed: $e")
        } finally {
            data.recycle()
            reply.recycle()
        }
    }
}
