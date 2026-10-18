package me.jxl.kiosk_satellite.airplay

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/** One RTSP request as an AirPlay sender sends it: headers and a body. */
internal class RtspRequest(
    val method: String,
    val uri: String,
    private val headers: Map<String, String>,
    val body: ByteArray,
) {
    /** A header by name, case-insensitively. */
    fun header(name: String): String? = headers[name.lowercase()]

    val cseq: String get() = header("CSeq") ?: "0"

    val text: String get() = String(body, Charsets.UTF_8)

    companion object {
        /** Bodies past this are refused: cover art is the largest thing sent. */
        private const val MAX_BODY = 8 * 1024 * 1024
        private const val MAX_LINE = 8192

        /** Reads the next request, or null at the end of the stream. */
        fun read(input: InputStream): RtspRequest? {
            var first: String
            do {
                first = readLine(input) ?: return null
            } while (first.isEmpty())
            val parts = first.split(' ')
            if (parts.size < 3) throw IOException("bad request line")
            val headers = HashMap<String, String>()
            while (true) {
                val line = readLine(input) ?: throw IOException("headers cut short")
                if (line.isEmpty()) break
                val colon = line.indexOf(':')
                if (colon <= 0) continue
                headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
            }
            val length = headers["content-length"]?.toIntOrNull() ?: 0
            if (length < 0 || length > MAX_BODY) throw IOException("body of $length bytes")
            val body = ByteArray(length)
            var read = 0
            while (read < length) {
                val n = input.read(body, read, length - read)
                if (n < 0) throw IOException("body cut short")
                read += n
            }
            return RtspRequest(parts[0], parts[1], headers, body)
        }

        private fun readLine(input: InputStream): String? {
            val out = ByteArrayOutputStream(128)
            while (true) {
                val b = input.read()
                if (b < 0) return if (out.size() == 0) null else out.toString("UTF-8")
                if (b == '\n'.code) break
                if (b != '\r'.code) out.write(b)
                if (out.size() > MAX_LINE) throw IOException("line too long")
            }
            return out.toString("UTF-8")
        }
    }
}

/** A response under construction; [write] sends it. */
internal class RtspResponse(val status: Int = 200) {
    private val headers = LinkedHashMap<String, String>()
    var body: ByteArray = ByteArray(0)

    fun header(name: String, value: String): RtspResponse {
        headers[name] = value
        return this
    }

    fun write(out: OutputStream, cseq: String) {
        val text = StringBuilder()
        text.append("RTSP/1.0 ").append(status).append(' ').append(reason(status)).append("\r\n")
        text.append("CSeq: ").append(cseq).append("\r\n")
        text.append("Server: AirTunes/105.1\r\n")
        for ((k, v) in headers) text.append(k).append(": ").append(v).append("\r\n")
        if (body.isNotEmpty()) text.append("Content-Length: ").append(body.size).append("\r\n")
        text.append("\r\n")
        out.write(text.toString().toByteArray(Charsets.UTF_8))
        if (body.isNotEmpty()) out.write(body)
        out.flush()
    }

    private fun reason(status: Int) = when (status) {
        200 -> "OK"
        400 -> "Bad Request"
        404 -> "Not Found"
        415 -> "Unsupported Media Type"
        451 -> "Parameter Not Understood"
        453 -> "Not Enough Bandwidth"
        456 -> "Header Field Not Valid for Resource"
        501 -> "Not Implemented"
        else -> "Error"
    }
}

/** The parts of a stream's SDP the receiver needs. */
internal class StreamFormat(
    val alac: Boolean,
    val fmtp: IntArray,
    val aesKey: ByteArray?,
    val aesIv: ByteArray?,
) {
    val framesPerPacket: Int get() = if (alac) fmtp[1] else 352
    val sampleRate: Int get() = if (alac) fmtp[11] else 44100
    val channels: Int get() = if (alac) fmtp[7] else 2

    companion object {
        /**
         * The format an ANNOUNCE's SDP describes, or null for one this
         * receiver cannot play (AAC, more than two channels, not 16 bits).
         * [unwrap] turns `a=rsaaeskey` into the AES key.
         */
        fun parse(sdp: String, unwrap: (ByteArray) -> ByteArray, decode: (String) -> ByteArray): StreamFormat? {
            var rtpmap = ""
            var fmtpLine: String? = null
            var key: String? = null
            var iv: String? = null
            for (raw in sdp.split('\n')) {
                val line = raw.trim()
                when {
                    line.startsWith("a=rtpmap:") -> rtpmap = line.substringAfter(' ', "")
                    line.startsWith("a=fmtp:") -> fmtpLine = line.removePrefix("a=fmtp:")
                    line.startsWith("a=rsaaeskey:") -> key = line.removePrefix("a=rsaaeskey:")
                    line.startsWith("a=aesiv:") -> iv = line.removePrefix("a=aesiv:")
                }
            }
            val alac = rtpmap.startsWith("AppleLossless")
            val pcm = rtpmap.startsWith("L16/44100/2")
            if (!alac && !pcm) return null
            // payload type, frames, compatible version, bit depth, pb, mb, kb,
            // channels, max run, max frame bytes, average bit rate, rate.
            val fmtp = intArrayOf(96, 352, 0, 16, 40, 10, 14, 2, 255, 0, 0, 44100)
            if (alac) {
                fmtpLine?.trim()?.split(Regex("\\s+"))?.take(fmtp.size)?.forEachIndexed { i, v ->
                    v.toIntOrNull()?.let { fmtp[i] = it }
                }
                if (fmtp[3] != 16 || fmtp[7] !in 1..2 || fmtp[1] !in 1..8192) return null
            }
            if ((key == null) != (iv == null)) return null
            val aesKey = key?.let { unwrap(decode(it)) }
            val aesIv = iv?.let { decode(it) }
            if (aesKey != null && (aesKey.size != 16 || aesIv?.size != 16)) return null
            return StreamFormat(alac, fmtp, aesKey, aesIv)
        }
    }
}

/** Reads `rtptime=` from an RTP-Info header. */
internal fun rtpTimeOf(header: String?): Long? =
    header?.substringAfter("rtptime=", "")?.takeWhile { it.isDigit() }?.toLongOrNull()
