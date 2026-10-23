package me.jxl.kiosk_satellite

/** One reading of a CPU source, timed against the CPU's awake clock. */
internal interface CpuSnapshot {
    val elapsedNanos: Long
    val awakeNanos: Long

    /** Percent busy since [before], or null when the two cannot be
     *  compared, such as readings from different sources. */
    fun usageSince(before: CpuSnapshot): Double?
}

/**
 * Cumulative busy time per core, from `/proc/stat` or the thermal HAL.
 *
 * Busy time is what a core spends running, and a running core always
 * takes the scheduler tick, so its count is reliable. Idle time is not:
 * a LineageOS Echo Show 8 credits its second core 293 idle ticks in five
 * days, and an Echo Show 5 reports idle jumps of half a million seconds.
 * So only the busy count is used, against the window's length.
 *
 * With [ticksPerSecond] (`/proc/stat`), the window is awake time in
 * ticks. Without it (the HAL, whose units vary by vendor), the window is
 * the widest total any core counted, which is a core online for all of
 * it. Either way an offline core or one missing from a reading counts as
 * free capacity, like the parked cores in [CpuIdleSnapshot].
 */
internal class CpuBusySnapshot(
    override val elapsedNanos: Long,
    override val awakeNanos: Long,
    val cores: Int,
    val busy: Map<Int, Long>,
    val total: Map<Int, Long> = emptyMap(),
    val ticksPerSecond: Long? = null,
) : CpuSnapshot {
    override fun usageSince(before: CpuSnapshot): Double? {
        if (before !is CpuBusySnapshot || cores <= 0) return null
        val window = if (ticksPerSecond != null) {
            (awakeNanos - before.awakeNanos) / 1e9 * ticksPerSecond
        } else {
            total.maxOfOrNull { (core, now) -> now - (before.total[core] ?: now) }
                ?.toDouble() ?: 0.0
        }
        if (window <= 0) return null
        var sum = 0.0
        for ((core, now) in busy) {
            val then = before.busy[core] ?: continue
            // A counter that went backwards was reset, not a measurement.
            if (now < then) continue
            sum += ((now - then) / window).coerceAtMost(1.0)
        }
        return (sum / cores * 100.0).coerceIn(0.0, 100.0)
    }

    companion object {
        /**
         * Busy ticks per core from `/proc/stat`: user, nice, system, irq,
         * softirq and steal. Guest time is already inside user and nice.
         * Only online cores have a line.
         */
        fun parseProcStat(text: String): Map<Int, Long> {
            val out = HashMap<Int, Long>()
            for (line in text.lineSequence()) {
                if (!line.startsWith("cpu") || line.length < 4 || !line[3].isDigit()) continue
                val fields = line.trim().split(Regex("\\s+"))
                val core = fields[0].removePrefix("cpu").toIntOrNull() ?: continue
                val v = fields.drop(1).map { it.toLongOrNull() ?: 0L }
                if (v.size < 7) continue
                out[core] = v[0] + v[1] + v[2] + v[5] + v[6] + (v.getOrNull(7) ?: 0L)
            }
            return out
        }
    }
}
