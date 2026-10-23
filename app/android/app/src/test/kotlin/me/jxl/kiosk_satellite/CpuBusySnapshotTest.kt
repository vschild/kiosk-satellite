package me.jxl.kiosk_satellite

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CpuBusySnapshotTest {
    private fun ticks(awakeSeconds: Double, cores: Int, vararg busy: Pair<Int, Long>) =
        CpuBusySnapshot(
            (awakeSeconds * 1e9).toLong(), (awakeSeconds * 1e9).toLong(), cores, busy.toMap(),
            ticksPerSecond = 100,
        )

    @Test
    fun parsesBusyTicksPerCore() {
        val busy = CpuBusySnapshot.parseProcStat(
            """
            cpu  57099296 3222092 54170387 692258140 197189 9034917 2456617 0 0 0
            cpu0 100 20 30 9000 50 4 5 1 0 0
            cpu2 10 0 5 900 0 0 0
            intr 2325401093 0 0
            ctxt 2575421674
            """.trimIndent(),
        )
        // user + nice + system + irq + softirq + steal, idle and iowait left out.
        assertEquals(mapOf(0 to 160L, 2 to 15L), busy)
    }

    @Test
    fun measuresBusyTicksAgainstAwakeTime() {
        val before = ticks(0.0, 2, 0 to 0L, 1 to 0L)
        // Ten seconds: one core 30% busy, the other 10%.
        val now = ticks(10.0, 2, 0 to 300L, 1 to 100L)
        assertEquals(20.0, now.usageSince(before)!!, 0.0001)
    }

    @Test
    fun ignoresTheBrokenIdleCountOfAHotplugKernel() {
        // Replays a LineageOS Echo Show 8 over 5.33 seconds: cpu1
        // and cpu2 logged about 50 ticks in total each, nearly all busy,
        // and cpu3 stayed offline. Busy over total read cpu1 as 98% busy
        // when it ran for a tenth of the window.
        val before = ticks(0.0, 4, 0 to 1000L, 1 to 2000L, 2 to 3000L)
        val now = ticks(5.33, 4, 0 to 1203L, 1 to 2048L, 2 to 3050L)
        assertEquals((203 + 48 + 50) / 533.0 / 4 * 100, now.usageSince(before)!!, 0.0001)
    }

    @Test
    fun anOfflineCoreCountsAsFreeCapacity() {
        val before = ticks(0.0, 4, 0 to 0L, 1 to 0L)
        val now = ticks(10.0, 4, 0 to 1000L)
        assertEquals(25.0, now.usageSince(before)!!, 0.0001)
    }

    @Test
    fun aResetCounterIsSkipped() {
        val before = ticks(0.0, 2, 0 to 500L, 1 to 900L)
        val now = ticks(10.0, 2, 0 to 1000L, 1 to 10L)
        assertEquals(25.0, now.usageSince(before)!!, 0.0001)
    }

    @Test
    fun aCoreNeverReadsAboveFull() {
        val before = ticks(0.0, 1, 0 to 0L)
        // Tick rounding can land a few ticks past the window.
        val now = ticks(1.0, 1, 0 to 103L)
        assertEquals(100.0, now.usageSince(before)!!, 0.0001)
    }

    @Test
    fun theHalWindowIsTheWidestCoreTotal() {
        // Vendor units, so no tick rate: cpu0 was online for the whole
        // window (1000 units), cpu1 for half of it.
        val before = CpuBusySnapshot(0, 0, 2, mapOf(0 to 0L, 1 to 0L), mapOf(0 to 0L, 1 to 0L))
        val now = CpuBusySnapshot(
            1, 1, 2, mapOf(0 to 400L, 1 to 100L), mapOf(0 to 1000L, 1 to 500L),
        )
        assertEquals(25.0, now.usageSince(before)!!, 0.0001)
    }

    @Test
    fun noWindowOrAnotherSourceGivesNoReading() {
        val before = ticks(5.0, 1, 0 to 0L)
        assertNull(ticks(5.0, 1, 0 to 10L).usageSince(before))
        val idle = CpuIdleSnapshot(0, 0, mapOf("cpu0" to 0L), emptyMap(), mapOf("cpu0" to true))
        assertNull(ticks(10.0, 1, 0 to 10L).usageSince(idle))
    }
}
