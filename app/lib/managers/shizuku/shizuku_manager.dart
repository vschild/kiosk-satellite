import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../wake_word/permission_descriptions.dart';

class ShizukuManager extends Manager {
  ShizukuManager(super.bus, super.commands, super.log);
  static const channel = MethodChannel('kiosk_satellite/shizuku');
  final state = ValueNotifier<Map<String, Object?>>(const {
    'status': 'checking',
  });
  bool _disposed = false;
  @override
  String get name => 'shizuku';
  @override
  Future<void> init() async {
    channel.setMethodCallHandler((call) async {
      if (!_disposed && call.method == 'state') {
        _setState(Map<String, Object?>.from(call.arguments as Map));
      }
    });
    for (final name in [
      'getShizukuState',
      'requestShizukuPermission',
      'runShizukuAction',
    ]) {
      commands.register(
        Command(
          name: name,
          description: switch (name) {
            'getShizukuState' => 'Read the device Shizuku connection.',
            'requestShizukuPermission' =>
              'Show the Shizuku permission request on this kiosk.',
            _ => 'Run a predefined Shizuku action for KS only.',
          },
          quiet: name == 'getShizukuState',
          params: name == 'runShizukuAction'
              ? const {
                  'action':
                      'grantAll, identity, reboot, microphone, batteryUnrestricted, camera, bluetooth, notification, displayOverOtherApps, writeSettings, uiGuard, deviceAdmin, allFiles, usageAccess or location',
                }
              : const {},
          handler: (args) async {
            try {
              return CommandResult.ok(
                name == 'runShizukuAction'
                    ? await run(args['action'] as String? ?? '')
                    : await refresh(
                        request: name == 'requestShizukuPermission',
                      ),
              );
            } catch (error) {
              return CommandResult.fail('$error');
            }
          },
        ),
      );
    }
    commands.register(
      Command(
        name: 'runShizukuCommand',
        description:
            'Run a shell command line through Shizuku, as adb shell would, '
            'and answer with its exit code and output.',
        params: const {
          'command': 'the command line, run through sh',
          'timeout': 'seconds to wait, 1 to 25; 0 is 10',
        },
        handler: (args) async {
          try {
            return CommandResult.ok(
              await runCommand(
                '${args['command'] ?? ''}',
                timeout: (args['timeout'] as num?)?.toInt() ?? 0,
              ),
            );
          } on PlatformException catch (error) {
            return CommandResult.fail(
              error.message ?? 'Shizuku command failed',
            );
          } catch (error) {
            return CommandResult.fail(
              error is StateError ? error.message : '$error',
            );
          }
        },
      ),
    );
  }

  /// Why a command cannot run right now, or null when Shizuku is ready.
  /// Each answer names the one thing to fix on the kiosk.
  static String? notReadyReason(Map<String, Object?> state) =>
      switch (state['status']) {
        'ready' => null,
        'unavailable' when state['installed'] == false =>
          'Shizuku is not installed on this device',
        'unavailable' => 'Shizuku is not running. Start it in the Shizuku app',
        'unsupported' => 'Update Shizuku to version 13 or later',
        'permission_required' || 'denied' =>
          'Kiosk Satellite is not allowed in Shizuku. Tap Shizuku access '
              'under Settings > Device > Shizuku',
        _ => 'Shizuku is not available',
      };

  Future<Map<String, Object?>> runCommand(
    String command, {
    int timeout = 0,
  }) async {
    final line = command.trim();
    if (line.isEmpty) throw StateError('command is empty');
    final seconds = timeout <= 0 ? 10 : timeout.clamp(1, 25);
    final reason = notReadyReason(await refresh());
    if (reason != null) throw StateError(reason);
    final result =
        await channel
            .invokeMapMethod<String, Object?>('runCommand', {
              'command': line,
              'timeoutMs': seconds * 1000,
            })
            .timeout(Duration(seconds: seconds + 15)) ??
        const {};
    return {
      'exit_code': result['exitCode'] ?? -1,
      'stdout': '${result['stdout'] ?? ''}',
      'stderr': '${result['stderr'] ?? ''}',
      'timed_out': result['timedOut'] == true,
      'truncated': result['truncated'] == true,
    };
  }

  Future<Map<String, Object?>> refresh({bool request = false}) async {
    final result = await channel
        .invokeMapMethod<String, Object?>(
          request ? 'requestPermission' : 'state',
        )
        .timeout(const Duration(seconds: 10));
    final value = result ?? const <String, Object?>{'status': 'unavailable'};
    _setState(value);
    return value;
  }

  /// One place every state read lands, so the bus hears the grant flip
  /// (issue #528): whoever gates on it re-asks rather than caching the
  /// answer from startup. Flips only: the listeners read the state back
  /// through getShizukuState, and a publish on every read would loop.
  void _setState(Map<String, Object?> value) {
    if (_disposed) return;
    final was = state.value['granted'] == true;
    state.value = value;
    final granted = value['granted'] == true;
    if (granted != was) bus.publish(ShizukuStateChanged(granted: granted));
  }

  Future<Map<String, Object?>> run(String action) async {
    if (action != 'grantAll' &&
        action != 'identity' &&
        action != 'reboot' &&
        !devicePermissionDescriptions.containsKey(action)) {
      throw ArgumentError('Unknown Shizuku action');
    }
    // identity and reboot run one fixed command and answer with its
    // outcome; there is no permission to read back afterwards. A reboot
    // that Android refused says so here, since the device visibly not
    // restarting is the only other signal (issue #528).
    if (action == 'identity' || action == 'reboot') {
      final result =
          await channel
              .invokeMapMethod<String, Object?>('runAction', {'action': action})
              .timeout(const Duration(seconds: 15)) ??
          const {};
      if (action == 'reboot' &&
          (result['exitCode'] != 0 || result['timedOut'] == true)) {
        final stderr = '${result['stderr'] ?? ''}'.trim();
        throw StateError(
          result['timedOut'] == true
              ? 'The restart command timed out'
              : stderr.isEmpty
              ? 'Android refused the restart'
              : stderr,
        );
      }
      return result;
    }
    Future<Map> readPermissions() async {
      final grants = await commands.execute('getSystemPermissions', const {});
      if (!grants.ok || grants.data is! Map) {
        throw StateError('Could not read current permissions. Try again.');
      }
      final guard = await commands.execute('hasUiGuard', const {});
      return {...grants.data as Map, 'uiGuard': guard.ok && guard.data == true};
    }

    final held = await readPermissions();
    Object? grantStatus(String key, Map values) => key == 'bluetooth'
        ? values['bluetoothPair'] ?? values[key]
        : values[key];
    final permissions = devicePermissionDescriptions.keys
        .where((key) => grantStatus(key, held) != true)
        .toList();
    final result = await channel
        .invokeMapMethod<String, Object?>('runAction', {
          'action': action,
          if (action == 'grantAll') 'permissions': permissions,
        })
        .timeout(const Duration(seconds: 180));
    final checked = await readPermissions();
    return {
      ...?result,
      if (action != 'identity')
        'results': [
          for (final row
              in (result?['results'] as List? ?? const []).whereType<Map>())
            {
              ...row,
              if (row['ok'] == true &&
                  grantStatus(row['key'] as String, checked) != true) ...{
                'ok': false,
                'error':
                    'Android has not confirmed this permission. Check Permissions Manager on the device.',
              },
            },
        ],
    };
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    channel.setMethodCallHandler(null);
    state.dispose();
  }
}
