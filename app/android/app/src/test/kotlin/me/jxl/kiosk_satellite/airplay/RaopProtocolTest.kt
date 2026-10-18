package me.jxl.kiosk_satellite.airplay

import java.io.ByteArrayInputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RaopProtocolTest {
    private fun packet(seq: Int, rtp: Long) = AudioPacket(seq and 0xFFFF, rtp and 0xFFFF_FFFFL, ShortArray(4), 352)

    @Test
    fun bufferHandsOutPacketsInOrderAndAsksForGaps() {
        val gaps = ArrayList<Pair<Int, Int>>()
        val b = PacketBuffer { first, count -> gaps.add(first to count) }
        b.put(packet(10, 1000))
        b.put(packet(11, 1352))
        b.put(packet(14, 2408))
        assertEquals(listOf(12 to 2), gaps)
        // The resend fills one of the two holes before the player gets there.
        b.put(packet(12, 1704))
        assertEquals(1000L, b.headRtp())
        assertEquals(10, b.read(352)?.seq)
        assertEquals(11, b.read(352)?.seq)
        assertEquals(12, b.read(352)?.seq)
        // Still missing: silence in its slot, the clock running on.
        assertEquals(2056L, b.headRtp())
        assertNull(b.read(352))
        assertEquals(2408L, b.headRtp())
        assertEquals(14, b.read(352)?.seq)
        assertNull(b.headRtp())
    }

    @Test
    fun bufferWrapsTheSequenceCounter() {
        val b = PacketBuffer { _, _ -> }
        b.put(packet(0xFFFF, 0xFFFF_FF00L))
        b.put(packet(0, 0xFFFF_FF00L + 352))
        assertEquals(0xFFFF, b.read(352)?.seq)
        assertEquals(0, b.read(352)?.seq)
        assertEquals(2, seqDiff(1, 0xFFFF))
        assertEquals(-2, seqDiff(0xFFFF, 1))
        assertEquals(10L, rtpDiff(5, 0xFFFF_FFFBL))
    }

    @Test
    fun bufferDropsStragglersAndPacketsFromBeforeAFlush() {
        val b = PacketBuffer { _, _ -> }
        b.put(packet(5, 500))
        b.read(352)
        // Already played: too late to matter.
        b.put(packet(4, 148))
        assertNull(b.headRtp())
        b.flush(10_000)
        b.put(packet(6, 852))
        assertNull(b.headRtp())
        b.put(packet(40, 10_000))
        assertEquals(10_000L, b.headRtp())
        assertEquals(1, b.buffered())
    }

    @Test
    fun clockKeepsTheQuietestExchange() {
        val c = ClockSync()
        c.guessFromSync(remoteNs = 5_000, arrivedNs = 1_000)
        assertEquals(4_000L, c.offsetNs)
        // 10 ms round trip, then 2 ms: the second is believed.
        c.addExchange(sentNs = 0, receivedNs = 10_000_000, remoteReceiveNs = 1_000_000_007_000_000, remoteSendNs = 1_000_000_007_000_000)
        assertEquals(1_000_000_002_000_000L, c.offsetNs)
        c.addExchange(sentNs = 100_000_000, receivedNs = 102_000_000, remoteReceiveNs = 1_000_000_101_000_000, remoteSendNs = 1_000_000_101_000_000)
        assertEquals(1_000_000_000_000_000L, c.offsetNs)
        // A sync guess no longer moves it.
        c.guessFromSync(remoteNs = 7, arrivedNs = 0)
        assertEquals(1_000_000_000_000_000L, c.offsetNs)
    }

    @Test
    fun readsRequestsWithBinaryBodies() {
        val body = byteArrayOf(0, 1, 2, 13, 10, 13, 10, 3)
        val head = "SET_PARAMETER rtsp://x/1 RTSP/1.0\r\nCSeq: 7\r\nContent-Type: image/jpeg\r\n" +
            "Content-Length: ${body.size}\r\n\r\n"
        val input = ByteArrayInputStream(head.toByteArray() + body + "OPTIONS * RTSP/1.0\r\nCSeq: 8\r\n\r\n".toByteArray())
        val first = RtspRequest.read(input)!!
        assertEquals("SET_PARAMETER", first.method)
        assertEquals("7", first.cseq)
        assertEquals("image/jpeg", first.header("content-type"))
        assertArrayEquals(body, first.body)
        val second = RtspRequest.read(input)!!
        assertEquals("OPTIONS", second.method)
        assertEquals("8", second.cseq)
        assertNull(RtspRequest.read(input))
    }

    @Test
    fun parsesTheStreamFormat() {
        val sdp = """
            v=0
            o=iTunes 3413821438 0 IN IP4 192.168.1.20
            m=audio 0 RTP/AVP 96
            a=rtpmap:96 AppleLossless
            a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100
            a=rsaaeskey:S0VZ
            a=aesiv:SVY=
        """.trimIndent().replace("\n", "\r\n")
        val keys = ArrayList<ByteArray>()
        val format = StreamFormat.parse(sdp, { keys.add(it); ByteArray(16) }) { s ->
            when (s) {
                "S0VZ" -> "KEY".toByteArray()
                else -> ByteArray(16)
            }
        }!!
        assertTrue(format.alac)
        assertEquals(352, format.framesPerPacket)
        assertEquals(44100, format.sampleRate)
        assertEquals(2, format.channels)
        assertEquals(40, format.fmtp[4])
        assertEquals("KEY", String(keys.single()))
        val pcm = StreamFormat.parse("a=rtpmap:96 L16/44100/2\r\n", { it }) { ByteArray(0) }!!
        assertFalse(pcm.alac)
        assertNull(pcm.aesKey)
        // AAC is not something this receiver plays.
        assertNull(StreamFormat.parse("a=rtpmap:96 mpeg4-generic/44100/2\r\n", { it }) { ByteArray(0) })
        assertEquals(1234L, rtpTimeOf("seq=5;rtptime=1234"))
        assertNull(rtpTimeOf(null))
    }

    @Test
    fun readsTrackMetadata() {
        fun item(tag: String, value: ByteArray): ByteArray {
            val n = value.size
            return tag.toByteArray() + byteArrayOf((n shr 24).toByte(), (n shr 16).toByte(), (n shr 8).toByte(), n.toByte()) + value
        }
        val listing = item(
            "mlit",
            item("minm", "Song".toByteArray()) + item("asar", "Band".toByteArray()) +
                item("astm", byteArrayOf(0, 0, 1, 0)) + item("asal", "Récord".toByteArray()),
        )
        val items = Dmap.items(listing)
        assertEquals("Song", items["minm"])
        assertEquals("Band", items["asar"])
        assertEquals("Récord", items["asal"])
        assertFalse(items.containsKey("astm"))
    }

    @Test
    fun readsTheRemoteStatus() {
        // A Mac's playstatusupdate, trimmed: revision, play state, shuffle,
        // repeat and what it offers of each, and a name to skip.
        val body = hex(
            "636d7374000000526d73747400000004000000c8636d737200000004000000e3" +
                "636170730000000104636173680000000101636172700000000102" +
                "63616173000000010263616172000000010663616e6e00000005536f6e6721",
        )
        val n = Dmap.numbers(body)
        assertEquals(227L, n["cmsr"])
        assertEquals(4L, n["caps"])
        assertEquals(1L, n["cash"])
        assertEquals(2L, n["carp"])
        assertEquals(2L, n["caas"])
        assertEquals(6L, n["caar"])
    }

    @Test
    fun readsThePlayQueue() {
        fun item(tag: String, value: ByteArray): ByteArray {
            val n = value.size
            return tag.toByteArray() + byteArrayOf((n shr 24).toByte(), (n shr 16).toByte(), (n shr 8).toByte(), n.toByte()) + value
        }
        fun num(v: Int, size: Int) = ByteArray(size) { (v shr (8 * (size - 1 - it))).toByte() }
        // A section marker, then two songs, as a Mac lists its Up Next.
        val sections = item("ceQS", item("mlit", item("ceQk", "main".toByteArray()) + item("ceQi", num(1, 4))))
        val songs = item("mlit", item("ceQn", "California".toByteArray()) + item("ceQr", "U2".toByteArray()) +
            item("astm", num(239846, 4)) + item("ceQI", num(3, 4))) +
            item("mlit", item("ceQn", "Song for Someone".toByteArray()) + item("ceQI", num(4, 4)))
        val body = item("ceQR", item("mstt", num(200, 4)) + item("mlcl", sections + songs))
        val queue = Dmap.queueItems(body)
        assertEquals(2, queue.size)
        assertEquals("California", queue[0]["title"])
        assertEquals("U2", queue[0]["artist"])
        assertEquals(239846L, queue[0]["durationMs"])
        assertEquals(3L, queue[0]["number"])
        assertEquals("Song for Someone", queue[1]["title"])
        assertEquals(4L, queue[1]["number"])
    }

    @Test
    fun mapsTheSenderVolume() {
        assertEquals(1f, RaopServer.volumeToGain(0f), 1e-6f)
        assertEquals(0f, RaopServer.volumeToGain(-144f), 1e-6f)
        assertEquals(0f, RaopServer.volumeToGain(-30f), 1e-6f)
        assertEquals(0.25f, RaopServer.volumeToGain(-15f), 1e-6f)
        assertEquals(-15f, RaopServer.gainToVolume(0.25f), 1e-4f)
        assertEquals(-144f, RaopServer.gainToVolume(0f), 1e-6f)
    }

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
