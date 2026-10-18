package me.jxl.kiosk_satellite.airplay

/**
 * Apple Lossless (ALAC) decoding for the AirPlay receiver, 16-bit mono or
 * stereo, which is everything an AirPlay sender streams.
 *
 * A frame is a run of elements, each a 3-bit tag: a single channel (0),
 * a channel pair (1) or the end (7). An element holds either verbatim
 * samples or, compressed, per channel an adaptive Golomb-Rice coded
 * residual run through an adaptive linear predictor, the pair then
 * mixed back from its mid and side. The parameters come from the
 * stream's format line (the ANNOUNCE's `a=fmtp`): [frameLength] samples
 * a frame, the Rice coder's [historyMult], [initialHistory] and
 * [riceLimit].
 *
 * Checked against frames from ffmpeg's encoder (AlacDecoderTest).
 */
class AlacDecoder(
    private val frameLength: Int = 352,
    private val sampleSize: Int = 16,
    private val historyMult: Int = 40,
    private val initialHistory: Int = 10,
    private val riceLimit: Int = 14,
    val channels: Int = 2,
) {
    class AlacException(message: String) : Exception(message)

    private val residual = Array(2) { IntArray(frameLength) }
    private val decoded = Array(2) { IntArray(frameLength) }
    private val extraBits = Array(2) { IntArray(frameLength) }
    private val coefs = Array(2) { IntArray(32) }

    init {
        require(sampleSize == 16) { "only 16-bit ALAC is supported" }
        require(channels in 1..2) { "only mono or stereo ALAC is supported" }
    }

    /**
     * Decode one frame of [length] bytes at [offset] into [out] as
     * interleaved samples. Returns the number of sample frames written.
     */
    fun decode(input: ByteArray, offset: Int, length: Int, out: ShortArray): Int {
        val bits = BitReader(input, offset, length)
        var channel = 0
        var frames = 0
        while (bits.left() >= 3) {
            val tag = bits.read(3)
            if (tag == TAG_END) break
            val pair = when (tag) {
                TAG_SCE -> false
                TAG_CPE -> true
                else -> throw AlacException("unsupported element $tag")
            }
            val count = if (pair) 2 else 1
            if (channel + count > channels) throw AlacException("more channels than configured")
            frames = decodeElement(bits, count, channel, out)
            channel += count
        }
        if (channel == 0) throw AlacException("no audio element")
        return frames
    }

    private fun decodeElement(bits: BitReader, count: Int, first: Int, out: ShortArray): Int {
        bits.skip(4) // element instance tag
        bits.skip(12) // unused
        val hasSize = bits.read(1) == 1
        val extra = bits.read(2) shl 3
        val compressed = bits.read(1) == 0
        val samples = if (hasSize) bits.readLong(32).toInt() else frameLength
        if (samples <= 0 || samples > frameLength) throw AlacException("bad frame size $samples")
        // The side channel of a pair carries one bit more than its samples.
        val bps = sampleSize - extra + count - 1
        var mixBits = 0
        var mixRes = 0
        var usedExtra = extra
        if (compressed) {
            mixBits = bits.read(8)
            mixRes = bits.read(8)
            val mode = IntArray(count)
            val quant = IntArray(count)
            val pbFactor = IntArray(count)
            val order = IntArray(count)
            for (ch in 0 until count) {
                mode[ch] = bits.read(4)
                quant[ch] = bits.read(4)
                pbFactor[ch] = bits.read(3)
                order[ch] = bits.read(5)
                if (quant[ch] == 0 || order[ch] >= frameLength) {
                    throw AlacException("bad predictor")
                }
                // Stored newest tap first, kept here oldest first.
                for (i in order[ch] - 1 downTo 0) coefs[ch][i] = bits.readSigned(16)
            }
            if (extra != 0) {
                for (i in 0 until samples) {
                    for (ch in 0 until count) extraBits[ch][i] = bits.read(extra)
                }
            }
            for (ch in 0 until count) {
                rice(bits, residual[ch], samples, bps, pbFactor[ch] * historyMult / 4)
                if (mode[ch] == 15) {
                    // Two passes: a first-order one, then the coded filter.
                    predict(residual[ch], residual[ch], samples, bps, null, 31, 0)
                } else if (mode[ch] != 0) {
                    throw AlacException("unknown prediction mode ${mode[ch]}")
                }
                predict(residual[ch], decoded[ch], samples, bps, coefs[ch], order[ch], quant[ch])
            }
        } else {
            for (i in 0 until samples) {
                for (ch in 0 until count) decoded[ch][i] = bits.readSigned(sampleSize)
            }
            usedExtra = 0
        }
        if (count == 2 && mixRes != 0) {
            val left = decoded[0]
            val right = decoded[1]
            for (i in 0 until samples) {
                val a = left[i] - ((right[i] * mixRes) shr mixBits)
                val b = a + right[i]
                left[i] = b
                right[i] = a
            }
        }
        if (usedExtra != 0) {
            for (ch in 0 until count) {
                val d = decoded[ch]
                val e = extraBits[ch]
                for (i in 0 until samples) d[i] = (d[i] shl usedExtra) or e[i]
            }
        }
        val stride = channels
        for (ch in 0 until count) {
            val d = decoded[ch]
            var o = first + ch
            for (i in 0 until samples) {
                out[o] = d[i].coerceIn(-32768, 32767).toShort()
                o += stride
            }
        }
        // A mono element in a stereo stream plays on both sides.
        if (count == 1 && channels == 2 && first == 0) {
            for (i in 0 until samples) out[i * 2 + 1] = out[i * 2]
        }
        return samples
    }

    /** The adaptive Golomb-Rice residuals, with runs of zeros. */
    private fun rice(bits: BitReader, output: IntArray, samples: Int, bps: Int, mult: Int) {
        var history = initialHistory
        var signModifier = 0
        var i = 0
        while (i < samples) {
            if (bits.left() <= 0) throw AlacException("residuals ran out")
            var k = log2((history ushr 9) + 3)
            if (k > riceLimit) k = riceLimit
            var x = scalar(bits, k, bps) + signModifier
            signModifier = 0
            output[i] = (x ushr 1) xor -(x and 1)
            history = if (x > 0xffff) 0xffff else history + x * mult - ((history * mult) ushr 9)
            if (history < 128 && i + 1 < samples) {
                k = 7 - log2(history) + ((history + 16) ushr 6)
                if (k > riceLimit) k = riceLimit
                var block = scalar(bits, k, 16)
                if (block > 0) {
                    if (block >= samples - i) block = samples - i - 1
                    java.util.Arrays.fill(output, i + 1, i + 1 + block, 0)
                    i += block
                }
                if (block <= 0xffff) signModifier = 1
                history = 0
            }
            i++
        }
    }

    /** One Rice-coded value with parameter [k], or an escaped raw one. */
    private fun scalar(bits: BitReader, k: Int, bps: Int): Int {
        var x = 0
        while (x < 9 && bits.read(1) == 1) x++
        if (x > 8) return bits.readLong(bps).toInt()
        if (k != 1) {
            val extra = bits.peek(k)
            x = (x shl k) - x
            if (extra > 1) {
                x += extra - 1
                bits.skip(k)
            } else {
                bits.skip(k - 1)
            }
        }
        return x
    }

    /**
     * The adaptive predictor: [coefs] are the taps oldest first, [order]
     * 31 is a plain first-order difference. Writes [output], which may be
     * [error] itself.
     */
    private fun predict(
        error: IntArray,
        output: IntArray,
        samples: Int,
        bps: Int,
        coefs: IntArray?,
        order: Int,
        quant: Int,
    ) {
        output[0] = error[0]
        if (samples <= 1) return
        if (order == 0) {
            System.arraycopy(error, 1, output, 1, samples - 1)
            return
        }
        if (order == 31) {
            for (i in 1 until samples) output[i] = signExtend(output[i - 1] + error[i], bps)
            return
        }
        val c = coefs!!
        var i = 1
        while (i <= order && i < samples) {
            output[i] = signExtend(output[i - 1] + error[i], bps)
            i++
        }
        val round = 1 shl (quant - 1)
        while (i < samples) {
            val base = i - order
            val d = output[base - 1]
            // 32-bit wrapping sums, as the encoder computes them.
            var sum = 0
            for (j in 0 until order) sum += (output[base + j] - d) * c[j]
            var errorValue = error[i]
            output[i] = signExtend(((sum.toLong() + round) shr quant).toInt() + d + errorValue, bps)
            val sign = Integer.signum(errorValue)
            if (sign != 0) {
                var j = 0
                while (j < order && errorValue * sign > 0) {
                    val diff = d - output[base + j]
                    val s = Integer.signum(diff) * sign
                    c[j] -= s
                    errorValue -= ((diff * s) shr quant) * (j + 1)
                    j++
                }
            }
            i++
        }
    }

    private fun signExtend(v: Int, bits: Int): Int {
        val shift = 32 - bits
        return (v shl shift) shr shift
    }

    private fun log2(v: Int): Int = if (v <= 0) 0 else 31 - Integer.numberOfLeadingZeros(v)

    private class BitReader(private val buf: ByteArray, offset: Int, length: Int) {
        private var pos = offset.toLong() * 8
        private val end = (offset.toLong() + length) * 8

        fun left(): Long = end - pos

        fun read(n: Int): Int = readLong(n).toInt()

        fun readLong(n: Int): Long {
            val v = peekLong(n)
            pos += n
            return v
        }

        fun readSigned(n: Int): Int {
            val v = read(n)
            val shift = 32 - n
            return (v shl shift) shr shift
        }

        fun peek(n: Int): Int = peekLong(n).toInt()

        fun skip(n: Int) {
            pos += n
        }

        private fun peekLong(n: Int): Long {
            if (n == 0) return 0
            if (pos + n > end) throw AlacException("frame ended early")
            var v = 0L
            var p = pos
            var remaining = n
            while (remaining > 0) {
                val byte = buf[(p ushr 3).toInt()].toInt() and 0xFF
                val bitInByte = (p and 7).toInt()
                val take = minOf(8 - bitInByte, remaining)
                val bitsHere = (byte ushr (8 - bitInByte - take)) and ((1 shl take) - 1)
                v = (v shl take) or bitsHere.toLong()
                p += take
                remaining -= take
            }
            return v
        }
    }

    private companion object {
        const val TAG_SCE = 0
        const val TAG_CPE = 1
        const val TAG_END = 7
    }
}
