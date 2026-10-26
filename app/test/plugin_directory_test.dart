import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kiosk_satellite/managers/plugins/plugin_directory.dart';

Map<String, Object?> entry([Map<String, Object?> changes = const {}]) => {
  'id': 'weather',
  'name': 'Weather',
  'description': 'Shows the weather.',
  'author': 'Alice',
  'license': 'MIT',
  'version': '1.2.0',
  'repository': 'https://github.com/Alice/kiosk-weather',
  'icon': 'https://kiosksatellite.com/plugins/icons/weather-0123456789ab.png',
  'stars': 9,
  'downloads': 42,
  'installs': 7,
  'capabilities': ['overlay'],
  'sha256': 'b' * 64,
  'status': 'ok',
  ...changes,
};

String index(List<Map<String, Object?>> plugins) => jsonEncode({
  'schemaVersion': 1,
  'generated': '2026-10-19T06:00:00Z',
  'plugins': plugins,
});

void main() {
  test('keeps only listed plugins that would install', () {
    final data = PluginDirectory.parse(
      jsonDecode(
        index([
          entry(),
          entry({'id': 'broken', 'status': 'broken'}),
          entry({'id': 'Bad ID'}),
          entry({'id': 'gitlab', 'repository': 'https://gitlab.com/a/b'}),
          entry({'id': 'old', 'version': 'v1'}),
          entry(),
        ]),
      ),
    );
    final plugins = data['plugins'] as List;
    expect(plugins.map((p) => p['id']), ['weather']);
    final weather = plugins.single as Map;
    expect(weather['repositoryKey'], 'https://github.com/alice/kiosk-weather');
    expect(weather['installs'], 7);
    expect(
      () => PluginDirectory.parse({'schemaVersion': 2, 'plugins': []}),
      throwsFormatException,
    );
  });

  test('shows icons only from the list server', () {
    final origin = Uri.parse('https://kiosksatellite.com/plugins/index.json');
    String? icon(String url) =>
        ((PluginDirectory.parse(
                      jsonDecode(
                        index([
                          entry({'icon': url}),
                        ]),
                      ),
                      origin: origin,
                    )['plugins']
                    as List)
                .single
            as Map)['icon'];
    expect(
      icon('https://kiosksatellite.com/plugins/icons/weather-0123456789ab.png'),
      'https://kiosksatellite.com/plugins/icons/weather-0123456789ab.png',
    );
    expect(icon('https://tracker.example/pixel.png'), isNull);
    expect(icon('http://kiosksatellite.com/plugins/icons/a.png'), isNull);
    expect(icon('https://kiosksatellite.com/plugins/icons/a.svg'), isNull);
  });

  test('compares a listed plugin with the installed one', () {
    final listed =
        (PluginDirectory.parse(jsonDecode(index([entry()])))['plugins'] as List)
                .single
            as Map<String, Object?>;
    Map<String, Object?> installed(
      String version, {
      String repository = 'https://github.com/alice/kiosk-weather',
      String sha = 'aaaa',
    }) => {
      'id': 'weather',
      'version': version,
      'sha256': sha,
      'source': {'repository': repository},
    };
    expect(PluginDirectory.installStatus(listed, null)['installed'], isFalse);
    expect(
      PluginDirectory.installStatus(
        listed,
        installed('1.1.0'),
      )['updateAvailable'],
      isTrue,
    );
    expect(
      PluginDirectory.installStatus(
        listed,
        installed('1.2.0', sha: 'b' * 64),
      )['updateAvailable'],
      isFalse,
    );
    expect(
      PluginDirectory.installStatus(
        listed,
        installed('1.2.0'),
      )['updateAvailable'],
      isTrue,
    );
    final elsewhere = PluginDirectory.installStatus(
      listed,
      installed('1.0.0', repository: 'https://github.com/mallory/weather'),
    );
    expect(elsewhere['installed'], isTrue);
    expect(elsewhere['sameSource'], isFalse);
    expect(elsewhere['updateAvailable'], isFalse);
  });

  test('holds back a release that needs a newer Kiosk Satellite', () {
    Map<String, Object?> listed(Object? minAppVersion) =>
        (PluginDirectory.parse(
                      jsonDecode(
                        index([
                          entry({'minAppVersion': minAppVersion}),
                        ]),
                      ),
                    )['plugins']
                    as List)
                .single
            as Map<String, Object?>;
    expect(listed('2026.10.40')['minAppVersion'], '2026.10.40');
    for (final bad in ['2026.10', '2026.09.1', 'v2026.10.40', 2026, null]) {
      expect(listed(bad)['minAppVersion'], isNull, reason: '$bad');
    }
    final older = {
      'id': 'weather',
      'version': '1.1.0',
      'source': {'repository': 'https://github.com/alice/kiosk-weather'},
    };
    final fresh = PluginDirectory.installStatus(
      listed('2026.10.40'),
      null,
      appVersion: '2026.10.39',
    );
    expect(fresh['needsAppVersion'], '2026.10.40');
    final update = PluginDirectory.installStatus(
      listed('2026.10.40'),
      older,
      appVersion: '2026.10.39',
    );
    expect(update['updateAvailable'], isFalse);
    expect(update['needsAppVersion'], '2026.10.40');
    final current = PluginDirectory.installStatus(
      listed('2026.10.40'),
      older,
      appVersion: '2026.10.40',
    );
    expect(current['updateAvailable'], isTrue);
    expect(current.containsKey('needsAppVersion'), isFalse);
    // Up to date already, so nothing is held back.
    expect(
      PluginDirectory.installStatus(listed('2026.10.40'), {
        ...older,
        'version': '1.2.0',
        'sha256': 'b' * 64,
      }, appVersion: '2026.10.39').containsKey('needsAppVersion'),
      isFalse,
    );
    expect(
      PluginDirectory.appVersionAtLeast('2026.10.9', '2026.10.10'),
      isFalse,
    );
    expect(PluginDirectory.appVersionAtLeast('2027.1.1', '2026.12.9'), isTrue);
    expect(PluginDirectory.appVersionAtLeast('', '2026.10.40'), isTrue);
  });

  group('reading the list', () {
    late Directory temp;
    late int requests;
    late int status;
    late String body;
    late DateTime now;
    PluginDirectory directory() => PluginDirectory(
      clientFactory: () => MockClient((request) async {
        requests++;
        if (status == 0) throw http.ClientException('offline');
        return http.Response(body, status);
      }),
      cacheFile: () async => File('${temp.path}/plugin_directory.json'),
      now: () => now,
    );

    setUp(() {
      temp = Directory.systemTemp.createTempSync('plugin-directory-');
      requests = 0;
      status = 200;
      body = index([entry()]);
      now = DateTime(2026, 10, 19, 8);
    });
    tearDown(() => temp.deleteSync(recursive: true));

    test('reads again only after an hour or on refresh', () async {
      final list = directory();
      await list.read();
      await list.read();
      expect(requests, 1);
      now = now.add(const Duration(minutes: 61));
      await list.read();
      expect(requests, 2);
      await list.read(refresh: true);
      expect(requests, 3);
    });

    test('falls back to the kept copy and says why', () async {
      await directory().read();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      status = 0;
      final data = await directory().read();
      expect((data['plugins'] as List).length, 1);
      expect(data['error'], contains('Could not reach Community Plugins'));
    });

    test('with no copy at all the error says what happened', () async {
      status = 503;
      await expectLater(
        directory().read(),
        throwsA(
          isA<PluginDirectoryError>().having(
            (e) => e.message,
            'message',
            'Could not load Community Plugins. Try again later.',
          ),
        ),
      );
    });

    test('answers whether a repository is listed', () async {
      final list = directory();
      expect(await list.lists('https://github.com/alice/Kiosk-Weather'), true);
      expect(await list.lists('https://github.com/bob/other'), false);
      status = 0;
      expect(await directory().lists('https://github.com/bob/other'), isNull);
    });
  });
}
