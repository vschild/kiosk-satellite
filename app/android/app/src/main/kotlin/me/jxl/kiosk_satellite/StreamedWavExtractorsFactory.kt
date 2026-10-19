package me.jxl.kiosk_satellite

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorInput
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.ForwardingExtractorOutput
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.wav.WavExtractor

/**
 * The default extractors, except that a WAV stream with no length takes
 * its duration from the audio that arrives instead of from its header.
 *
 * A TTS engine streaming WAV cannot know its length when it writes the
 * header, so it puts 0xFFFFFFFF in the data size (issue #1030). Media3
 * trusts that size when the server sends no Content-Length, which at 24
 * kHz mono is a 24.8 hour duration. ExoPlayer only ends once the position
 * reaches the duration, so the answer finished playing but the turn never
 * ended. Unsized, the stream behaves like a streamed MP3: no duration
 * until the last byte, then the real one.
 */
@androidx.annotation.OptIn(UnstableApi::class)
internal class StreamedWavExtractorsFactory(
    private val delegate: ExtractorsFactory = DefaultExtractorsFactory(),
) : ExtractorsFactory {
    override fun createExtractors(): Array<Extractor> =
        wrap(delegate.createExtractors())

    override fun createExtractors(
        uri: Uri,
        responseHeaders: Map<String, List<String>>,
    ): Array<Extractor> = wrap(delegate.createExtractors(uri, responseHeaders))

    private fun wrap(extractors: Array<Extractor>): Array<Extractor> =
        Array(extractors.size) {
            val extractor = extractors[it]
            if (extractor is WavExtractor) UnsizedStreamWavExtractor(extractor) else extractor
        }

    private class UnsizedStreamWavExtractor(private val wav: WavExtractor) : Extractor {
        /** The input has no known length: the header's size is a guess. */
        private var unsized = false

        override fun sniff(input: ExtractorInput): Boolean = wav.sniff(input)

        override fun init(output: ExtractorOutput) {
            wav.init(object : ForwardingExtractorOutput(output) {
                override fun seekMap(seekMap: SeekMap) {
                    super.seekMap(if (unsized) SeekMap.Unseekable(C.TIME_UNSET) else seekMap)
                }
            })
        }

        override fun read(input: ExtractorInput, seekPosition: PositionHolder): Int {
            unsized = input.length == C.LENGTH_UNSET.toLong()
            return wav.read(input, seekPosition)
        }

        override fun seek(position: Long, timeUs: Long) = wav.seek(position, timeUs)

        override fun release() = wav.release()

        override fun getUnderlyingImplementation(): Extractor = wav
    }
}
