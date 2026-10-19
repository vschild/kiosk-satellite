import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kiosk_satellite/app_container.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/managers/screensaver/photo_metadata.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/ui/screensaver_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Image URL screensaver (issue #1038): one address fetched again for
/// every slide, the photo on screen held through a slow or failed fetch,
/// and Previous stepping back through the photos already fetched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAB4AAAAoCAIAAABmcd1FAAAALklEQVR4nO3MQQEAQAQAsHMttJJYNil4bQEWXfl2/KVXrVar1Wq1Wq1Wq9WH9QCo5QF3BVxaYAAAAABJRU5ErkJggg==',
  );
  const url = 'http://photos.local/random';

  late AppContainer c;
  var changes = 0;
  StreamSubscription<ScreensaverSlideChanged>? subscription;

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  }

  Future<void> mount(
    WidgetTester tester, {
    String address = url,
    Duration retryDelay = const Duration(seconds: 30),
  }) async {
    SharedPreferences.setMockInitialValues({
      'ks.screensaver.mode': 'url',
      'ks.screensaver.url_image': address,
      'ks.screensaver.url_interval_seconds': 600,
    });
    c = AppContainer();
    await c.settings.init();
    await c.screensaver.start();
    changes = 0;
    subscription = c.bus.on<ScreensaverSlideChanged>().listen((_) => changes++);
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ImageUrlScreensaver(container: c, retryDelay: retryDelay),
      ),
    );
    await drain(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await subscription?.cancel();
  }

  test('the address must be a whole http(s) URL, or blank', () {
    expect(defs.validateScreensaverUrlImage(''), isNull);
    expect(defs.validateScreensaverUrlImage('https://x.local/a.jpg'), isNull);
    expect(defs.validateScreensaverUrlImage('/sdcard/a.jpg'), isNotNull);
    expect(defs.validateScreensaverUrlImage('http://'), isNotNull);
    expect(defs.screensaverUrlImage.perDevice, isFalse);
    expect(slideEdgeTapDefs['url'], defs.screensaverUrlEdgeTaps);
    expect(photoMetadataDefs['url']?.enabled, defs.screensaverUrlMetadata);
  });

  testWidgets('every slide is a new fetch, and Previous steps back through '
      'the photos already fetched', (tester) async {
    await tester.runAsync(() async {
      final requests = <http.Request>[];
      await http.runWithClient(
        () async {
          await mount(tester);
          expect(requests, hasLength(1));
          expect(requests.single.url.toString(), url);
          // Never a cached copy: the same address answers anew each time.
          expect(requests.single.headers['Cache-Control'], 'no-cache');
          expect(changes, 1);
          expect(find.byType(Image), findsWidgets);

          final next = c.screensaver.stepSlide(1);
          await drain(tester);
          await next;
          expect(requests, hasLength(2));
          expect(changes, 2);

          // Back to the first photo, from memory.
          final back = c.screensaver.stepSlide(-1);
          await drain(tester);
          await back;
          expect(requests, hasLength(2));
          expect(changes, 3);
          // Nothing older is kept, so a second Previous does nothing.
          final again = c.screensaver.stepSlide(-1);
          await drain(tester);
          await again;
          expect(changes, 3);

          // Forward again walks the kept photo before fetching anew.
          final forward = c.screensaver.stepSlide(1);
          await drain(tester);
          await forward;
          expect(requests, hasLength(2));
          expect(changes, 4);
          final fresh = c.screensaver.stepSlide(1);
          await drain(tester);
          await fresh;
          expect(requests, hasLength(3));
          expect(changes, 5);
          await finish(tester);
        },
        () => MockClient((request) async {
          requests.add(request);
          return http.Response.bytes(png, 200);
        }),
      );
    });
  });

  testWidgets('a failed first fetch says so and retries', (tester) async {
    await tester.runAsync(() async {
      var calls = 0;
      await http.runWithClient(
        () async {
          await mount(tester, retryDelay: const Duration(seconds: 1));
          expect(changes, 0);
          expect(
            find.text('Could not load the image. Retrying automatically.'),
            findsOneWidget,
          );
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          await drain(tester);
          expect(calls, 2);
          expect(changes, 1);
          expect(find.textContaining('Retrying'), findsNothing);
          await finish(tester);
        },
        () => MockClient((request) async {
          calls++;
          return calls == 1
              ? http.Response('down', 503)
              : http.Response.bytes(png, 200);
        }),
      );
    });
  });

  testWidgets('a failed later fetch keeps the photo on screen', (tester) async {
    await tester.runAsync(() async {
      var calls = 0;
      await http.runWithClient(
        () async {
          await mount(tester);
          expect(changes, 1);
          final next = c.screensaver.stepSlide(1);
          await drain(tester);
          await next;
          expect(calls, 2);
          expect(changes, 1);
          expect(find.byType(Image), findsWidgets);
          expect(find.textContaining('Retrying'), findsNothing);
          await finish(tester);
        },
        () => MockClient((request) async {
          calls++;
          // Not an image at all the second time.
          return calls == 1
              ? http.Response.bytes(png, 200)
              : http.Response('<html></html>', 200);
        }),
      );
    });
  });

  testWidgets('no address asks for one', (tester) async {
    await tester.runAsync(() async {
      await mount(tester, address: '');
      expect(
        find.text('No image URL set. Add one in Settings.'),
        findsOneWidget,
      );
      await finish(tester);
    });
  });

  testWidgets('a write of the address being fetched does not fetch twice', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final release = Completer<void>();
      var calls = 0;
      await http.runWithClient(
        () async {
          SharedPreferences.setMockInitialValues({
            'ks.screensaver.mode': 'url',
            'ks.screensaver.url_image': url,
          });
          c = AppContainer();
          await c.settings.init();
          await c.screensaver.start();
          await tester.pumpWidget(
            MaterialApp(home: ImageUrlScreensaver(container: c)),
          );
          await drain(tester);
          // The same value written while the first fetch is out.
          await c.settings.set(defs.screensaverUrlImage, url);
          release.complete();
          await drain(tester);
          expect(calls, 1);
          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient((request) async {
          calls++;
          await release.future;
          return http.Response.bytes(png, 200);
        }),
      );
    });
  });

  testWidgets('a new address shows at once', (tester) async {
    await tester.runAsync(() async {
      final requests = <Uri>[];
      await http.runWithClient(
        () async {
          await mount(tester);
          expect(changes, 1);
          await c.settings.set(
            defs.screensaverUrlImage,
            'http://photos.local/other',
          );
          await drain(tester);
          expect(requests.last.path, '/other');
          expect(changes, 2);
          await finish(tester);
        },
        () => MockClient((request) async {
          requests.add(request.url);
          return http.Response.bytes(png, 200);
        }),
      );
    });
  });
}
