package me.jxl.kiosk_satellite

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest
import java.util.concurrent.Executors
import me.jxl.kiosk_satellite.airplay.RaopListener
import me.jxl.kiosk_satellite.airplay.RaopMdns
import me.jxl.kiosk_satellite.airplay.RaopServer

/**
 * Flutter bridge for the AirPlay receiver (airplay/): an iPhone, iPad or
 * Mac plays to this device as it would to any AirPlay speaker.
 *
 * Methods:
 *  - start {name, senderVolume, offsetMs, takeover}: serve and announce
 *    under [name], with the options of configure. A new name re-announces.
 *  - configure {senderVolume, offsetMs, takeover}: whether the sender's
 *    volume control counts, the playout offset (negative plays earlier)
 *    and whether a second sender can take over. Applies live.
 *  - stop: says goodbye, ends any session and stops serving.
 *  - control {command}: play, pause, toggle, next, previous or stop, sent
 *    to the sender's remote control. False when it has none.
 *  - queue: the sender's Up Next (title, artist, album, durationMs and
 *    the sender's number for each), null when it cannot say.
 *  - playQueue {number}: play the Up Next song the sender numbered so.
 *  - shuffle {on}, repeat {mode}: set them through the remote control,
 *    mode being off, one or all. False when the sender has none.
 *  - seek {positionMs}: jump within the track through the remote control.
 *    False when the sender has none. Not every sender honors it.
 *  - duck {factor}: the voice interaction duck, 1.0 for none.
 *  - snapshot: the session as last pushed.
 *  - stats: the live session's playout diagnostics, null with none.
 *  - artwork: the current cover's bytes, null for none.
 *  - nudge: re-announce after a network change.
 *  - remote {path, headers}: a raw request to the sender's remote
 *    control, with any extra headers, for diagnostics: its status and
 *    body as hex, null with none.
 *
 * Pushes `snapshot` on every change: null with no session, else the
 * sender's name, whether it plays, the track, its progress and an
 * artwork id that moves with each new cover. The Dart manager owns the
 * policy (when it serves, its name and its options), and this bridge only
 * executes.
 * Registered in KioskApplication so it runs with no Activity attached.
 */
class AirPlayBridge(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "kiosk_satellite/airplay")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "airplay-control").apply { isDaemon = true }
    }

    private val deviceId: ByteArray = run {
        val androidId = runCatching {
            Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
        }.getOrNull() ?: "kiosk"
        val digest = MessageDigest.getInstance("SHA-1").digest("airplay:$androidId".toByteArray())
        // A locally administered, unicast hardware address.
        digest.copyOf(6).also { it[0] = ((it[0].toInt() or 0x02) and 0xFE).toByte() }
    }

    private val mdns = RaopMdns(context, deviceId)
    private val state = State()
    private val server = RaopServer(deviceId, state, mdns::lookupDacp)
    private var name = ""
    private var serving = false
    private var duck = 1f

    init {
        // The bridge lives as long as the app, so the listener stays.
        VolumeController.addListener { server.mediaGain = VolumeController.mediaGain }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    configure(call)
                    start(call.argument<String>("name") ?: "")
                    result.success(null)
                }
                "configure" -> {
                    configure(call)
                    result.success(null)
                }
                "stop" -> {
                    stop()
                    result.success(null)
                }
                "control" -> {
                    val command = call.argument<String>("command") ?: ""
                    val sent = server.control(command)
                    if (sent && (command == "next" || command == "previous")) state.holdForJump()
                    result.success(sent)
                }
                "queue" -> worker.execute {
                    val items = runCatching { server.queue() }.getOrNull()
                    main.post { result.success(items) }
                }
                "playQueue" -> {
                    val sent = server.playQueueItem((call.argument<Number>("number") ?: 0).toLong())
                    if (sent) state.holdForJump()
                    result.success(sent)
                }
                "shuffle" -> result.success(server.setShuffle(call.argument<Boolean>("on") ?: false))
                "repeat" -> result.success(server.setRepeat(call.argument<String>("mode") ?: "off"))
                "seek" -> {
                    val sent = server.seek((call.argument<Number>("positionMs") ?: 0).toLong())
                    if (sent) state.holdForJump()
                    result.success(sent)
                }
                "duck" -> {
                    duck = (call.argument<Number>("factor") ?: 1.0).toFloat().coerceIn(0f, 1f)
                    server.duckGain = duck
                    result.success(null)
                }
                "snapshot" -> result.success(state.snapshot())
                "stats" -> worker.execute {
                    val stats = runCatching { server.stats() }.getOrNull()
                    main.post { result.success(stats) }
                }
                "artwork" -> result.success(state.artwork.takeIf { it.isNotEmpty() })
                "remote" -> {
                    val path = call.argument<String>("path") ?: ""
                    val headers = (call.argument<Map<String, Any?>>("headers") ?: emptyMap())
                        .mapValues { "${it.value}" }
                    worker.execute {
                        val answer = runCatching { server.remoteRequest(path, headers) }.getOrNull()
                        main.post {
                            result.success(answer?.let {
                                mapOf(
                                    "status" to it.first,
                                    "body" to it.second.joinToString("") { b -> "%02x".format(b) },
                                )
                            })
                        }
                    }
                }
                "nudge" -> {
                    mdns.nudge()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun configure(call: io.flutter.plugin.common.MethodCall) {
        call.argument<Boolean>("senderVolume")?.let { server.senderVolume = it }
        call.argument<Number>("offsetMs")?.let { server.offsetNs = it.toLong() * 1_000_000L }
        call.argument<Boolean>("takeover")?.let { server.takeover = it }
    }

    private fun start(name: String) {
        this.name = name.ifBlank { android.os.Build.MODEL ?: "Kiosk Satellite" }
        if (serving) {
            mdns.start(this.name, server.port)
            return
        }
        serving = true
        server.mediaGain = VolumeController.mediaGain
        server.duckGain = duck
        worker.execute {
            val port = runCatching { server.start() }.getOrElse {
                Log.e(TAG, "AirPlay receiver could not start", it)
                0
            }
            main.post { if (serving && port > 0) mdns.start(this.name, port) }
        }
    }

    private fun stop() {
        if (!serving) return
        serving = false
        mdns.stop()
        worker.execute { server.stop() }
    }

    /** The session as Dart sees it, kept on the main thread. */
    private inner class State : RaopListener {
        var active = false
        var client = ""
        var playing = false
        var title = ""
        var artist = ""
        var album = ""
        var durationMs: Long? = null
        var positionMs: Long? = null
        var receivedAt = 0L
        var artwork = ByteArray(0)
        var artworkId = 0
        var remote = false

        /**
         * The RTP times the sender stamped the track and the cover with:
         * equal, the cover is that track's, whichever arrived first.
         */
        var metadataRtp: Long? = null
        var artworkRtp: Long? = null
        /**
         * Whether the sender answers its remote control's status, which is
         * what the richer controls (seek, shuffle, repeat, the queue) also
         * need. A Mac does, iOS refuses all of them.
         */
        var remoteStatus = false
        var shuffle = false
        var repeat = "off"
        var shuffleOffered = false
        var repeatOffered = false

        /**
         * A skip or seek asked of the sender keeps the playing look until
         * the audio comes back, for at most [JUMP_HOLD_MS]: the sender
         * flushes and takes a few seconds to start the new spot (3.5 s
         * for an Apple Music track on a Mac), and the gap read as a pause.
         */
        private var holdUntil = 0L
        private var audioPlaying = false
        private val holdEnd = Runnable {
            if (!audioPlaying && playing) {
                showPlaying(false)
                push()
            }
        }

        fun holdForJump() {
            if (!playing) return
            holdUntil = android.os.SystemClock.elapsedRealtime() + JUMP_HOLD_MS
            main.removeCallbacks(holdEnd)
            main.postDelayed(holdEnd, JUMP_HOLD_MS)
        }

        fun snapshot(): Map<String, Any?>? = if (!active) null else mapOf(
            "client" to client,
            "playing" to playing,
            "title" to title,
            "artist" to artist,
            "album" to album,
            "durationMs" to durationMs,
            "positionMs" to positionMs,
            "receivedAt" to receivedAt,
            "artworkId" to if (artwork.isEmpty()) 0 else artworkId,
            "remote" to remote,
            // The cover belongs to the track shown: the album's cover for
            // the queue panel.
            "artworkMatchesTrack" to (artwork.isNotEmpty() && artworkRtp != null && artworkRtp == metadataRtp),
            "remoteStatus" to remoteStatus,
            "shuffle" to shuffle,
            "repeat" to repeat,
            "shuffleOffered" to shuffleOffered,
            "repeatOffered" to repeatOffered,
        )

        private fun push() {
            channel.invokeMethod("snapshot", snapshot())
        }

        private fun onMain(block: () -> Unit) {
            main.post {
                block()
                push()
            }
        }

        override fun onSession(client: String?) = onMain {
            holdUntil = 0
            main.removeCallbacks(holdEnd)
            audioPlaying = false
            active = client != null
            this.client = client ?: ""
            playing = false
            title = ""; artist = ""; album = ""
            durationMs = null; positionMs = null
            artwork = ByteArray(0)
            metadataRtp = null
            artworkRtp = null
            remote = false
            remoteStatus = false
            shuffle = false
            repeat = "off"
            shuffleOffered = false
            repeatOffered = false
        }

        override fun onPlaying(playing: Boolean) = onMain {
            audioPlaying = playing
            if (!playing && android.os.SystemClock.elapsedRealtime() < holdUntil) return@onMain
            holdUntil = 0
            main.removeCallbacks(holdEnd)
            showPlaying(playing)
        }

        private fun showPlaying(playing: Boolean) {
            // The position moves while it plays: re-anchor the clock the
            // surfaces extrapolate from at each change.
            val now = System.currentTimeMillis()
            positionMs?.let { p ->
                if (this.playing && !playing) positionMs = p + (now - receivedAt)
            }
            if (positionMs != null) receivedAt = now
            this.playing = playing
        }

        override fun onMetadata(title: String, artist: String, album: String, rtp: Long?) = onMain {
            this.title = title
            this.artist = artist
            this.album = album
            metadataRtp = rtp
        }

        override fun onArtwork(bytes: ByteArray, rtp: Long?) = onMain {
            artwork = bytes
            artworkId++
            artworkRtp = rtp
        }

        override fun onProgress(start: Long, current: Long, end: Long) = onMain {
            val rate = 44100L
            val elapsed = (current - start) and 0xFFFF_FFFFL
            val length = (end - start) and 0xFFFF_FFFFL
            durationMs = if (length in 1 until 0x8000_0000L) length * 1000 / rate else null
            positionMs = if (elapsed < 0x8000_0000L) elapsed * 1000 / rate else 0
            receivedAt = System.currentTimeMillis()
        }

        override fun onVolume(gain: Float) {}

        override fun onRemote(available: Boolean) = onMain { remote = available }

        override fun onRemoteState(
            shuffle: Boolean,
            repeat: Int,
            shuffleOffered: Boolean,
            repeatOffered: Boolean,
        ) = onMain {
            remoteStatus = true
            this.shuffle = shuffle
            this.repeat = when (repeat) {
                1 -> "one"
                2 -> "all"
                else -> "off"
            }
            this.shuffleOffered = shuffleOffered
            this.repeatOffered = repeatOffered
        }
    }

    private companion object {
        const val TAG = "AirPlay"
        const val JUMP_HOLD_MS = 10_000L
    }
}
