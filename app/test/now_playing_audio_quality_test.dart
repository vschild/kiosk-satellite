import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/l10n/generated/ui_strings.dart';
import 'package:kiosk_satellite/managers/sendspin/music_assistant_api.dart';
import 'package:kiosk_satellite/ui/sendspin_player_overlay.dart';

Map<String, Object?> _queue(Map<String, Object?> format, {String? provider}) =>
    {
      'state': 'playing',
      'current_item': {
        'queue_item_id': 'q1',
        'name': 'Song',
        'media_item': {'name': 'Song', 'media_type': 'track'},
        'streamdetails': {'provider': ?provider, 'audio_format': format},
      },
    };

void main() {
  group('audioQualityOf', () {
    test('reads a hi-res FLAC stream and names its source', () {
      final snap = queueTrackSnapshot(
        _queue({
          'content_type': 'flac',
          'codec_type': 'unknown',
          'sample_rate': 96000,
          'bit_depth': 24,
          'bit_rate': 0,
        }, provider: 'qobuz--abc'),
        providerNames: const {'qobuz--abc': 'Qobuz'},
      );
      expect(snap?['audioQuality'], {
        'codec': 'FLAC',
        'sampleRate': 96000,
        'bitDepth': 24,
        'lossless': true,
        'source': 'Qobuz',
      });
    });

    test('names the codec inside a container', () {
      final quality = audioQualityOf({
        'provider': 'spotify--x',
        'audio_format': {
          'content_type': 'ogg',
          'codec_type': 'vorbis',
          'sample_rate': 44100,
          'bit_depth': 16,
          'bit_rate': 320,
        },
      }, const {});
      expect(quality, {
        'codec': 'VORBIS',
        'sampleRate': 44100,
        'bitDepth': 16,
        'bitRate': 320,
        'lossless': false,
      });
    });

    test('reads raw PCM as lossless PCM', () {
      final quality = audioQualityOf({
        'audio_format': {'content_type': 's24le', 'sample_rate': 48000},
      }, const {});
      expect(quality?['codec'], 'PCM');
      expect(quality?['lossless'], isTrue);
    });

    test('is null before the stream starts', () {
      expect(audioQualityOf(null, const {}), isNull);
      expect(audioQualityOf({'audio_format': null}, const {}), isNull);
      expect(
        audioQualityOf({
          'audio_format': {'content_type': 'unknown'},
        }, const {}),
        isNull,
      );
      expect(queueTrackSnapshot(_queue({}))?['audioQuality'], isNull);
    });
  });

  group('queueTrackSnapshot title', () {
    Map<String, Object?> queue(Map<String, Object?> media) => {
      'current_item': {'name': 'Artist - Song', 'media_item': media},
    };

    test('joins a version the way the Sendspin metadata does', () {
      expect(
        queueTrackSnapshot(
          queue({'name': 'Red', 'version': 'Document One Remix'}),
        )?['title'],
        'Red (Document One Remix)',
      );
    });

    test('keeps a name that already carries its version', () {
      expect(
        queueTrackSnapshot(
          queue({'name': 'Red (Live)', 'version': 'Live'}),
        )?['title'],
        'Red (Live)',
      );
      expect(
        queueTrackSnapshot(queue({'name': 'Red', 'version': ''}))?['title'],
        'Red',
      );
    });
  });

  group('audioQualityLabels', () {
    Future<List<String>> labels(
      WidgetTester tester,
      Map<String, Object?>? quality, {
      Locale locale = const Locale('en'),
    }) async {
      late List<String> result;
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: UiStrings.localizationsDelegates,
          supportedLocales: UiStrings.supportedLocales,
          home: Builder(
            builder: (context) {
              result = audioQualityLabels(context, quality);
              return const SizedBox();
            },
          ),
        ),
      );
      return result;
    }

    testWidgets('hi-res lossless shows the badge and the bit depth', (
      tester,
    ) async {
      expect(
        await labels(tester, {
          'codec': 'FLAC',
          'sampleRate': 96000,
          'bitDepth': 24,
          'bitRate': 2400,
          'lossless': true,
          'source': 'Qobuz',
        }),
        ['Hi-Res', 'FLAC', '24-bit', '96 kHz', '2400 kbps', 'Qobuz'],
      );
    });

    testWidgets('16-bit 44.1 kHz lossless reads as CD quality', (tester) async {
      expect(
        await labels(tester, {
          'codec': 'FLAC',
          'sampleRate': 44100,
          'bitDepth': 16,
          'lossless': true,
        }),
        ['CD quality', 'FLAC', '16-bit', '44.1 kHz'],
      );
    });

    testWidgets('lossy audio reads as Lossy with its decoded bit depth', (
      tester,
    ) async {
      expect(
        await labels(tester, {
          'codec': 'VORBIS',
          'sampleRate': 44100,
          'bitDepth': 16,
          'bitRate': 320,
          'lossless': false,
          'source': 'Spotify',
        }),
        ['Lossy', 'VORBIS', '16-bit', '44.1 kHz', '320 kbps', 'Spotify'],
      );
    });

    testWidgets('the sample rate follows the locale', (tester) async {
      final result = await labels(tester, {
        'codec': 'FLAC',
        'sampleRate': 44100,
        'lossless': true,
      }, locale: const Locale('de'));
      expect(result, contains(startsWith('44,1')));
    });

    testWidgets('nothing to show without a format', (tester) async {
      expect(await labels(tester, null), isEmpty);
    });
  });
}
