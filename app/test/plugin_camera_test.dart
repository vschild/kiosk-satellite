import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/motion/motion_manager.dart';
import 'package:kiosk_satellite/managers/plugins/plugin_camera.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The camera and barcode plugin capabilities: a frame claim rides the
/// motion session, and a scan holds every session off while the scanner
/// has the camera. The camera is mocked at its channels.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final listens = <Map>[];
  final controls = <String>[];
  MockStreamHandlerEventSink? sink;

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async => switch (call.method) {
        'checkPermissionStatus' => 1,
        _ => null,
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('kiosk_satellite/motion/control'),
      (call) async {
        controls.add(call.method);
        return null;
      },
    );
    messenger.setMockStreamHandler(
      const EventChannel('kiosk_satellite/motion'),
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          listens.add(arguments as Map);
          sink = events;
        },
        onCancel: (arguments) => sink = null,
      ),
    );
  });

  late SettingsManager settings;
  late MotionManager motion;
  late PluginCamera camera;
  late List<Map<String, Object?>> closed;

  Future<void> pump() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> build({bool cameraOn = true}) async {
    listens.clear();
    controls.clear();
    sink = null;
    SharedPreferences.setMockInitialValues({'ks.camera.enabled': cameraOn});
    final bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    motion = MotionManager(bus, commands, log, settings);
    await motion.init();
    closed = [];
    camera = PluginCamera(
      motion: motion,
      commands: commands,
      settings: settings,
      log: log,
    )..notifyClosed = closed.add;
    await pump();
  }

  Map<String, Object?> claim(int number, {String facing = 'default'}) => {
    'id': 'scanner',
    'session': 's1',
    'claim': number,
    'width': 1280,
    'height': 720,
    'facing': facing,
  };

  test('a claim runs the camera on its own with its size and lens', () async {
    await build();
    expect(listens, isEmpty, reason: 'nothing else wants the camera');
    expect(await camera.open(claim(1, facing: 'back')), isNull);
    await pump();
    expect(listens.single['plugin'], {'width': 1280, 'height': 720});
    expect(listens.single['camera'], 'back');

    // Opening again with the same request keeps the session as it is.
    expect(await camera.open(claim(2, facing: 'back')), isNull);
    await pump();
    expect(listens, hasLength(1));

    camera.close({'id': 'scanner', 'session': 's1', 'claim': 2});
    await pump();
    expect(sink, isNull, reason: 'the claim was all that held the camera');
    expect(closed, isEmpty, reason: 'the plugin closed it itself');
  });

  test(
    'a claim is refused with the camera off and ends when it turns off',
    () async {
      await build(cameraOn: false);
      expect(await camera.open(claim(1)), 'disabled');
      expect(listens, isEmpty);

      await build();
      expect(await camera.open(claim(1)), isNull);
      await pump();
      await settings.set(defs.cameraEnabled, false);
      await pump();
      expect(closed.single['reason'], 'disabled');
      expect(closed.single['claim'], 1);
      expect(sink, isNull);
    },
  );

  test('a camera error ends the claim as camera_failed', () async {
    await build();
    await camera.open(claim(3));
    await pump();
    sink!.error(code: 'camera', message: 'camera revoked by the OS');
    await pump();
    expect(closed.single['reason'], 'camera_failed');
    expect(closed.single['claim'], 3);
  });

  test(
    'the scanner holds every session off and ends a claim as busy',
    () async {
      await build();
      await camera.open(claim(1));
      await pump();
      expect(sink, isNotNull);

      final started = Completer<PluginScanRequest>();
      final answer = Completer<Map<String, Object?>>();
      camera.presenter = (request, cancel) {
        started.complete(request);
        return answer.future;
      };
      final result = camera.scan({
        'id': 'scanner',
        'session': 's1',
        'scan': 'a',
        'formats': ['ean_13', 'qr_code'],
        'facing': 'back',
        'timeoutMs': 20000,
        'title': 'Scan a product',
      });
      final request = await started.future;
      expect(request.formats, ['ean_13', 'qr_code']);
      expect(request.facing, 'back');
      expect(request.timeout, const Duration(seconds: 20));
      expect(request.title, 'Scan a product');
      expect(request.message, isNull);
      await pump();
      expect(sink, isNull, reason: 'the scanner has the camera');
      expect(controls, contains('release'));
      expect(closed.single['reason'], 'busy');
      expect(motion.scannerHeld, isTrue);

      // Nothing binds meanwhile, a new claim included.
      expect(await camera.open(claim(2)), 'busy');
      expect(await camera.scan({'id': 'other', 'session': 's2', 'scan': 'b'}), {
        'ok': false,
        'error': 'busy',
      });

      answer.complete({
        'ok': true,
        'value': '4006381333931',
        'format': 'ean_13',
      });
      expect(await result, {
        'ok': true,
        'value': '4006381333931',
        'format': 'ean_13',
      });
      expect(motion.scannerHeld, isFalse);
    },
  );

  test('cancelBarcodeScan reaches the open scanner', () async {
    await build();
    camera.presenter = (request, cancel) async => {
      'ok': false,
      'error': await cancel,
    };
    final result = camera.scan({'id': 'scanner', 'session': 's1', 'scan': 'a'});
    await pump();
    // Another session's cancel is not this scan's.
    camera.cancelScan({'id': 'scanner', 'session': 's9', 'scan': 'a'});
    camera.cancelScan({'id': 'scanner', 'session': 's1', 'scan': 'a'});
    expect(await result, {'ok': false, 'error': 'canceled'});
    expect(motion.scannerHeld, isFalse);
  });

  test('a scan needs the camera and the kiosk screen', () async {
    await build(cameraOn: false);
    camera.presenter = (request, cancel) async => {'ok': true};
    expect(await camera.scan({'id': 'scanner', 'session': 's1', 'scan': 'a'}), {
      'ok': false,
      'error': 'disabled',
    });
    await build();
    expect(await camera.scan({'id': 'scanner', 'session': 's1', 'scan': 'a'}), {
      'ok': false,
      'error': 'unavailable',
    });
    expect(motion.scannerHeld, isFalse);
  });
}
