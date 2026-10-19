package me.jxl.kiosk_satellite

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.DataReader
import androidx.media3.extractor.DefaultExtractorInput
import androidx.media3.extractor.DiscardingTrackOutput
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.TrackOutput
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.nio.ByteBuffer
import java.nio.ByteOrder

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [27], application = android.app.Application::class, manifest = Config.NONE)
class StreamedWavExtractorsFactoryTest {
    /** One second of 24 kHz mono 16-bit silence behind a header claiming [dataSize]. */
    private fun wav(dataSize: Long): ByteArray {
        val pcm = 48_000
        return ByteBuffer.allocate(44 + pcm).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()); putInt((dataSize + 36).toInt())
            put("WAVE".toByteArray())
            put("fmt ".toByteArray()); putInt(16)
            putShort(1); putShort(1); putInt(24_000); putInt(48_000); putShort(2); putShort(16)
            put("data".toByteArray()); putInt(dataSize.toInt())
        }.array()
    }

    /** Runs the factory's WAV extractor over [bytes] and returns its seek map. */
    private fun seekMap(bytes: ByteArray, length: Long): SeekMap {
        val extractor = StreamedWavExtractorsFactory()
            .createExtractors(Uri.parse("http://127.0.0.1/tts.mp3"), emptyMap())
            .single { it.underlyingImplementation.javaClass.simpleName == "WavExtractor" }
        var offset = 0
        val reader = DataReader { buffer, at, size ->
            if (offset >= bytes.size) return@DataReader C.RESULT_END_OF_INPUT
            val n = minOf(size, bytes.size - offset)
            System.arraycopy(bytes, offset, buffer, at, n)
            offset += n
            n
        }
        var map: SeekMap? = null
        extractor.init(object : ExtractorOutput {
            override fun track(id: Int, type: Int): TrackOutput = DiscardingTrackOutput()
            override fun endTracks() {}
            override fun seekMap(seekMap: SeekMap) { map = seekMap }
        })
        val input = DefaultExtractorInput(reader, 0, length)
        assertTrue(extractor.sniff(input))
        input.resetPeekPosition()
        while (extractor.read(input, PositionHolder()) == Extractor.RESULT_CONTINUE) {}
        return map!!
    }

    @Test fun streamedPlaceholderSizeHasNoDuration() {
        val map = seekMap(wav(0xFFFF_FFFFL), C.LENGTH_UNSET.toLong())
        assertEquals(C.TIME_UNSET, map.durationUs)
        assertFalse(map.isSeekable)
    }

    @Test fun knownLengthKeepsTheHeaderDuration() {
        val bytes = wav(48_000)
        val map = seekMap(bytes, bytes.size.toLong())
        assertEquals(1_000_000L, map.durationUs)
        assertTrue(map.isSeekable)
    }

    @Test fun otherExtractorsPassThrough() {
        val extractors = StreamedWavExtractorsFactory().createExtractors()
        assertTrue(extractors.any { it.javaClass.simpleName == "Mp3Extractor" })
    }
}
