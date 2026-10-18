package me.jxl.kiosk_satellite.airplay

import java.io.DataInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Frames from ffmpeg's ALAC encoder (tool/generate_alac_vectors.py)
 * decode to the signal they were made from, bit for bit: a tonal stretch,
 * digital silence (the zero runs), full-scale noise the encoder may store
 * verbatim and a short last frame that carries its own size.
 */
class AlacDecoderTest {
    @Test
    fun decodesFfmpegFramesBitExact() = check("alac_default.bin")

    @Test
    fun decodesHighOrderPredictorsBitExact() = check("alac_order30.bin")

    @Test
    fun decodesVerbatimFrame() {
        // A pair element, uncompressed: tag 1, instance 0, 12 unused bits,
        // no size, no extra bits, verbatim. Then two frames of L and R.
        val bits = StringBuilder()
        bits.append("001").append("0000").append("0".repeat(12)).append("0").append("00").append("1")
        for (s in intArrayOf(1000, -1000, 32767, -32768)) {
            bits.append(Integer.toBinaryString(s and 0xFFFF).padStart(16, '0'))
        }
        bits.append("111")
        while (bits.length % 8 != 0) bits.append('0')
        val bytes = ByteArray(bits.length / 8) { i ->
            bits.substring(i * 8, i * 8 + 8).toInt(2).toByte()
        }
        val decoder = AlacDecoder(frameLength = 2)
        val out = ShortArray(4)
        assertEquals(2, decoder.decode(bytes, 0, bytes.size, out))
        assertEquals(listOf<Short>(1000, -1000, 32767, -32768), out.toList())
    }

    private fun check(name: String) {
        val expected = signal()
        val packets = packets(name)
        val decoder = AlacDecoder(frameLength = 4096)
        val out = ShortArray(4096 * 2)
        var frame = 0
        for (p in packets) {
            val n = decoder.decode(p, 0, p.size, out)
            for (i in 0 until n * 2) {
                assertEquals("sample ${frame * 2 + i}", expected[frame * 2 + i], out[i])
            }
            frame += n
        }
        assertEquals(FRAMES, frame)
        assertTrue(packets.size > 1)
    }

    private fun packets(name: String): List<ByteArray> {
        val stream = javaClass.classLoader!!.getResourceAsStream("airplay/$name")!!
        DataInputStream(stream).use { input ->
            val magic = ByteArray(4).also { input.readFully(it) }
            assertEquals("ALAC", String(magic))
            return List(input.readInt()) { ByteArray(input.readInt()).also { input.readFully(it) } }
        }
    }

    /** The generator's signal, integer for integer. */
    private fun signal(): ShortArray {
        fun tri(n: Int, period: Int, amp: Int): Int {
            val p = n % period
            val half = period / 2
            val v = if (p < half) p else period - p
            return Math.floorDiv(v * 2 * amp, half) - amp
        }
        fun clamp(v: Int) = v.coerceIn(-32768, 32767).toShort()
        val out = ShortArray(FRAMES * 2)
        var seed = 12345L
        for (n in 0 until FRAMES) {
            seed = (seed * 1103515245 + 12345) and 0x7fffffff
            val noise = ((seed shr 16) % 2001).toInt() - 1000
            val l: Int
            val r: Int
            when {
                n < 8820 -> {
                    l = tri(n, 100, 9000) + Math.floorDiv(noise, 4)
                    r = tri(n, 77, 7000) - Math.floorDiv(noise, 8) + Math.floorDiv(l, 3)
                }
                n < 13230 -> {
                    l = 0
                    r = 0
                }
                else -> {
                    l = noise * 30
                    r = -l + noise
                }
            }
            out[n * 2] = clamp(l)
            out[n * 2 + 1] = clamp(r)
        }
        return out
    }

    private companion object {
        const val FRAMES = 17640
    }
}
