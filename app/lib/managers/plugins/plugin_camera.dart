import 'dart:async';

import 'package:permission_handler/permission_handler.dart';

import '../../core/command_registry.dart';
import '../../core/headless.dart';
import '../../core/logging.dart';
import '../../core/permissions.dart';
import '../motion/motion_manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';

/// A barcode scan a plugin asked for, as the scanner screen shows it.
class PluginScanRequest {
  const PluginScanRequest({
    required this.pluginId,
    required this.formats,
    required this.facing,
    required this.timeout,
    this.title,
    this.message,
  });

  final String pluginId;

  /// SDK format names. Empty reads every format.
  final List<String> formats;

  /// `front` or `back`, or null for the Camera settings' lens.
  final String? facing;
  final Duration timeout;
  final String? title;
  final String? message;
}

/// Shows the scanner for a request and answers with its outcome as
/// `{ok, value, format}` or `{ok: false, error}`. [cancel] completes with
/// a reason when the scan has to end early.
typedef PluginScanPresenter =
    Future<Map<String, Object?>> Function(
      PluginScanRequest request,
      Future<String> cancel,
    );

/// The device camera for plugins: frames for the `camera` capability ride
/// the motion session, and scans for the `barcode` capability open the
/// scanner screen. The plugin bridge allows one claim and one scan at a
/// time. Errors use the SDK's reason names.
class PluginCamera {
  PluginCamera({
    required this.motion,
    required this.commands,
    required this.settings,
    required this.log,
  });

  final MotionManager motion;
  final CommandRegistry commands;
  final SettingsManager settings;
  final Logger log;

  /// Tells the plugin bridge that a claim ended here. Set by the plugin
  /// manager.
  void Function(Map<String, Object?> args)? notifyClosed;

  /// Shows the scanner. Set by the kiosk screen while it is up.
  PluginScanPresenter? presenter;

  ({String id, String session, int claim})? _claim;
  ({String id, String session, String scan, Completer<String> cancel})? _scan;

  /// Whether a plugin scan is open or about to.
  bool get scanning => _scan != null;

  /// Why the camera cannot run for a plugin right now, or null.
  Future<String?> _unavailable() async {
    if (Headless.active) return 'no_camera';
    if (!settings.get(defs.cameraEnabled)) return 'disabled';
    final facings = await commands.execute('getCameraFacings', const {});
    if (facings.ok && facings.data is List && (facings.data as List).isEmpty) {
      return 'no_camera';
    }
    return null;
  }

  static Future<bool> _permitted() async =>
      await Permission.camera.isGranted ||
      await ensureOsPermission(Permission.camera);

  /// A plugin's openCamera. Answers null when the claim stands, otherwise
  /// the reason it closed. Opening again updates the claim in place.
  Future<String?> open(Map args) async {
    final id = args['id'];
    final session = args['session'];
    final number = args['claim'];
    final width = args['width'];
    final height = args['height'];
    final facing = args['facing'];
    if (id is! String ||
        session is! String ||
        number is! int ||
        width is! int ||
        height is! int) {
      return 'camera_failed';
    }
    final claim = (id: id, session: session, claim: number);
    _claim = claim;
    final refused =
        await _unavailable() ?? (await _permitted() ? null : 'permission');
    // The plugin closed it or opened again while this was answering.
    if (_claim != claim) return null;
    if (refused != null) {
      _claim = null;
      motion.releaseForPlugin();
      return refused;
    }
    final busy = motion.claimForPlugin(
      (
        width: width,
        height: height,
        facing: facing == 'front' || facing == 'back' ? facing as String : null,
      ),
      (reason) {
        if (_claim != claim) return;
        _claim = null;
        notifyClosed?.call({
          'id': id,
          'session': session,
          'claim': number,
          'reason': reason,
        });
      },
    );
    if (busy != null) _claim = null;
    log.info('plugin:$id', busy == null ? 'camera open' : 'camera $busy');
    return busy;
  }

  /// A plugin's closeCamera, or the bridge ending the claim.
  void close(Map args) {
    final claim = _claim;
    if (claim == null ||
        claim.id != args['id'] ||
        claim.session != args['session'] ||
        (args['claim'] is int && args['claim'] != claim.claim)) {
      return;
    }
    _claim = null;
    log.info('plugin:${claim.id}', 'camera closed');
    motion.releaseForPlugin();
  }

  /// A plugin's scanBarcode. Answers once the scanner closes.
  Future<Map<String, Object?>> scan(Map args) async {
    Map<String, Object?> failed(String code) => {'ok': false, 'error': code};
    final id = args['id'];
    final session = args['session'];
    final scan = args['scan'];
    if (id is! String || session is! String || scan is! String) {
      return failed('unavailable');
    }
    final unavailable = await _unavailable();
    if (unavailable != null) return failed(unavailable);
    if (_scan != null || motion.scannerHeld) return failed('busy');
    final present = presenter;
    if (present == null) return failed('unavailable');
    final cancel = Completer<String>();
    final current = (id: id, session: session, scan: scan, cancel: cancel);
    _scan = current;
    var held = false;
    try {
      if (!await _permitted()) return failed('permission');
      if (cancel.isCompleted) return failed(await cancel.future);
      // Someone has to see the scanner.
      await commands.execute('screenOn', const {});
      await commands.execute('stopScreensaver', const {});
      if (cancel.isCompleted) return failed(await cancel.future);
      await motion.holdForScanner();
      held = true;
      final facing = args['facing'];
      final timeout = args['timeoutMs'];
      log.info('plugin:$id', 'barcode scan open');
      final result = await present(
        PluginScanRequest(
          pluginId: id,
          formats: [
            for (final f in args['formats'] as List? ?? const [])
              if (f is String) f,
          ],
          facing: facing == 'front' || facing == 'back'
              ? facing as String
              : null,
          timeout: Duration(milliseconds: timeout is int ? timeout : 30000),
          title: args['title'] as String?,
          message: args['message'] as String?,
        ),
        cancel.future,
      );
      log.info(
        'plugin:$id',
        result['ok'] == true
            ? 'barcode scan read a code'
            : 'barcode scan ended (${result['error']})',
      );
      return result;
    } finally {
      if (_scan == current) _scan = null;
      if (held) motion.releaseScanner();
    }
  }

  /// A plugin's cancelBarcodeScan, or the bridge ending its session.
  void cancelScan(Map args) {
    final current = _scan;
    if (current == null ||
        current.id != args['id'] ||
        current.session != args['session'] ||
        current.scan != args['scan'] ||
        current.cancel.isCompleted) {
      return;
    }
    current.cancel.complete('canceled');
  }
}
