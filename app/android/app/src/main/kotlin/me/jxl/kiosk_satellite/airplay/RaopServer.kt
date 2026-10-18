package me.jxl.kiosk_satellite.airplay

import android.util.Base64
import android.util.Log
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import kotlin.math.max

/**
 * What a session tells whoever shows it. Called from the server's
 * threads, and the bridge moves it to the main thread.
 */
internal interface RaopListener {
    /** A sender connected ([client] is its name) or left (null). */
    fun onSession(client: String?)
    fun onPlaying(playing: Boolean)
    /** The track, with the RTP time the sender stamped it with, if any. */
    fun onMetadata(title: String, artist: String, album: String, rtp: Long?)
    /** Cover art bytes, empty for a track without. */
    fun onArtwork(bytes: ByteArray, rtp: Long?)
    /** The track's start, the sender's now and its end, as RTP times. */
    fun onProgress(start: Long, current: Long, end: Long)
    /** The sender's volume, 0 to 1 on the receiver's taper. */
    fun onVolume(gain: Float)
    fun onRemote(available: Boolean)

    /**
     * The sender's shuffle and repeat as its remote control reports them:
     * shuffle on, repeat 0 (off), 1 (one) or 2 (all), and whether the
     * sender offers each for what plays.
     */
    fun onRemoteState(shuffle: Boolean, repeat: Int, shuffleOffered: Boolean, repeatOffered: Boolean)
}

/**
 * The AirPlay 1 (RAOP) receiver: an RTSP server that takes one sender at
 * a time. A sender that connects while another plays takes over, the way
 * picking a speaker on a second phone does on any AirPlay speaker.
 *
 * The exchange, as an iPhone runs it:
 *
 *  - OPTIONS with an Apple-Challenge, answered by
 *    [RaopCrypto.challengeResponse].
 *  - ANNOUNCE with the stream format and its wrapped AES key.
 *  - SETUP, which binds the three UDP ports ([RaopStream]).
 *  - RECORD, and audio flows.
 *  - SET_PARAMETER for the volume, the track (DMAP), its cover and its
 *    progress.
 *  - FLUSH on pause or skip.
 *  - TEARDOWN at the end, or just a closed connection.
 */
internal class RaopServer(
    private val deviceId: ByteArray,
    private val listener: RaopListener,
    private val lookupDacp: (dacpId: String, found: (Int) -> Unit) -> Unit,
) {
    @Volatile private var server: ServerSocket? = null
    @Volatile private var running = false
    private val lock = Any()
    /** The connection whose session is the live one. */
    private var current: Connection? = null

    @Volatile var mediaGain = 1f
        set(value) {
            field = value
            applyGains()
        }
    @Volatile var duckGain = 1f
        set(value) {
            field = value
            applyGains()
        }

    /** Whether the sender's volume control scales the audio. */
    @Volatile var senderVolume = true
        set(value) {
            field = value
            applyGains()
        }

    /** Moves the playout against the sender's clock; negative plays earlier. */
    @Volatile var offsetNs = 0L

    /** Whether a second sender may take the speaker from one that plays. */
    @Volatile var takeover = true

    val port: Int get() = server?.localPort ?: 0

    /** Bind to the first free port from 5000 up, any port failing that. */
    fun start(): Int {
        if (running) return port
        val socket = (5000..5009).firstNotNullOfOrNull { p ->
            runCatching { ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(p)) } }.getOrNull()
        } ?: ServerSocket(0)
        server = socket
        running = true
        Thread({ acceptLoop(socket) }, "airplay-rtsp").apply { isDaemon = true }.start()
        Log.i(TAG, "AirPlay receiver on port ${socket.localPort}")
        return socket.localPort
    }

    fun stop() {
        running = false
        runCatching { server?.close() }
        server = null
        val c = synchronized(lock) { current.also { current = null } }
        c?.close()
    }

    /** A transport command through the sender's remote control. */
    fun control(command: String): Boolean {
        val c = synchronized(lock) { current } ?: return false
        val path = when (command) {
            "play" -> "play"
            "pause" -> "pause"
            "toggle" -> "playpause"
            "next" -> "nextitem"
            "previous" -> "previtem"
            "stop" -> "stop"
            else -> return false
        }
        return c.dacp(path)
    }

    /**
     * The sender's Up Next, the songs after the current one, from its
     * remote control: title, artist, album, length and the sender's own
     * number for each. Null when it cannot say. Blocks, off the main thread.
     */
    fun queue(): List<Map<String, Any?>>? {
        val c = synchronized(lock) { current } ?: return null
        val answer = c.dacpRequest("ctrl-int/1/playqueue-contents?span=50") ?: return null
        if (answer.first != 200) return null
        return Dmap.queueItems(answer.second)
    }

    /**
     * Play the Up Next song the sender numbered [number]. The jump counts
     * from the current song (1 is the next one), one less than the number
     * the listing gives it, as a Mac's Music app takes it.
     */
    fun playQueueItem(number: Long): Boolean {
        val c = synchronized(lock) { current } ?: return false
        val index = number - 1
        if (index < 1) return false
        return c.dacp("playqueue-edit?command=playnow&index=$index")
    }

    /** Shuffle on or off through the remote control. */
    fun setShuffle(on: Boolean): Boolean {
        val c = synchronized(lock) { current } ?: return false
        return c.dacp("setproperty?dacp.shufflestate=${if (on) 1 else 0}")
    }

    /** Repeat off, one or all through the remote control. */
    fun setRepeat(mode: String): Boolean {
        val c = synchronized(lock) { current } ?: return false
        val value = when (mode) {
            "one" -> 1
            "all" -> 2
            else -> 0
        }
        return c.dacp("setproperty?dacp.repeatstate=$value")
    }

    /**
     * Jump to [positionMs] in the track, through the remote control's play
     * position property (iTunes' own, which not every sender honors). The
     * sender flushes and sends its new progress if it took it.
     */
    fun seek(positionMs: Long): Boolean {
        val c = synchronized(lock) { current } ?: return false
        return c.dacp("setproperty?dacp.playingtime=${positionMs.coerceAtLeast(0)}")
    }

    private fun applyGains() {
        val c = synchronized(lock) { current } ?: return
        c.applyGains()
    }

    /** A raw remote control request on the live session, for diagnostics. */
    fun remoteRequest(path: String, headers: Map<String, String> = emptyMap()): Pair<Int, ByteArray>? =
        synchronized(lock) { current }?.dacpRequest(path, headers = headers)

    /** The live session's playout diagnostics, null with no session. */
    fun stats(): Map<String, Any?>? = synchronized(lock) { current }?.stats()

    private fun acceptLoop(socket: ServerSocket) {
        while (running) {
            val client = try {
                socket.accept()
            } catch (e: Exception) {
                if (running) Log.w(TAG, "accept failed: $e")
                break
            }
            client.tcpNoDelay = true
            Thread({ Connection(client).serve() }, "airplay-rtsp-conn").apply { isDaemon = true }.start()
        }
    }

    private inner class Connection(private val socket: Socket) {
        private var format: StreamFormat? = null
        private var stream: RaopStream? = null
        private var player: RaopPlayer? = null
        private var client = ""
        private var dacpId: String? = null
        private var activeRemote: String? = null
        @Volatile private var dacpPort = 0
        private var volumeGain = 1f
        @Volatile private var closed = false

        fun serve() {
            val input = BufferedInputStream(socket.getInputStream())
            val output = BufferedOutputStream(socket.getOutputStream())
            try {
                while (!closed) {
                    val req = RtspRequest.read(input) ?: break
                    val res = handle(req)
                    res.write(output, req.cseq)
                    if (req.method == "TEARDOWN") break
                }
            } catch (e: Exception) {
                if (!closed) Log.i(TAG, "connection ended: $e")
            } finally {
                close()
            }
        }

        fun close() {
            if (closed) return
            closed = true
            runCatching { socket.close() }
            endSession()
        }

        /** The stream stops and, if this was the live session, it is over. */
        private fun endSession() {
            stopStream()
            val wasCurrent = synchronized(lock) {
                (current === this).also { if (it) current = null }
            }
            if (wasCurrent) listener.onSession(null)
        }

        private fun handle(req: RtspRequest): RtspResponse {
            // Debug level: what a sender asks for, and where, is the first
            // thing to know when a transport command does the wrong thing.
            Log.d(
                TAG,
                "${req.method} ${req.header("Content-Type") ?: ""} " +
                    (req.header("RTP-Info") ?: "") +
                    if (req.header("Content-Type")?.startsWith("text/parameters") == true) " ${req.text.trim()}" else "",
            )
            val res = when (req.method) {
                "OPTIONS" -> RtspResponse().header(
                    "Public",
                    "ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER",
                )
                "ANNOUNCE" -> announce(req)
                "SETUP" -> setup(req)
                "RECORD" -> record(req)
                "FLUSH" -> flush(req)
                "SET_PARAMETER" -> setParameter(req)
                "GET_PARAMETER" -> getParameter(req)
                "TEARDOWN" -> {
                    endSession()
                    RtspResponse().header("Connection", "close")
                }
                else -> RtspResponse(501)
            }
            req.header("Apple-Challenge")?.let { challenge ->
                RaopCrypto.challengeResponse(challenge, socket.localAddress, deviceId)
                    ?.let { res.header("Apple-Response", it) }
            }
            res.header("Audio-Jack-Status", "connected; type=analog")
            return res
        }

        private fun announce(req: RtspRequest): RtspResponse {
            val parsed = try {
                StreamFormat.parse(req.text, RaopCrypto::unwrapAesKey) { Base64.decode(it.trim(), Base64.DEFAULT) }
            } catch (e: Exception) {
                Log.w(TAG, "ANNOUNCE refused: $e")
                return RtspResponse(456)
            } ?: return RtspResponse(415)
            // This sender takes the speaker and whoever had it is let go,
            // unless taking over is off and someone still holds it.
            val previous = synchronized(lock) {
                val p = current
                if (p != null && p !== this && !takeover) return RtspResponse(453)
                current = this
                p
            }
            if (previous != null && previous !== this) previous.close()
            stopStream()
            format = parsed
            client = req.header("X-Apple-Client-Name")?.takeIf { it.isNotBlank() } ?: ""
            Log.i(
                TAG,
                "session from ${socket.inetAddress.hostAddress}" +
                    (if (client.isEmpty()) "" else " ($client)") +
                    if (parsed.alac) ", ALAC" else ", PCM",
            )
            listener.onSession(client)
            return RtspResponse()
        }

        private fun setup(req: RtspRequest): RtspResponse {
            val f = format ?: return RtspResponse(451)
            if (!isCurrent()) return RtspResponse(453)
            val transport = req.header("Transport") ?: return RtspResponse(451)
            fun portOf(key: String) =
                transport.substringAfter("$key=", "").takeWhile { it.isDigit() }.toIntOrNull() ?: 0
            activeRemote = req.header("Active-Remote")
            dacpId = req.header("DACP-ID")
            if (stream == null) {
                val s = RaopStream(f, socket.inetAddress, portOf("control_port"), portOf("timing_port"))
                s.start()
                stream = s
                player = RaopPlayer(s, f, listener::onPlaying, { offsetNs }).also {
                    it.setGains(mediaGain * effectiveVolume(), duckGain)
                    it.start()
                }
            }
            findRemote()
            val s = stream!!
            return RtspResponse()
                .header(
                    "Transport",
                    "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;" +
                        "control_port=${s.controlPort};timing_port=${s.timingPort};server_port=${s.audioPort}",
                )
                .header("Session", "1")
        }

        private fun record(req: RtspRequest): RtspResponse {
            val s = stream ?: return RtspResponse(451)
            rtpTimeOf(req.header("RTP-Info"))?.let { s.flush(it) }
            return RtspResponse().header("Audio-Latency", "11025")
        }

        private fun flush(req: RtspRequest): RtspResponse {
            val s = stream ?: return RtspResponse(451)
            s.flush(rtpTimeOf(req.header("RTP-Info")))
            player?.flush()
            return RtspResponse()
        }

        private fun setParameter(req: RtspRequest): RtspResponse {
            if (!isCurrent()) return RtspResponse()
            val type = req.header("Content-Type") ?: ""
            when {
                type.startsWith("text/parameters") -> parameters(req.text)
                type.startsWith("application/x-dmap-tagged") -> metadata(req.body, rtpTimeOf(req.header("RTP-Info")))
                type.startsWith("image/") -> listener.onArtwork(
                    if (type.startsWith("image/none")) ByteArray(0) else req.body,
                    rtpTimeOf(req.header("RTP-Info")),
                )
            }
            return RtspResponse()
        }

        private fun getParameter(req: RtspRequest): RtspResponse {
            val res = RtspResponse()
            if (req.text.trim() == "volume") {
                res.header("Content-Type", "text/parameters")
                res.body = "volume: %.6f\r\n".format(java.util.Locale.ROOT, gainToVolume(volumeGain))
                    .toByteArray()
            }
            return res
        }

        private fun parameters(text: String) {
            for (raw in text.split('\n')) {
                val line = raw.trim()
                when {
                    line.startsWith("volume:") -> {
                        val v = line.removePrefix("volume:").trim().toFloatOrNull() ?: continue
                        volumeGain = volumeToGain(v)
                        applyGains()
                        listener.onVolume(volumeGain)
                    }
                    line.startsWith("progress:") -> {
                        val parts = line.removePrefix("progress:").trim().split('/')
                        val n = parts.mapNotNull { it.trim().toLongOrNull() }
                        if (n.size == 3) listener.onProgress(n[0], n[1], n[2])
                    }
                }
            }
        }

        /** The DMAP listing: a container whose items are four-letter tags. */
        private fun metadata(body: ByteArray, rtp: Long?) {
            val items = Dmap.items(body)
            listener.onMetadata(items["minm"] ?: "", items["asar"] ?: "", items["asal"] ?: "", rtp)
        }

        fun applyGains() {
            player?.setGains(mediaGain * effectiveVolume(), duckGain)
        }

        private fun effectiveVolume() = if (senderVolume) volumeGain else 1f

        fun stats(): Map<String, Any?> = (player?.stats() ?: emptyMap()) + mapOf(
            "sender" to socket.inetAddress.hostAddress,
            "codec" to if (format?.alac == true) "ALAC" else "PCM",
            "encrypted" to (format?.aesKey != null),
            "volume" to volumeGain,
            "remoteControlPort" to dacpPort,
        )

        /** The sender's remote control, once its port is known. */
        fun dacp(command: String): Boolean {
            if (activeRemote == null || dacpPort <= 0) return false
            Thread({
                val answer = dacpRequest("ctrl-int/1/$command")
                Log.d(TAG, "remote $command: ${answer?.first ?: "failed"}")
                // The status it changed shows at once.
                synchronized(statusWake) { statusWake.notifyAll() }
            }, "airplay-dacp").apply { isDaemon = true }.start()
            return true
        }

        /**
         * One request to the sender's remote control, [path] after the
         * port: the status and body, or null when it could not be asked.
         * Blocks, so off the main thread.
         */
        fun dacpRequest(
            path: String,
            readTimeoutMs: Int = 4000,
            headers: Map<String, String> = emptyMap(),
        ): Pair<Int, ByteArray>? {
            val remote = activeRemote ?: return null
            val p = dacpPort
            if (p <= 0) return null
            val host = socket.inetAddress
            return runCatching {
                val address = if (host is java.net.Inet6Address) "[${host.hostAddress}]" else host.hostAddress
                val conn = URL("http://$address:$p/$path").openConnection() as HttpURLConnection
                conn.connectTimeout = 2000
                conn.readTimeout = readTimeoutMs
                conn.useCaches = false
                conn.setRequestProperty("Active-Remote", remote)
                for ((name, value) in headers) conn.setRequestProperty(name, value)
                try {
                    val code = conn.responseCode
                    val body = runCatching {
                        (if (code < 400) conn.inputStream else conn.errorStream)?.use { it.readBytes() }
                    }.getOrNull() ?: ByteArray(0)
                    code to body
                } finally {
                    conn.disconnect()
                }
            }.onFailure {
                // A status request that waited out its time is not a failure.
                if (it !is java.net.SocketTimeoutException) Log.w(TAG, "remote $path failed: $it")
            }.getOrNull()
        }

        private fun findRemote() {
            val id = dacpId ?: return
            if (activeRemote == null || dacpPort > 0) return
            lookupDacp(id) { port ->
                if (closed || !isCurrent()) return@lookupDacp
                dacpPort = port
                Log.i(TAG, "remote control at port $port")
                listener.onRemote(true)
                watchRemote()
            }
        }

        /** Wakes the status watcher early, after a command that changes the status. */
        private val statusWake = Object()

        /**
         * Follows the sender's play status for shuffle and repeat. Each
         * request names the last revision seen. The protocol lets the
         * sender hold the request until something moves past it, but a Mac
         * refuses that with 403 and only answers once the revision has
         * moved, so the watcher asks every [STATUS_POLL_MS] and right after
         * a command of its own.
         */
        private fun watchRemote() {
            Thread({
                var revision = 1L
                var backoff = 1000L
                var lastStatus = -1
                Log.d(TAG, "following the remote control's status")
                while (!closed && isCurrent()) {
                    val asked = android.os.SystemClock.elapsedRealtime()
                    val answer = dacpRequest(
                        "ctrl-int/1/playstatusupdate?revision-number=$revision",
                        readTimeoutMs = STATUS_WAIT_MS,
                    )
                    if (closed) break
                    val status = answer?.first ?: 0
                    if (status != lastStatus) {
                        Log.d(TAG, "remote status answer: ${if (status == 0) "none" else status}")
                        lastStatus = status
                    }
                    // Nothing changed for a while: ask again, no harm done.
                    if (answer == null &&
                        android.os.SystemClock.elapsedRealtime() - asked >= STATUS_WAIT_MS - 1000
                    ) {
                        continue
                    }
                    // A sender without the status says so for good: 501,
                    // or 400 from iOS, whose remote control takes play,
                    // pause, skip and volume and refuses everything else.
                    if (status == 501 || status == 400) break
                    // Nothing new since the revision named.
                    if (status == 403) {
                        backoff = 1000L
                        pause(STATUS_POLL_MS)
                        continue
                    }
                    if (status != 200) {
                        // A hiccup: try again, slower.
                        pause(backoff)
                        backoff = minOf(backoff * 2, 30_000L)
                        continue
                    }
                    backoff = 1000L
                    val values = Dmap.numbers(answer!!.second)
                    values["cmsr"]?.let { revision = it }
                    listener.onRemoteState(
                        shuffle = (values["cash"] ?: 0L) != 0L,
                        repeat = (values["carp"] ?: 0L).toInt(),
                        shuffleOffered = (values["caas"] ?: 0L) >= 2,
                        repeatOffered = (values["caar"] ?: 0L) > 1,
                    )
                }
                Log.d(TAG, "stopped following the remote control's status")
            }, "airplay-dacp-status").apply { isDaemon = true }.start()
        }

        private fun pause(ms: Long) {
            synchronized(statusWake) { statusWake.wait(ms) }
        }

        private fun isCurrent() = synchronized(lock) { current === this }

        private fun stopStream() {
            player?.stop()
            stream?.stop()
            player = null
            stream = null
        }
    }

    companion object {
        private const val TAG = "AirPlay"

        /** How long one status request waits for a change before asking again. */
        private const val STATUS_WAIT_MS = 30_000

        /** How often the status is asked for while nothing changes. */
        private const val STATUS_POLL_MS = 2_000L

        /**
         * The sender's volume, -30 (quietest) to 0 dB, -144 for mute, on
         * the squared taper the app's other volumes use.
         */
        fun volumeToGain(v: Float): Float {
            if (v <= -30f) return 0f
            val f = ((v + 30f) / 30f).coerceIn(0f, 1f)
            return f * f
        }

        fun gainToVolume(g: Float): Float {
            if (g <= 0f) return -144f
            return max(-30f, kotlin.math.sqrt(g) * 30f - 30f)
        }
    }
}

/** DMAP, the tagged format AirPlay sends a track's title, artist and album in. */
internal object Dmap {
    /** The string items of a listing (`mlit`), by tag. */
    fun items(body: ByteArray): Map<String, String> {
        val out = HashMap<String, String>()
        walk(body, 0, body.size, out)
        return out
    }

    private fun walk(b: ByteArray, from: Int, to: Int, out: MutableMap<String, String>) {
        var pos = from
        while (pos + 8 <= to) {
            val tag = String(b, pos, 4, Charsets.ISO_8859_1)
            val len = ((b[pos + 4].toInt() and 0xFF) shl 24) or ((b[pos + 5].toInt() and 0xFF) shl 16) or
                ((b[pos + 6].toInt() and 0xFF) shl 8) or (b[pos + 7].toInt() and 0xFF)
            pos += 8
            if (len < 0 || pos + len > to) return
            if (tag in CONTAINERS) {
                walk(b, pos, pos + len, out)
            } else if (tag in STRINGS) {
                out[tag] = String(b, pos, len, Charsets.UTF_8)
            }
            pos += len
        }
    }

    /** The numeric items of a status (`cmst`, `cmgt`), by tag. */
    fun numbers(body: ByteArray): Map<String, Long> {
        val out = HashMap<String, Long>()
        fun walk(from: Int, to: Int) {
            var pos = from
            while (pos + 8 <= to) {
                val tag = String(body, pos, 4, Charsets.ISO_8859_1)
                val len = ((body[pos + 4].toInt() and 0xFF) shl 24) or ((body[pos + 5].toInt() and 0xFF) shl 16) or
                    ((body[pos + 6].toInt() and 0xFF) shl 8) or (body[pos + 7].toInt() and 0xFF)
                pos += 8
                if (len < 0 || pos + len > to) return
                if (tag in STATUS_CONTAINERS) {
                    walk(pos, pos + len)
                } else if (len in 1..8) {
                    var v = 0L
                    for (i in 0 until len) v = (v shl 8) or (body[pos + i].toLong() and 0xFF)
                    out[tag] = v
                }
                pos += len
            }
        }
        walk(0, body.size)
        return out
    }

    /**
     * The songs of a play queue listing (`ceQR`): the items of its list,
     * leaving out the section markers (`ceQS`) that say which part of the
     * queue they come from.
     */
    fun queueItems(body: ByteArray): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        fun walk(from: Int, to: Int, inList: Boolean) {
            var pos = from
            while (pos + 8 <= to) {
                val tag = String(body, pos, 4, Charsets.ISO_8859_1)
                val len = ((body[pos + 4].toInt() and 0xFF) shl 24) or ((body[pos + 5].toInt() and 0xFF) shl 16) or
                    ((body[pos + 6].toInt() and 0xFF) shl 8) or (body[pos + 7].toInt() and 0xFF)
                pos += 8
                if (len < 0 || pos + len > to) return
                when {
                    tag == "ceQR" -> walk(pos, pos + len, false)
                    tag == "mlcl" -> walk(pos, pos + len, true)
                    tag == "mlit" && inList -> out.add(queueItem(body, pos, pos + len))
                }
                pos += len
            }
        }
        walk(0, body.size, false)
        return out
    }

    private fun queueItem(body: ByteArray, from: Int, to: Int): Map<String, Any?> {
        val item = HashMap<String, Any?>()
        var pos = from
        while (pos + 8 <= to) {
            val tag = String(body, pos, 4, Charsets.ISO_8859_1)
            val len = ((body[pos + 4].toInt() and 0xFF) shl 24) or ((body[pos + 5].toInt() and 0xFF) shl 16) or
                ((body[pos + 6].toInt() and 0xFF) shl 8) or (body[pos + 7].toInt() and 0xFF)
            pos += 8
            if (len < 0 || pos + len > to) break
            when (tag) {
                "ceQn" -> item["title"] = String(body, pos, len, Charsets.UTF_8)
                "ceQr" -> item["artist"] = String(body, pos, len, Charsets.UTF_8)
                "ceQa" -> item["album"] = String(body, pos, len, Charsets.UTF_8)
                "astm", "ceQI" -> if (len in 1..8) {
                    var v = 0L
                    for (i in 0 until len) v = (v shl 8) or (body[pos + i].toLong() and 0xFF)
                    item[if (tag == "astm") "durationMs" else "number"] = v
                }
            }
            pos += len
        }
        return item
    }

    private val CONTAINERS = setOf("mlit", "mlcl", "cmst")
    private val STATUS_CONTAINERS = setOf("cmst", "cmgt")
    private val STRINGS = setOf("minm", "asar", "asal", "asaa", "asgn")
}
