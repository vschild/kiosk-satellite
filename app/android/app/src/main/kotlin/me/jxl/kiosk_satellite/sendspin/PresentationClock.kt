package me.jxl.kiosk_satellite.sendspin

import kotlin.math.abs

/** Checks presentation timestamp consistency and retains a calibrated head fallback. */
internal class PresentationClock {
    companion object {
        private const val STARTUP_WAIT_NS = 300_000_000L
        private const val TIMESTAMP_STARTUP_NS = 2_000_000_000L
        private const val STALE_NS = 500_000_000L
        // A2DP timestamps include the headset's delay report, so they name
        // the future time a frame will play. The legacy HAL accepts reports
        // up to one second.
        private const val MAX_LEAD_NS = 1_000_000_000L
        private const val MAX_RATE_ERROR_NS = 5_000_000L
        // A Bluetooth stack sends whole codec frames on its own timer and
        // skips a tick to catch up, so its timestamps zigzag by up to one
        // codec frame (23 ms for AAC).
        private const val BLUETOOTH_RATE_ERROR_NS = 30_000_000L
        // Longer than that zigzag's period, 2.4 s for AAC at 44.1 kHz, so
        // its earliest edge stays in the window.
        private const val WINDOW_NS = 4_000_000_000L
        private const val WINDOW_CAPACITY = 512
    }

    var source = "warming_up"
        private set
    var fallbackReason: String? = null
        private set
    var latencyUs = 0L
        private set
    var canPollTimestamp = true
        private set

    /** The output is Bluetooth, whose timestamps step a codec frame at a time. */
    var bluetooth = false

    /** Bluetooth samples off the line so far, and the times the line moved. */
    var outliers = 0
        private set
    var moves = 0
        private set
    /** How far the last move shifted the presentation line, in microseconds. */
    var lastMoveUs = 0L
        private set

    private var startedNs = 0L
    private var referenceNs = 0L
    private var referenceFrames = 0L
    private var lastAdvanceNs = 0L
    private var goodSamples = 0
    private var calibrated = false

    // Recent accepted timestamps. On Bluetooth, playback follows their
    // earliest presentation line, which stays put while the stack zigzags.
    // Other outputs follow the latest sample.
    private val windowNs = LongArray(WINDOW_CAPACITY)
    private val windowFrames = LongArray(WINDOW_CAPACITY)
    private var windowStart = 0
    private var windowSize = 0
    private var anchorNs = 0L
    private var anchorFrames = 0L

    // Consecutive Bluetooth samples off the line, and the latest of them.
    private var outlierRun = 0
    private var outlierNs = 0L
    private var outlierFrames = 0L

    fun reset(nowNs: Long, estimatedLatencyUs: Long) {
        source = "warming_up"
        fallbackReason = null
        latencyUs = estimatedLatencyUs
        startedNs = nowNs
        referenceNs = 0
        referenceFrames = 0
        lastAdvanceNs = nowNs
        goodSamples = 0
        calibrated = false
        canPollTimestamp = true
        windowSize = 0
        outlierRun = 0
        outlierNs = 0
    }

    /**
     * Validates timestamps again on a new output device. Playback keeps
     * following the head, with [estimatedLatencyUs] for the new device,
     * until the new timestamps establish.
     */
    fun rerouted(nowNs: Long, estimatedLatencyUs: Long) {
        val warming = source == "warming_up"
        val started = startedNs
        reset(nowNs, estimatedLatencyUs)
        if (warming) {
            startedNs = started
        } else {
            source = "playback_head"
            fallbackReason = "route_changed"
        }
    }

    fun position(
        nowNs: Long,
        headFrames: Long,
        written: Long,
        sampleRate: Int,
        timestampFrames: Long?,
        timestampNs: Long?,
    ): Long {
        if (canPollTimestamp && timestampFrames != null && timestampNs != null) {
            val valid = timestampNs > 0 && timestampNs >= startedNs &&
                timestampNs - nowNs <= MAX_LEAD_NS && nowNs - timestampNs <= STALE_NS &&
                timestampFrames in 0..written
            if (valid && timestampNs != referenceNs && timestampNs != outlierNs) {
                val deltaNs = timestampNs - referenceNs
                val deltaFrames = timestampFrames - referenceFrames
                // Validation compares consecutive samples. Once established,
                // a Bluetooth sample is compared against the filtered line.
                val rateError = when {
                    referenceNs == 0L -> 0L
                    source == "timestamp" && bluetooth -> abs(
                        (timestampFrames - anchorFrames) * 1_000_000_000L / sampleRate -
                            (timestampNs - anchorNs),
                    )
                    else -> abs(deltaFrames * 1_000_000_000L / sampleRate - deltaNs)
                }
                val maxRateError = if (source == "timestamp" && bluetooth) {
                    BLUETOOTH_RATE_ERROR_NS
                } else {
                    MAX_RATE_ERROR_NS
                }
                if (referenceNs == 0L ||
                    (deltaNs > 0 && deltaFrames > 0 && rateError <= maxRateError)
                ) {
                    referenceNs = timestampNs
                    referenceFrames = timestampFrames
                    lastAdvanceNs = nowNs
                    outlierRun = 0
                    addToWindow(timestampNs, timestampFrames, sampleRate)
                    goodSamples++
                    if (goodSamples >= 3) {
                        source = "timestamp"
                        fallbackReason = null
                    }
                    if (source == "timestamp") {
                        val presented = anchorFrames + (nowNs - anchorNs) * sampleRate / 1_000_000_000L
                        // Keep the same presentation reference if timestamps later freeze.
                        // The head clock has already removed mixer-period jitter.
                        val measuredUs = ((headFrames - presented) * 1_000_000 / sampleRate)
                            .coerceIn(0, 1_000_000)
                        latencyUs = if (calibrated) (latencyUs * 7 + measuredUs) / 8 else measuredUs
                        calibrated = true
                    }
                } else if (source == "timestamp" && bluetooth) {
                    holdThroughOutlier(nowNs, timestampNs, timestampFrames, sampleRate)
                } else if (source == "timestamp") {
                    fallBack("inconsistent_timestamp")
                } else {
                    referenceNs = timestampNs
                    referenceFrames = timestampFrames
                    windowSize = 0
                    addToWindow(timestampNs, timestampFrames, sampleRate)
                    goodSamples = 1
                }
            }
        }
        if (source == "timestamp" &&
            (nowNs - lastAdvanceNs > STALE_NS || nowNs - referenceNs > STALE_NS)
        ) {
            fallBack("stalled_timestamp")
        }
        if (source == "warming_up" && nowNs - startedNs >= STARTUP_WAIT_NS) {
            fallBack("timestamp_unavailable")
        }
        // Some drivers need more than the priming window to publish three
        // advancing timestamps. Let those establish the physical reference
        // without holding up playback. A rejected live clock never returns.
        if (source == "playback_head" && nowNs - startedNs >= TIMESTAMP_STARTUP_NS) {
            canPollTimestamp = false
        }
        val frames = when (source) {
            "timestamp" -> anchorFrames + (nowNs - anchorNs) * sampleRate / 1_000_000_000L
            "playback_head" -> headFrames - latencyUs * sampleRate / 1_000_000
            else -> 0
        }
        return frames.coerceIn(0, written)
    }

    /**
     * Keeps the Bluetooth line through a sample that strays from it. Three
     * strays in a row that agree with each other mean the line itself moved,
     * as after an underrun, so playback follows them from then on. Strays
     * that never agree stop advancing the line and end in a stall.
     */
    private fun holdThroughOutlier(nowNs: Long, ns: Long, frames: Long, sampleRate: Int) {
        outliers++
        val deltaNs = ns - outlierNs
        val deltaFrames = frames - outlierFrames
        val agrees = outlierRun > 0 && deltaNs > 0 && deltaFrames > 0 &&
            abs(deltaFrames * 1_000_000_000L / sampleRate - deltaNs) <= MAX_RATE_ERROR_NS
        outlierRun = if (agrees) outlierRun + 1 else 1
        outlierNs = ns
        outlierFrames = frames
        if (outlierRun < 3) return
        val expected = anchorFrames + (ns - anchorNs) * sampleRate / 1_000_000_000L
        lastMoveUs = (frames - expected) * 1_000_000 / sampleRate
        moves++
        outlierRun = 0
        referenceNs = ns
        referenceFrames = frames
        lastAdvanceNs = nowNs
        windowSize = 0
        addToWindow(ns, frames, sampleRate)
    }

    /** Adds a sample and moves the anchor to the earliest line in the window. */
    private fun addToWindow(ns: Long, frames: Long, sampleRate: Int) {
        if (!bluetooth) windowSize = 0
        if (windowSize == WINDOW_CAPACITY) {
            windowStart = (windowStart + 1) % WINDOW_CAPACITY
            windowSize--
        }
        val end = (windowStart + windowSize) % WINDOW_CAPACITY
        windowNs[end] = ns
        windowFrames[end] = frames
        windowSize++
        while (windowSize > 1 && ns - windowNs[windowStart] > WINDOW_NS) {
            windowStart = (windowStart + 1) % WINDOW_CAPACITY
            windowSize--
        }
        var earliest = frames
        for (i in 0 until windowSize) {
            val index = (windowStart + i) % WINDOW_CAPACITY
            val projected = windowFrames[index] +
                (ns - windowNs[index]) * sampleRate / 1_000_000_000L
            if (projected < earliest) earliest = projected
        }
        anchorNs = ns
        anchorFrames = earliest
    }

    private fun fallBack(reason: String) {
        source = "playback_head"
        fallbackReason = reason
        if (reason != "timestamp_unavailable") canPollTimestamp = false
    }
}
