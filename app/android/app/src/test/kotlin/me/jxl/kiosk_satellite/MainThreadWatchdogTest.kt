package me.jxl.kiosk_satellite

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MainThreadWatchdogTest {
    private val stall = MainThreadWatchdog.STALL_MS
    private val grace = MainThreadWatchdog.GRACE_MS

    @Test fun oneTaskHoldingTheMainThreadForAMinuteIsADeadlock() {
        assertTrue(MainThreadWatchdog.stalled(stall, grace, debugger = false))
        assertTrue(MainThreadWatchdog.stalled(9 * 3_600_000L, 5 * 86_400_000L, debugger = false))
    }

    @Test fun anythingShorterIsJustASlowDevice() {
        assertFalse(MainThreadWatchdog.stalled(stall - 1, 86_400_000L, debugger = false))
        assertFalse(MainThreadWatchdog.stalled(20_000L, 86_400_000L, debugger = false))
    }

    @Test fun startupIsLeftAlone() {
        assertFalse(MainThreadWatchdog.stalled(stall, grace - 1, debugger = false))
    }

    @Test fun aBreakpointIsNotADeadlock() {
        assertFalse(MainThreadWatchdog.stalled(stall * 10, grace * 10, debugger = true))
    }
}
