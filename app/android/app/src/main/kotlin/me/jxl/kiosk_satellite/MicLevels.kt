package me.jxl.kiosk_satellite

/**
 * How loud each recent 10 ms of the microphone was, for wake word
 * arbitration (Dart's wakeEnergy), measured before the noise suppressor
 * and the residual echo gate. Both push the quiet between words toward
 * silence, so a kiosk running them would claim a wake word far louder over
 * its floor than one that does not, wherever the speaker stands. The echo
 * canceller has already run, so what the kiosk itself plays does not count.
 *
 * Fed by [SoftwareEcho] while it processes the capture and by [MicRecorder]
 * otherwise, read over `kiosk_satellite/mic_levels`.
 */
object MicLevels {
    /** 10 ms of 16 kHz mono PCM16. */
    private const val FRAME = 160

    /** Three seconds, the most wakeEnergy reads. */
    private const val SIZE = 300

    private val squares = DoubleArray(SIZE)
    private val times = LongArray(SIZE)
    private var next = 0
    private var count = 0

    /** The capture gain in dB, applied after this measures. */
    @Volatile var gainDb = 0.0

    /** Mean square of the 10 ms frame at [at] in [pcm], full scale 1. */
    fun meanSquare(pcm: ByteArray, at: Int): Double {
        var sum = 0.0
        for (i in 0 until FRAME) {
            val v = (pcm[at + i * 2].toInt() and 0xFF) or (pcm[at + i * 2 + 1].toInt() shl 8)
            val s = v.toShort() / 32768.0
            sum += s * s
        }
        return sum / FRAME
    }

    /** Record each whole frame of [pcm] as it is now. */
    fun measure(pcm: ByteArray) {
        val frames = pcm.size / (FRAME * 2)
        val now = System.nanoTime()
        synchronized(this) {
            for (f in 0 until frames) put(meanSquare(pcm, f * FRAME * 2), now)
        }
    }

    /** Record [frames] mean squares measured elsewhere. */
    fun add(levels: DoubleArray, frames: Int) {
        val now = System.nanoTime()
        synchronized(this) {
            for (f in 0 until frames) put(levels[f], now)
        }
    }

    private fun put(square: Double, now: Long) {
        squares[next] = square
        times[next] = now
        next = (next + 1) % SIZE
        if (count < SIZE) count++
    }

    /**
     * The last [ms] of levels, oldest first, in dBFS per 20 ms (the frame
     * wakeEnergy works in), with the capture gain applied. Empty when the
     * microphone has not delivered that recently.
     */
    fun recent(ms: Int): DoubleArray {
        val since = System.nanoTime() - ms * 1_000_000L
        val picked = ArrayList<Double>()
        synchronized(this) {
            for (i in 0 until count) {
                val at = (next - count + i + SIZE) % SIZE
                if (times[at] >= since) picked.add(squares[at])
            }
        }
        val out = DoubleArray(picked.size / 2)
        for (i in out.indices) {
            val square = (picked[i * 2] + picked[i * 2 + 1]) / 2
            out[i] = if (square > 0) 10 * Math.log10(square) + gainDb else -120.0
        }
        return out
    }

    fun clear() {
        synchronized(this) {
            next = 0
            count = 0
        }
    }
}
