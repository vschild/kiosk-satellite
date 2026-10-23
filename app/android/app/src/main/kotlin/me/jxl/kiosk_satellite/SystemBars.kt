package me.jxl.kiosk_satellite

import android.app.Activity
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController

/**
 * Re-asserts the kiosk's immersive mode from the native side when a window
 * gains focus.
 *
 * Dart asks for immersive-sticky at launch and on every resume, but that
 * request reaches the window that exists when it lands. An Activity
 * destroyed and re-created under the process-wide engine (Back on a Meta
 * Portal's own system bar finishes it, a tile tap re-creates it) gets a
 * fresh window, and on the Portal the bar service shows its bars for a new
 * Activity until the window reports otherwise: a resume that raced that
 * report left Meta's bar over the dashboard until the next focus change.
 * Applying the same flags here, at focus and again a beat later, closes
 * that gap on every device, and repeating an already-applied mode is free.
 *
 * With Hide status bar or Hide navigation bar off (issues #1076 and #1102)
 * that bar stays up instead: [hideStatus] and [hideNavigation] limit the
 * re-assertion to the bars that hide, and CutoutLayout pads the content by
 * the visible ones so nothing draws under them.
 */
object SystemBars {
    private val main = Handler(Looper.getMainLooper())

    /** Whether each bar stays hidden: its Screen setting, or kiosk mode and
     *  lockdown, which always hide both. Seeded by MainActivity.onCreate
     *  from the settings mirror and kept current by KioskLock.apply. */
    @Volatile var hideStatus = true
    @Volatile var hideNavigation = true

    /** Whether any bar stays up, which is when the content gets padded. */
    val anyShown: Boolean get() = !hideStatus || !hideNavigation

    /** The layout flags Flutter's modes keep in every case, for Android 10
     *  and older, where the insets controller does not exist. The window
     *  stays laid out under the bars, which CutoutLayout pads. */
    @Suppress("DEPRECATION")
    private const val LEGACY_LAYOUT_FLAGS =
        View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN

    @Suppress("DEPRECATION")
    private fun legacyHideFlags(): Int {
        var flags = 0
        if (hideStatus) flags = flags or View.SYSTEM_UI_FLAG_FULLSCREEN
        if (hideNavigation) flags = flags or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
        if (flags != 0) flags = flags or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        return flags
    }

    private fun hiddenTypes(): Int {
        var types = 0
        if (hideStatus) types = types or WindowInsets.Type.statusBars()
        if (hideNavigation) types = types or WindowInsets.Type.navigationBars()
        return types
    }

    private fun shownTypes(): Int =
        (WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars()) and
            hiddenTypes().inv()

    /** Hide and show the bars for a settings change, then re-dispatch the
     *  insets so the content padding follows. Dart switches the system UI
     *  mode too; this covers a window whose bars were hidden from here. */
    fun apply(activity: Activity, status: Boolean, navigation: Boolean) {
        hideStatus = status
        hideNavigation = navigation
        hide(activity)
        show(activity)
        activity.window?.decorView?.requestApplyInsets()
    }

    /** Hide the bars now and again shortly after, for a window that just
     *  gained focus. */
    fun reassertOnFocus(activity: Activity) {
        if (!hideStatus && !hideNavigation) return
        hide(activity)
        for (delay in longArrayOf(500L, 2500L)) {
            main.postDelayed({
                if (!activity.isFinishing && !activity.isDestroyed) hide(activity)
            }, delay)
        }
    }

    fun hide(activity: Activity) {
        val window = activity.window ?: return
        if (Build.VERSION.SDK_INT >= 30) {
            val types = hiddenTypes()
            if (types == 0) return
            val controller = window.insetsController ?: return
            // Flutter's manual mode hides a bar without the sticky flag, so
            // a swipe would bring it back for good. Setting the behavior on
            // the controller takes it out of the legacy flags' hands: from
            // then on a swipe only shows the bar for a moment, as in
            // immersive sticky.
            if (controller.systemBarsBehavior !=
                WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE) {
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
            val insets = window.decorView.rootWindowInsets
            val visible = insets == null ||
                (hideStatus && insets.isVisible(WindowInsets.Type.statusBars())) ||
                (hideNavigation && insets.isVisible(WindowInsets.Type.navigationBars()))
            if (!visible) return
            controller.hide(types)
        } else {
            val flags = legacyHideFlags()
            if (flags == 0) return
            @Suppress("DEPRECATION")
            val decor = window.decorView
            @Suppress("DEPRECATION")
            val wanted = LEGACY_LAYOUT_FLAGS or flags
            @Suppress("DEPRECATION")
            if (decor.systemUiVisibility and wanted != wanted) {
                @Suppress("DEPRECATION")
                decor.systemUiVisibility = decor.systemUiVisibility or wanted
            }
        }
    }

    fun show(activity: Activity) {
        val window = activity.window ?: return
        if (Build.VERSION.SDK_INT >= 30) {
            val types = shownTypes()
            if (types == 0) return
            val insets = window.decorView.rootWindowInsets
            if (insets != null &&
                (hideStatus || insets.isVisible(WindowInsets.Type.statusBars())) &&
                (hideNavigation || insets.isVisible(WindowInsets.Type.navigationBars()))
            ) return
            window.insetsController?.show(types)
        } else {
            @Suppress("DEPRECATION")
            var clear = 0
            @Suppress("DEPRECATION")
            if (!hideStatus) clear = clear or View.SYSTEM_UI_FLAG_FULLSCREEN
            @Suppress("DEPRECATION")
            if (!hideNavigation) clear = clear or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            @Suppress("DEPRECATION")
            if (!hideStatus && !hideNavigation) {
                clear = clear or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            }
            if (clear == 0) return
            @Suppress("DEPRECATION")
            val decor = window.decorView
            @Suppress("DEPRECATION")
            if (decor.systemUiVisibility and clear != 0) {
                @Suppress("DEPRECATION")
                decor.systemUiVisibility = decor.systemUiVisibility and clear.inv()
            }
        }
    }
}
