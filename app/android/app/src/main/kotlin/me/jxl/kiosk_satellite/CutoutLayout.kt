package me.jxl.kiosk_satellite

import android.app.Activity
import android.content.Context
import android.graphics.Insets
import android.graphics.Rect
import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.android.FlutterViewDelegate

/**
 * Applies the "Display cutout" setting (browser.cutout_mode) to an
 * Activity's window.
 *
 * Anything that survives the inset dispatch reaches the dashboard WebView,
 * Chromium republishes it to the page as env(safe-area-inset-*), and Home
 * Assistant's frontend pads its layout by it. Two independent rules decide
 * what survives:
 *
 *  - System bar insets (status bar, navigation bar and caption bar) are
 *    withheld ALWAYS, on every mode. The app keeps the bars hidden, so a
 *    page padding for them is never right; on healthy ROMs
 *    their insets are zero while hidden and this is a no-op. The whole
 *    systemBars group is stripped, not just status and navigation, because
 *    Chromium's safe area is displayCutout plus systemBars, and that group
 *    also holds the caption bar: Lenovo's Android 15 tablets put a
 *    multi-window handle on top of fullscreen apps, and the gap came back
 *    there with only status and navigation stripped (issue #961). Lenovo's
 *    ZUI also reports the status bar inset as occupied even while immersive
 *    mode has the bar hidden, which put a bar-height gap inside the page on
 *    a device with no cutout at all (discussion #102:
 *    the reporter's photos show the page background full-bleed with the
 *    content padded down one bar height, and with Home Assistant's header
 *    shown the gap sits above the header, its own safe-area padding). Kept
 *    out of the cutout setting deliberately: that device has nothing to
 *    gain from any cutout choice, and no choice should reopen the gap.
 *  - The cutout inset follows the mode: the fill modes (always,
 *    short_edges) withhold it, along with claiming the cutout row via
 *    layoutInDisplayCutoutMode; the avoid modes (default, never) let it
 *    through, so the page can pad below a punch-hole camera.
 *
 * IME insets always pass through for Flutter's keyboard handling.
 *
 * With Hide status bar or Hide navigation bar off (issues #1076 and #1102)
 * that bar stays up, and the content view is padded by it instead. The
 * window keeps its edge-to-edge layout, the bar strips show the black
 * window background and everything inside (Flutter, the dashboard page)
 * still sees zero bar insets, so no layout of the app's own has to change.
 *
 * Some ROMs overrule the mode: One UI forces the window into the cutout row
 * regardless of a NEVER request (verified on One UI 8: the window-level
 * attribute reads NEVER post-set, yet the relayout the WindowManager receives
 * says always). The avoid modes still do their job there through the inset
 * half: un-stripped, the cutout inset reaches the page and Home Assistant
 * pads its header below the camera.
 *
 * Called from MainActivity.onCreate with the SharedPreferences mirror of
 * the setting (right from the first frame), and from KioskLock.apply when
 * the setting changes at runtime.
 */
object CutoutLayout {
    /** Read by the listener on every dispatch; apply() flips it per mode.
     *  Governs only the cutout inset; bars are stripped unconditionally. */
    @Volatile private var stripCutout = true

    fun apply(activity: Activity, mode: String) {
        if (Build.VERSION.SDK_INT >= 28) applyCutoutMode(activity, mode)
        // Idempotent: a second apply() replaces the previous listener.
        activity.window.decorView.setOnApplyWindowInsetsListener { view, insets ->
            padForBars(activity, insets)
            view.onApplyWindowInsets(stripped(insets))
        }
        // Re-dispatch so a runtime mode change reaches the page immediately;
        // the WebView re-evaluates env(safe-area-inset-*) on the spot.
        activity.window.decorView.requestApplyInsets()
    }

    private fun applyCutoutMode(activity: Activity, mode: String) {
        stripCutout = mode == "always" || mode == "short_edges"
        // A fresh copy, not an in-place mutation: getAttributes returns the
        // window's own instance, and setAttributes copies the argument onto
        // that instance to compute what changed. Handing it back itself makes
        // the diff empty and the new mode never reaches the WindowManager
        // (it only worked before attach, where addView takes the attrs as-is).
        val lp = WindowManager.LayoutParams()
        lp.copyFrom(activity.window.attributes)
        activity.window.attributes = lp.apply {
            layoutInDisplayCutoutMode = when (mode) {
                "never" -> WindowManager.LayoutParams
                    .LAYOUT_IN_DISPLAY_CUTOUT_MODE_NEVER
                "default" -> WindowManager.LayoutParams
                    .LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT
                "short_edges" -> WindowManager.LayoutParams
                    .LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                // "always" needs API 30; short edges is the closest below.
                else -> if (Build.VERSION.SDK_INT >= 30) {
                    WindowManager.LayoutParams
                        .LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams
                        .LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
            }
        }
    }

    /**
     * The room the bars that stay up take, empty while both are hidden. Only
     * a bar whose setting keeps it up counts, so a ROM that reports a hidden
     * bar's inset (Lenovo's ZUI, discussion #102) cannot open a gap. Only the
     * status and navigation bars: the caption bar is a handle some ROMs float
     * over a full-screen app (issue #961), not a bar to make room for. Before
     * Android 11 the stable insets give the bar sizes without the keyboard,
     * which the legacy system window insets fold in. There the status bar is
     * the top edge and the navigation bar any of the other three.
     */
    private fun barPadding(insets: WindowInsets): Rect {
        if (!SystemBars.anyShown) return Rect()
        val status = !SystemBars.hideStatus
        val navigation = !SystemBars.hideNavigation
        if (Build.VERSION.SDK_INT >= 30) {
            var types = 0
            if (status) types = types or WindowInsets.Type.statusBars()
            if (navigation) types = types or WindowInsets.Type.navigationBars()
            val bars = insets.getInsets(types)
            return Rect(bars.left, bars.top, bars.right, bars.bottom)
        }
        @Suppress("DEPRECATION")
        return Rect(
            if (navigation) insets.stableInsetLeft else 0,
            if (status) insets.stableInsetTop else 0,
            if (navigation) insets.stableInsetRight else 0,
            if (navigation) insets.stableInsetBottom else 0,
        )
    }

    private fun padForBars(activity: Activity, insets: WindowInsets) {
        val content = activity.findViewById<View>(android.R.id.content) ?: return
        val pad = barPadding(insets)
        if (content.paddingLeft != pad.left || content.paddingTop != pad.top ||
            content.paddingRight != pad.right || content.paddingBottom != pad.bottom) {
            content.setPadding(pad.left, pad.top, pad.right, pad.bottom)
        }
    }

    /**
     * Keeps the caption bar out of Flutter's padding too. On API 35+ the
     * FlutterView grows its top padding to the caption bar's bounding rects,
     * which it reads from the decor view's root insets rather than from the
     * dispatch the listener above strips. On Lenovo's Android 15 tablets that
     * left the drawer and settings one bar lower than the dashboard (issue
     * #961). Called on every new FlutterView, from MainActivity.onCreate.
     */
    fun withholdCaptionBar(view: FlutterView) {
        view.setDelegate(NoCaptionBar)
    }

    private object NoCaptionBar : FlutterViewDelegate() {
        override fun getCaptionBarInsets(context: Context): List<Rect> =
            emptyList()
    }

    private fun stripped(insets: WindowInsets): WindowInsets =
        if (Build.VERSION.SDK_INT >= 30) {
            var types = WindowInsets.Type.systemBars()
            if (stripCutout) types = types or WindowInsets.Type.displayCutout()
            // Inside the padded content every inset shrinks by the padding,
            // the keyboard's too, or Flutter would leave a navigation bar's
            // height of gap above the keyboard.
            val pad = barPadding(insets)
            WindowInsets.Builder(insets.inset(pad.left, pad.top, pad.right, pad.bottom))
                .setInsets(types, Insets.NONE)
                .setInsetsIgnoringVisibility(types, Insets.NONE)
                .setVisible(types, false)
                .apply { if (stripCutout) setDisplayCutout(null) }
                .build()
        } else {
            // Only the cutout on the legacy dispatch: the pre-30 systemWindow
            // insets fold the keyboard in with the bars, so consuming them
            // would leave text fields covered by the IME. While the content
            // is padded for the bars, the bar part comes off them instead,
            // leaving the keyboard's share.
            var legacy = insets
            if (Build.VERSION.SDK_INT >= 28 && stripCutout) {
                @Suppress("DEPRECATION")
                legacy = legacy.consumeDisplayCutout()
            }
            if (SystemBars.anyShown) legacy = withoutPadding(legacy, barPadding(insets))
            legacy
        }

    @Suppress("DEPRECATION")
    private fun withoutPadding(insets: WindowInsets, pad: Rect): WindowInsets =
        insets.replaceSystemWindowInsets(
            maxOf(0, insets.systemWindowInsetLeft - pad.left),
            maxOf(0, insets.systemWindowInsetTop - pad.top),
            maxOf(0, insets.systemWindowInsetRight - pad.right),
            maxOf(0, insets.systemWindowInsetBottom - pad.bottom),
        )
}
