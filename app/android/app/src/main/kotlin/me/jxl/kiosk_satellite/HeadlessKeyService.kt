package me.jxl.kiosk_satellite

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

/**
 * The hardware buttons of a device without a screen ([Headless]).
 *
 * With a screen, keys reach the kiosk through its focused Activity. A
 * headless device never has one, so its buttons (an Echo Dot's action,
 * microphone and volume buttons) would go nowhere. An accessibility service
 * that filters key events sees every key before any window does, which is
 * the one way an app can hear them without being on screen.
 *
 * The component ships disabled and is enabled only on headless devices
 * (see [HardwareKeys.attach]), so no other device lists it. With no screen
 * for Android's Accessibility settings, it is switched on over adb:
 *
 *     adb shell settings put secure enabled_accessibility_services \
 *         me.jxl.kiosk_satellite/.HeadlessKeyService
 *     adb shell settings put secure accessibility_enabled 1
 */
class HeadlessKeyService : AccessibilityService() {
    companion object {
        /** Bound and live: the buttons can be heard. */
        @Volatile
        var running = false
            private set
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        running = true
    }

    override fun onKeyEvent(event: KeyEvent): Boolean = HardwareKeys.onKey(event)

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onUnbind(intent: Intent?): Boolean {
        running = false
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }
}
