import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/glance/glance_manager.dart';
import 'package:kiosk_satellite/managers/home_assistant/home_assistant_manager.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:kiosk_satellite/ui/glance_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// At a Glance states read the way Home Assistant words them: a window
/// sensor that is "off" reads "Closed", in the server's language, and an
/// integration's own states use its translation key (issue #919).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const german = {
    'component.binary_sensor.entity_component._.state.off': 'Aus',
    'component.binary_sensor.entity_component._.state.on': 'Ein',
    'component.binary_sensor.entity_component.window.state.off': 'Geschlossen',
    'component.binary_sensor.entity_component.window.state.on': 'Geöffnet',
    'component.binary_sensor.entity_component.window.name': 'Fenster',
    'component.sensor.entity_component._.name': 'Sensor',
    'component.backup.entity.sensor.backup_manager_state.state.idle':
        'Leerlauf',
    'component.backup.entity.event.automatic_backup_event.state_attributes.event_type.state.failed':
        'Fehlgeschlagen',
  };

  /// A German Home Assistant stand-in. [asked] records each translation
  /// lookup as `category:integrations`. While [registryFails] says so, the
  /// registry lookup fails the way an old server's would. Like the real
  /// server it rejects an id that is not higher than the last one.
  Future<(HttpServer, HomeAssistantManager)> start(
    List<String> asked, {
    bool registryFails = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(jsonEncode({'type': 'auth_required'}));
      var lastId = 0;
      socket.listen((raw) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        final type = '${msg['type']}';
        if (type == 'auth') {
          socket.add(jsonEncode({'type': 'auth_ok'}));
          return;
        }
        final id = msg['id'] as int;
        if (id <= lastId) {
          socket.add(
            jsonEncode({
              'id': id,
              'type': 'result',
              'success': false,
              'error': {'code': 'id_reuse'},
            }),
          );
          return;
        }
        lastId = id;
        Map<String, Object?> result(Object? value) => {
          'id': msg['id'],
          'type': 'result',
          'success': true,
          'result': value,
        };
        switch (type) {
          case 'ping':
            socket.add(jsonEncode({'id': id, 'type': 'pong'}));
          case 'subscribe_entities':
            socket.add(jsonEncode(result(null)));
          case 'frontend/get_user_data':
            // A user who never picked a language follows the server.
            socket.add(jsonEncode(result({'value': null})));
          case 'get_config':
            socket.add(jsonEncode(result({'language': 'de'})));
          case 'config/entity_registry/get_entries':
            if (registryFails) {
              socket.add(
                jsonEncode({
                  'id': msg['id'],
                  'type': 'result',
                  'success': false,
                  'error': {'code': 'unknown_command'},
                }),
              );
              return;
            }
            socket.add(
              jsonEncode(
                result({
                  'binary_sensor.window': {
                    'platform': 'zha',
                    'translation_key': null,
                  },
                  'sensor.backup_state': {
                    'platform': 'backup',
                    'translation_key': 'backup_manager_state',
                  },
                }),
              ),
            );
          case 'frontend/get_translations':
            final integrations = (msg['integration'] as List).cast<String>();
            asked.add('${msg['category']}:${integrations.join(',')}');
            socket.add(
              jsonEncode(
                result({
                  'resources': {
                    for (final entry in german.entries)
                      if (integrations.any(
                        (i) => entry.key.startsWith(
                          'component.$i.${msg['category']}.',
                        ),
                      ))
                        entry.key: entry.value,
                  },
                }),
              ),
            );
        }
      });
    });
    SharedPreferences.setMockInitialValues({
      'ks.ha.url': 'http://127.0.0.1:${server.port}',
      'ks.ha.token': 'token',
    });
    final bus = EventBus();
    final log = Logger();
    final settings = SettingsManager(bus, CommandRegistry(log), log);
    await settings.init();
    return (
      server,
      HomeAssistantManager(bus, CommandRegistry(log), log, settings),
    );
  }

  Future<EntityStateLabels> labels(HomeAssistantManager ha) async {
    final got = Completer<EntityStateLabels>();
    final live = await ha.subscribeEntities(
      ['binary_sensor.window', 'sensor.backup_state'],
      (_, _) {},
      onStateLabels: got.complete,
    );
    addTearDown(() => live?.close());
    return got.future.timeout(const Duration(seconds: 2));
  }

  test('states read in the server language, by class and key', () async {
    final asked = <String>[];
    final (server, ha) = await start(asked);
    addTearDown(() => server.close(force: true));
    final got = await labels(ha);
    expect(got.label('binary_sensor.window', 'window', 'off'), 'Geschlossen');
    expect(got.label('binary_sensor.window', null, 'on'), 'Ein');
    // A class Home Assistant has no wording for falls back to the domain's.
    expect(got.label('binary_sensor.window', 'vibration', 'off'), 'Aus');
    expect(got.label('sensor.backup_state', 'enum', 'idle'), 'Leerlauf');
    expect(got.label('sensor.backup_state', null, '21.5'), isNull);
    expect(asked, ['entity_component:binary_sensor,sensor', 'entity:backup']);
    // The next subscription reads the cache instead of asking again.
    final again = await labels(ha);
    expect(again.label('binary_sensor.window', 'window', 'on'), 'Geöffnet');
    expect(asked, hasLength(2));
  });

  test('labels still come when the registry lookup fails', () async {
    final asked = <String>[];
    final (server, ha) = await start(asked, registryFails: true);
    addTearDown(() => server.close(force: true));
    final got = await labels(ha);
    expect(got.label('binary_sensor.window', 'window', 'off'), 'Geschlossen');
    expect(got.label('sensor.backup_state', null, 'idle'), isNull);
    expect(asked, ['entity_component:binary_sensor,sensor']);
  });

  test('pings after the language lookup still get a pong', () async {
    GlanceSubscription.heartbeat = const Duration(milliseconds: 50);
    GlanceSubscription.pongTimeout = const Duration(milliseconds: 50);
    addTearDown(() {
      GlanceSubscription.heartbeat = const Duration(seconds: 30);
      GlanceSubscription.pongTimeout = const Duration(seconds: 10);
    });
    final (server, ha) = await start(<String>[]);
    addTearDown(() => server.close(force: true));
    final got = Completer<void>();
    final live = await ha.subscribeEntities(
      ['binary_sensor.window'],
      (_, _) {},
      onStateLabels: (_) => got.complete(),
    );
    addTearDown(() => live?.close());
    await got.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(live!.isClosed, false);
  });

  test('parseStateLabels leaves out names and attribute states', () {
    final parsed = parseStateLabels({'resources': german});
    expect(parsed.keys, unorderedEquals(['binary_sensor', 'backup']));
    expect(parsed['binary_sensor'], hasLength(4));
    expect(parsed['backup'], {
      'component.backup.entity.sensor.backup_manager_state.state.idle':
          'Leerlauf',
    });
  });

  group('glanceStateText', () {
    final labels = EntityStateLabels(german, {
      'sensor.backup_state': ('backup', 'backup_manager_state'),
    });

    GlanceEntity entity(
      String id,
      String state, {
      String? deviceClass,
      String? unit,
      int? precision,
    }) => GlanceEntity(
      entityId: id,
      name: id,
      state: state,
      deviceClass: deviceClass,
      unit: unit,
      precision: precision,
      labels: labels,
    );

    test('uses the wording Home Assistant sends', () {
      expect(
        glanceStateText(
          entity('binary_sensor.window', 'off', deviceClass: 'window'),
        ),
        'Geschlossen',
      );
      expect(
        glanceStateText(entity('sensor.backup_state', 'idle')),
        'Leerlauf',
      );
    });

    test('numbers and unknown states keep their own text', () {
      expect(
        glanceStateText(entity('sensor.t', '21.46', unit: '°C', precision: 1)),
        '21.5 °C',
      );
      expect(
        glanceStateText(entity('binary_sensor.window', 'unknown')),
        'Unknown',
      );
      // No wording at all: the prettified state, as before.
      expect(glanceStateText(entity('cover.garage', 'opening')), 'Opening');
    });
  });
}
