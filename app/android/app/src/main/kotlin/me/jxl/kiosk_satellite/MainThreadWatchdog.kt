package me.jxl.kiosk_satellite

import android.content.Context
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.os.SystemClock
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Restarts the process when the main thread stops turning (issue #1166).
 *
 * Every other recovery runs on the main thread: the Dart frame watchdog
 * (Dart shares the platform thread), the heartbeat receiver and the
 * Activity's own callbacks. A deadlock there (WebView 138 on Android 8.1
 * parked Viz's doFrame on a wait the in-process GPU thread never signaled)
 * freezes all of them with it. Android shows its ANR dialog, never kills a
 * foreground app, and the panel stays dead until someone walks up to it.
 *
 * This thread asks only whether the Looper finishes its current task. The
 * ping goes to the front of the queue and is asynchronous, so a long queue,
 * a sync barrier or a slow dashboard never delays it: it waits only for the
 * one task in progress. Slowness shows up as many short tasks and never
 * trips this. A minute inside one task does, the same limit Android's own
 * watchdog gives system_server. The first two minutes of a process are
 * left alone, and a debugger at a breakpoint is never mistaken for a
 * deadlock. The clock is uptime, so deep sleep does not count as stalled.
 */
object MainThreadWatchdog {
    private const val TAG = "MainThreadWatchdog"

    private const val CHECK_MS = 5_000L

    /** One task holding the main thread this long is a deadlock. */
    internal const val STALL_MS = 60_000L

    /** Process start, engine boot and the first WebView all run here. */
    internal const val GRACE_MS = 120_000L

    private val started = AtomicBoolean(false)

    fun start(context: Context) {
        if (!started.compareAndSet(false, true)) return
        val app = context.applicationContext
        Thread({ watch(app) }, "ks-main-watchdog").apply {
            isDaemon = true
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    /** Whether a ping unanswered for [waitedMs] means the main thread is stuck. */
    internal fun stalled(waitedMs: Long, aliveMs: Long, debugger: Boolean): Boolean =
        !debugger && aliveMs >= GRACE_MS && waitedMs >= STALL_MS

    private fun watch(context: Context) {
        val main = Handler(Looper.getMainLooper())
        val startedAt = SystemClock.uptimeMillis()
        val answered = AtomicBoolean(true)
        var postedAt = startedAt
        while (true) {
            val now = SystemClock.uptimeMillis()
            if (answered.get()) {
                answered.set(false)
                postedAt = now
                val ping = Message.obtain(main) { answered.set(true) }
                ping.isAsynchronous = true
                main.sendMessageAtFrontOfQueue(ping)
            } else if (stalled(now - postedAt, now - startedAt, Debug.isDebuggerConnected())) {
                restart(context, (now - postedAt) / 1000)
                return
            }
            try {
                Thread.sleep(CHECK_MS)
            } catch (_: InterruptedException) {
                return
            }
        }
    }

    private fun restart(context: Context, seconds: Long) {
        val mainThread = Looper.getMainLooper().thread
        val stack = mainThread.stackTrace
        val reason = "the main thread watchdog found the main thread stuck in one task for ${seconds}s"
        Log.e(TAG, reason + "\n" + stack.joinToString("\n") { "  at $it" })
        // The main thread's frames, not this thread's: where it is stuck is
        // the whole report.
        CrashJournal.note(context, reason, mainThread, stack)
        // Only bring the kiosk back if it was the thing on screen. Otherwise
        // the sticky service restarts the process behind the app in front.
        val foreground = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.ks.crash.was_foreground", false)
        if (foreground) BackgroundBridge.prepareRelaunch(context)
        me.jxl.kiosk_satellite.plugins.PluginBridge.noteDeliberateExit(context)
        android.os.Process.killProcess(android.os.Process.myPid())
    }
}
