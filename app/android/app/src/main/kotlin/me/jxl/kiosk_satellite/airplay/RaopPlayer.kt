package me.jxl.kiosk_satellite.airplay

import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import me.jxl.kiosk_satellite.sendspin.NativeAudioOutput

/**
 * Plays one AirPlay stream on time. Each packet has a moment it should
 * come out of the speaker (its RTP time on the sender's clock, through
 * [RaopStream.localTimeOf]). The player compares that with when the next
 * frame it writes will actually be heard, from the output's presentation
 * clock, and closes the gap:
 *
 *  - Early by more than [WINDOW_NS]: silence until the packet is due,
 *    which is how a stream starts its two seconds behind the sender.
 *  - Late by more than that: frames dropped until caught up, after a
 *    stall or a long resend.
 *  - Inside the window: the packet plays, one frame longer or shorter
 *    while the error is past [STUFF_NS], which follows the drift between
 *    the two clocks without being heard.
 *
 * A packet that never arrived plays as silence in its slot. The output is
 * Sendspin's [NativeAudioOutput]: the same AudioTrack handling, soft
 * start, gain stages and echo canceller tap.
 */
internal class RaopPlayer(
    private val stream: RaopStream,
    private val format: StreamFormat,
    private val onPlaying: (Boolean) -> Unit,
    /** The sync offset in force: negative plays earlier. */
    private val offsetNs: () -> Long = { 0L },
) {
    private val output = NativeAudioOutput()
    private val rate = format.sampleRate
    private val framesPerPacket = format.framesPerPacket
    private val bytes = ByteBuffer.allocateDirect((framesPerPacket + 1) * 4).order(ByteOrder.LITTLE_ENDIAN)
    private val silence = ByteBuffer.allocateDirect(SILENCE_FRAMES * 4).order(ByteOrder.LITTLE_ENDIAN)
    private val scratch = ShortArray((framesPerPacket + 1) * 2)

    @Volatile private var running = false
    @Volatile private var flushWanted = false
    private var thread: Thread? = null
    private var playing = false
    private var presented = 0L
    private var presentedAtNs = 0L
    private var waitingSince = 0L

    // Diagnostics for airplayStatus: how far off the last packet was and
    // what it took to keep on time.
    @Volatile private var lastErrorUs = 0L
    @Volatile private var silenceFrames = 0L
    @Volatile private var droppedFrames = 0L
    @Volatile private var stuffedFrames = 0L
    @Volatile private var missingPackets = 0L

    fun start() {
        running = true
        thread = Thread(::loop, "airplay-player").apply {
            priority = Thread.MAX_PRIORITY
            isDaemon = true
            start()
        }
    }

    fun stop() {
        running = false
        thread?.interrupt()
        runCatching { thread?.join(1000) }
        output.release()
        setPlaying(false)
    }

    /** The stream was flushed: drop what is queued on the output too. */
    fun flush() {
        flushWanted = true
    }

    /** How the playout is keeping time, for diagnostics. */
    fun stats(): Map<String, Any?> = mapOf(
        "playing" to playing,
        "bufferedPackets" to stream.buffer.buffered(),
        "latencyMs" to stream.latencyFrames * 1000 / rate,
        "clockSynced" to (stream.clock.offsetNs != null),
        "anchored" to (stream.anchor != null),
        "syncErrorMs" to lastErrorUs / 1000.0,
        "silenceMs" to silenceFrames * 1000 / rate,
        "droppedMs" to droppedFrames * 1000 / rate,
        "stuffedFrames" to stuffedFrames,
        "missingPackets" to missingPackets,
        "droppedAsStale" to stream.buffer.droppedAsStale,
        "lastFlushRtp" to stream.buffer.lastFlushRtp,
        "headRtp" to stream.buffer.headRtp(),
        "outputQueueMs" to output.outputQueueMs(),
        "underruns" to output.underrunCount(),
        "sinkLatencyMs" to output.sinkLatencyMs(),
    )

    fun setGains(media: Float, duck: Float) {
        output.setMediaGain(media)
        output.setDuckGain(duck)
    }

    private fun loop() {
        try {
            while (running) {
                if (flushWanted) {
                    flushWanted = false
                    stopOutput()
                    continue
                }
                step()
            }
        } catch (_: InterruptedException) {
        } catch (e: Exception) {
            Log.e(TAG, "player stopped", e)
        } finally {
            output.release()
        }
    }

    private fun step() {
        val now = System.nanoTime()
        val head = stream.buffer.headRtp()
        if (head == null) {
            if (!output.isStarted) {
                Thread.sleep(5)
                return
            }
            // Starved. A short gap keeps the clock running on silence and
            // catches up when packets return. A long one is a pause.
            if (now - stream.buffer.lastArrivalNs > IDLE_NS) {
                stopOutput()
            } else {
                writeSilence(rate / 100)
            }
            return
        }
        val target = stream.localTimeOf(head)?.plus(offsetNs())
        if (target == null) {
            // No sync packet yet. Every sender sends one at the start. If
            // none comes, play the usual latency after the first packet.
            if (waitingSince == 0L) waitingSince = now
            if (now - waitingSince > ANCHOR_WAIT_NS) {
                stream.assumeAnchor(head, waitingSince + stream.latencyFrames * 1_000_000_000L / rate)
            }
            Thread.sleep(5)
            return
        }
        waitingSince = 0L
        if (!output.isStarted && !startOutput()) {
            // No output to be had: keep the buffer moving rather than fill it.
            stream.buffer.read(framesPerPacket)
            Thread.sleep(framesPerPacket * 1000L / rate)
            return
        }
        val error = presentationOfNextWrite(now) - target
        lastErrorUs = error / 1000
        when {
            error < -WINDOW_NS -> {
                val frames = minOf(nsToFrames(-error), SILENCE_FRAMES.toLong()).toInt()
                silenceFrames += frames
                writeSilence(frames)
            }
            error > WINDOW_NS -> {
                val packet = stream.buffer.read(framesPerPacket)
                val frames = packet?.frames ?: framesPerPacket
                val drop = nsToFrames(error)
                droppedFrames += minOf(drop, frames.toLong())
                if (packet == null) missingPackets++
                if (drop < frames && packet != null) {
                    writePcm(packet.pcm, drop.toInt(), frames - drop.toInt())
                    setPlaying(true)
                }
            }
            else -> {
                val packet = stream.buffer.read(framesPerPacket)
                if (packet == null) {
                    missingPackets++
                    writeSilence(framesPerPacket)
                    return
                }
                var frames = packet.frames
                val pcm = packet.pcm
                if (error > STUFF_NS && frames > 1) {
                    stuffedFrames--
                    frames -= 1
                    writePcm(pcm, 0, frames)
                } else if (error < -STUFF_NS) {
                    stuffedFrames++
                    System.arraycopy(pcm, 0, scratch, 0, frames * 2)
                    scratch[frames * 2] = pcm[frames * 2 - 2]
                    scratch[frames * 2 + 1] = pcm[frames * 2 - 1]
                    writePcm(scratch, 0, frames + 1)
                } else {
                    writePcm(pcm, 0, frames)
                }
                setPlaying(true)
            }
        }
    }

    /** When the next frame written will be heard, on the monotonic clock. */
    private fun presentationOfNextWrite(now: Long): Long {
        output.takePresentedFramesDelta()?.let {
            presented += it.frames
            presentedAtNs = it.sampledAtUs * 1000
        }
        val written = output.totalFramesWritten()
        if (presentedAtNs == 0L) return now + output.outputQueueMs() * 1_000_000L
        return presentedAtNs + (written - presented) * 1_000_000_000L / rate
    }

    private fun startOutput(): Boolean {
        presented = 0
        presentedAtNs = 0
        val ok = output.start(rate, 2, 16)
        if (!ok) Log.w(TAG, "no audio output")
        return ok
    }

    private fun stopOutput() {
        if (output.isStarted) output.pause()
        presented = 0
        presentedAtNs = 0
        setPlaying(false)
    }

    private fun writePcm(pcm: ShortArray, from: Int, frames: Int) {
        if (frames <= 0) return
        bytes.clear()
        bytes.asShortBuffer().put(pcm, from * 2, frames * 2)
        drain(bytes, frames * 4)
    }

    private fun writeSilence(frames: Int) {
        if (frames <= 0) return
        silence.clear()
        drain(silence, frames * 4)
    }

    private fun drain(buffer: ByteBuffer, length: Int) {
        buffer.position(0)
        buffer.limit(length)
        while (running && !flushWanted && buffer.position() < length && output.isStarted) {
            val n = output.write(buffer, length - buffer.position(), WRITE_TIMEOUT_MS)
            if (n <= 0 && !output.isStarted) break
        }
    }

    private fun setPlaying(value: Boolean) {
        if (playing == value) return
        playing = value
        onPlaying(value)
    }

    private fun nsToFrames(ns: Long): Long = ns * rate / 1_000_000_000L

    private companion object {
        const val TAG = "AirPlay"
        const val WINDOW_NS = 25_000_000L
        const val STUFF_NS = 3_000_000L
        const val IDLE_NS = 1_500_000_000L
        const val ANCHOR_WAIT_NS = 1_000_000_000L
        const val SILENCE_FRAMES = 1764 // 40 ms at 44.1 kHz
        const val WRITE_TIMEOUT_MS = 100
    }
}
