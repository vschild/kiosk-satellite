package me.jxl.kiosk_satellite

import kotlin.math.min

/**
 * The policy behind the capture format ladder in [MicRecorder]: when a
 * walk down the ladder may start, where capture lands when the ladder runs
 * out, and how much silence a rung is allowed before it counts against it.
 *
 * A refused open and a delivered rate that does not match the rate opened
 * are facts about the format. Zeros are not: a room is quiet, a HAL gates
 * its output to exact silence between sounds, a privacy toggle mutes the
 * microphone. So a rung that has delivered audio is trusted, and silence on
 * it counts only after [TRUSTED_ZERO_BYTES] rather than the
 * [FRESH_ZERO_BYTES] a rung that has never delivered anything gets. When
 * the ladder runs out, capture goes back to the rung that last delivered
 * audio (the first rung when none did) instead of staying on the last one
 * tried, and the next walk waits out a backoff that doubles up to
 * [BACKOFF_MAX_NS]: a microphone that really died is retried within
 * minutes, one that is merely quiet is not reopened every two seconds.
 *
 * A run of zeros that ends in audio without a reopen proves the rung
 * gates: a dead capture does not come back by itself. Silence on a
 * [gating] rung never walks the ladder. After [GATING_ZERO_BYTES] it is
 * only reopened in place, on the same format and source, which still
 * recovers a capture that wedged.
 */
internal class CaptureWalk(private val rungs: Int, start: Int, gating: Set<Int> = emptySet()) {
    companion object {
        /** All-zero bytes, as 16 kHz mono PCM16, before a fresh rung is given up on: 2 s. */
        const val FRESH_ZERO_BYTES = 2L * 16000 * 2

        /** The same for a rung that has delivered audio: 30 s. */
        const val TRUSTED_ZERO_BYTES = 30L * 16000 * 2

        /** The same for a rung proven to gate, before it is reopened in place: 10 min. */
        const val GATING_ZERO_BYTES = 600L * 16000 * 2

        const val BACKOFF_FIRST_NS = 60_000_000_000L
        const val BACKOFF_MAX_NS = 600_000_000_000L

        /**
         * Bounds on the delivered rate against the rate opened, wide enough
         * that no healthy device trips them (see [rateVerdict]).
         */
        const val RATE_RATIO_MIN = 0.6
        const val RATE_RATIO_MAX = 1.6

        /**
         * What a delivered-rate measurement says about the format, given
         * [ratio] (frames delivered against the rate opened) and whether
         * the device [played] a sound during the window. Too many frames
         * is a format lie whatever plays. Too few is one only in a window
         * without a sound: some HALs starve the capture while the device
         * plays (an MT8167 panel read 6% of the rate under an answer),
         * which says nothing about the format, so that window is measured
         * again.
         */
        fun rateVerdict(ratio: Double, played: Boolean): RateVerdict = when {
            ratio > RATE_RATIO_MAX -> RateVerdict.LIE
            ratio < RATE_RATIO_MIN -> if (played) RateVerdict.MEASURE_AGAIN else RateVerdict.LIE
            else -> RateVerdict.HONEST
        }
    }

    enum class RateVerdict { HONEST, LIE, MEASURE_AGAIN }

    /** The rung capture is open at. */
    var step = start
        private set

    /** The rung that most recently delivered audio, or -1. */
    var audibleStep = -1
        private set

    /** When the next walk may start, as armed by the last [exhausted]. */
    var nextWalkNs = 0L
        private set
    private var backoffNs = BACKOFF_FIRST_NS
    private val gatingRungs = BooleanArray(rungs) { it in gating }

    /** Seconds until the next walk may start, as armed by the last [exhausted]. */
    var waitSeconds = 0L
        private set

    /** Capture moved to [rung]. */
    fun opened(rung: Int) {
        require(rung in 0 until rungs)
        step = rung
    }

    /**
     * The current rung delivered nonzero audio after [afterZeroBytes] of
     * silence in the same open. True when that proves for the first time
     * that the rung gates.
     */
    fun audible(afterZeroBytes: Long = 0L): Boolean {
        audibleStep = step
        if (afterZeroBytes < FRESH_ZERO_BYTES || gatingRungs[step]) return false
        gatingRungs[step] = true
        return true
    }

    /** The current rung is one that gates quiet audio to zeros. */
    val gating: Boolean get() = gatingRungs[step]

    /** The current rung is one that delivered audio at some point. */
    val trusted: Boolean get() = audibleStep == step

    /** How much silence the current rung may read before it counts against it. */
    val zeroLimitBytes: Long get() = when {
        gating -> GATING_ZERO_BYTES
        trusted -> TRUSTED_ZERO_BYTES
        else -> FRESH_ZERO_BYTES
    }

    /** Whether a walk down the ladder may start now. */
    fun mayWalk(nowNs: Long): Boolean = nowNs >= nextWalkNs

    /**
     * Every rung past the current one has been tried and none delivered
     * audio. Arms the backoff and returns the rung to go back to.
     */
    fun exhausted(nowNs: Long): Int {
        nextWalkNs = nowNs + backoffNs
        waitSeconds = backoffNs / 1_000_000_000L
        backoffNs = min(backoffNs * 2, BACKOFF_MAX_NS)
        return if (audibleStep >= 0) audibleStep else 0
    }
}
