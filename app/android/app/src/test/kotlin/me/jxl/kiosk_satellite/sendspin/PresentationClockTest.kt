package me.jxl.kiosk_satellite.sendspin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class PresentationClockTest {
    private val clock = PresentationClock().also { it.reset(1_000_000_000L, 80_000) }

    private fun sample(ms: Long, presented: Long?, head: Long, stampMs: Long = ms): Long =
        clock.position(ms * 1_000_000, head, 480_000, 48_000, presented, stampMs * 1_000_000)

    private fun establishTimestamp() {
        sample(1_100, 4_800, 10_800)
        sample(1_120, 5_760, 11_760)
        sample(1_140, 6_720, 12_720)
        assertEquals("timestamp", clock.source)
    }

    @Test fun validatedTimestampOverridesTheInitialLatencyEstimate() {
        establishTimestamp()
        assertEquals(125_000, clock.latencyUs)
        assertEquals(7_200, sample(1_150, 6_720, 13_200, stampMs = 1_140))
    }

    @Test fun repeatedTimestampsDoNotCountAsValidation() {
        repeat(10) { sample(1_100L + it, 4_800, 10_800, stampMs = 1_100) }
        assertEquals("warming_up", clock.source)
    }

    @Test fun missingTimestampsUseTheHeadAfterABoundedStartupWait() {
        assertEquals(0, sample(1_100, null, 4_800))
        assertEquals(10_560, sample(1_300, null, 14_400))
        assertEquals("playback_head", clock.source)
        assertEquals("timestamp_unavailable", clock.fallbackReason)
    }

    @Test fun frozenTimestampFallsBackWithItsMeasuredLatency() {
        establishTimestamp()
        val result = sample(1_700, 6_720, 39_600, stampMs = 1_140)
        assertEquals("playback_head", clock.source)
        assertEquals("stalled_timestamp", clock.fallbackReason)
        assertEquals(33_600, result)
        assertEquals(125_000, clock.latencyUs)
        sample(1_720, 34_560, 40_560)
        assertEquals("playback_head", clock.source)
    }

    @Test fun aSlowStartingDriverCanEstablishItsTimestampAfterPriming() {
        sample(1_300, null, 14_400)
        assertEquals("playback_head", clock.source)
        sample(1_400, 19_200, 25_200)
        sample(1_420, 20_160, 26_160)
        assertEquals(21_120, sample(1_440, 21_120, 27_120))
        assertEquals("timestamp", clock.source)
        assertEquals(null, clock.fallbackReason)
    }

    @Test fun unavailableTimestampsAreNotPolledForever() {
        sample(3_000, null, 96_000)
        assertEquals(false, clock.canPollTimestamp)
    }

    @Test fun backwardTimestampCannotPoisonThePlaybackPosition() {
        establishTimestamp()
        val result = sample(1_160, 5_760, 13_680, stampMs = 1_120)
        assertEquals("playback_head", clock.source)
        assertEquals("inconsistent_timestamp", clock.fallbackReason)
        assertEquals(7_680, result)
    }

    @Test fun aTimestampWithTheWrongRateIsRejected() {
        establishTimestamp()
        sample(1_160, 15_000, 20_000)
        assertEquals("inconsistent_timestamp", clock.fallbackReason)
    }

    @Test fun timestampsFromThePreviousStreamAreIgnored() {
        sample(1_100, 48_000, 5_000, stampMs = 900)
        sample(1_120, 48_960, 6_000, stampMs = 920)
        sample(1_140, 49_920, 7_000, stampMs = 940)
        assertEquals("warming_up", clock.source)
    }

    @Test fun extrapolationNeverReportsUnwrittenAudio() {
        establishTimestamp()
        val position = clock.position(1_150_000_000, 7_000, 7_000, 48_000, null, null)
        assertEquals(7_000, position)
    }

    @Test fun aFutureTimestampFromADelayReportValidates() {
        sample(1_100, 12_480, 18_480, stampMs = 1_300)
        sample(1_120, 13_440, 19_440, stampMs = 1_320)
        assertEquals(4_800, sample(1_140, 14_400, 20_400, stampMs = 1_340))
        assertEquals("timestamp", clock.source)
    }

    @Test fun aTimestampTooFarInTheFutureIsIgnored() {
        sample(1_100, 4_800, 10_800, stampMs = 2_200)
        sample(1_120, 5_760, 11_760, stampMs = 2_220)
        sample(1_140, 6_720, 12_720, stampMs = 2_240)
        assertEquals("warming_up", clock.source)
    }

    @Test fun bluetoothTimestampsPlaySmoothlyThroughTheStackCatchingUp() {
        clock.bluetooth = true
        val steps = a2dpSteps(seconds = 20)
        assertEquals("timestamp", clock.source)
        // At most one adjustment while the first catch-up shows where the
        // zigzag's edge is, then nothing the sync engine would correct.
        assertTrue(steps.count { abs(it) > 48 } <= 1)
        assertTrue(steps.drop(150).all { abs(it) <= 48 })
    }

    @Test fun aSteppingTimestampStillFallsBackOffBluetooth() {
        a2dpSteps(seconds = 5)
        assertEquals("playback_head", clock.source)
        assertEquals("inconsistent_timestamp", clock.fallbackReason)
    }

    @Test fun aSingleBluetoothOutlierKeepsTheLine() {
        clock.bluetooth = true
        establishTimestamp()
        assertEquals(7_680, sample(1_160, 9_600, 13_680))
        assertEquals(8_640, sample(1_180, 8_640, 14_640))
        assertEquals("timestamp", clock.source)
        assertEquals(1, clock.outliers)
        assertEquals(0, clock.moves)
    }

    @Test fun aBluetoothLineThatMovesIsFollowed() {
        clock.bluetooth = true
        establishTimestamp()
        sample(1_160, 10_560, 13_680)
        sample(1_180, 11_520, 14_640)
        assertEquals(12_480, sample(1_200, 12_480, 15_600))
        assertEquals("timestamp", clock.source)
        assertEquals(1, clock.moves)
        assertEquals(60_000, clock.lastMoveUs)
    }

    @Test fun bluetoothOutliersThatNeverAgreeEndInAStall() {
        clock.bluetooth = true
        establishTimestamp()
        for (i in 1..40) sample(1_140L + i * 20, 16_320L + i * 960 + (i % 2) * 4_800, 13_680)
        assertEquals("playback_head", clock.source)
        assertEquals("stalled_timestamp", clock.fallbackReason)
    }

    @Test fun aNewOutputDeviceRevalidatesOnTheHead() {
        establishTimestamp()
        clock.rerouted(1_500_000_000, 240_000)
        assertEquals("playback_head", clock.source)
        assertEquals("route_changed", clock.fallbackReason)
        assertEquals(24_000 - 11_520, sample(1_500, null, 24_000))
        sample(3_000, null, 96_000)
        assertEquals(true, clock.canPollTimestamp)
        sample(3_100, 85_000, 100_800)
        sample(3_120, 85_960, 101_760)
        sample(3_140, 86_920, 102_720)
        assertEquals("timestamp", clock.source)
    }

    @Test fun aRouteChangeWhileWarmingUpKeepsTheStartupWait() {
        clock.rerouted(1_200_000_000, 240_000)
        sample(1_300, null, 14_400)
        assertEquals("playback_head", clock.source)
        assertEquals("timestamp_unavailable", clock.fallbackReason)
    }

    /**
     * Plays a 48 kHz track to an A2DP stack as measured on an Echo Dot: AAC
     * at 44.1 kHz sends 1,024 samples per 23 ms tick, skips a tick whenever
     * it is a packet ahead and stamps each packet with a 200 ms delay report.
     * The stream takes 900 ms to start. Returns how far each 20 ms poll
     * strayed from the time that passed, in frames, once the music plays.
     */
    private fun a2dpSteps(seconds: Int): List<Long> {
        val packetFrames = 1_024.0 * 48_000 / 44_100
        val firstTickNs = 1_900_000_000L
        val tickNs = 23_000_000L
        val stamps = mutableListOf<Pair<Long, Long>>()
        var packets = 0
        var tickAt = firstTickNs
        val endNs = 1_000_000_000L + seconds * 1_000_000_000L
        while (tickAt < endNs) {
            val dueFrames = (tickAt - firstTickNs + tickNs) * 48_000 / 1_000_000_000.0
            if (packets * packetFrames <= dueFrames) {
                packets++
                stamps += tickAt to (packets * packetFrames).toLong()
            }
            tickAt += tickNs
        }
        val steps = mutableListOf<Long>()
        var previous: Long? = null
        var nowNs = 1_000_000_000L
        var next = 0
        while (nowNs < endNs) {
            while (next < stamps.size && stamps[next].first <= nowNs) next++
            val stamp = stamps.getOrNull(next - 1)
            val presented = stamp?.second
            val head = ((nowNs - firstTickNs).coerceAtLeast(0) * 48_000 / 1_000_000_000L) + 11_520
            val position = clock.position(
                nowNs, head, head + 24_000, 48_000, presented, stamp?.first?.plus(200_000_000L),
            )
            // Nothing reaches the headset until the delay report has passed.
            if (clock.source == "timestamp" && position > 0) {
                previous?.let { steps += position - it - 960 }
                previous = position
            }
            nowNs += 20_000_000L
        }
        return steps
    }

    @Test fun resetRevalidatesTheNewStream() {
        establishTimestamp()
        clock.reset(2_000_000_000, 112_000)
        assertEquals("warming_up", clock.source)
        assertEquals(0, sample(2_050, null, 0))
        assertTrue(clock.fallbackReason == null)
    }
}
