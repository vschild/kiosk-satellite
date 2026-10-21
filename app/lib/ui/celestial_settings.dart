import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../core/lifecycle.dart';
import '../core/events.dart';
import '../l10n/messages.dart';
import '../managers/screensaver/celestial_location.dart';
import '../managers/settings/definitions.dart' as defs;
import 'entity_picker.dart';
import 'kit.dart';

/// The Celestial screensaver's location entity: the entity picker's row,
/// limited to the domains that carry a latitude and longitude.
class CelestialEntityRow extends StatefulWidget {
  const CelestialEntityRow({super.key, required this.container});

  final AppContainer container;

  @override
  State<CelestialEntityRow> createState() => _CelestialEntityRowState();
}

class _CelestialEntityRowState extends State<CelestialEntityRow> {
  StreamSubscription<SettingChanged>? _sub;

  AppContainer get c => widget.container;

  @override
  void initState() {
    super.initState();
    _sub = c.bus.on<SettingChanged>().listen((event) {
      if (event.key == defs.screensaverCelestialEntity.key && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PickRow(
      title: defs.screensaverCelestialEntity.localizedTitle(context),
      description: defs.screensaverCelestialEntity.localizedDescription(
        context,
      ),
      spec: entitySpec(
        context,
        c.commands,
        domains: const ['person', 'device_tracker', 'zone'],
      ),
      value: c.settings.get(defs.screensaverCelestialEntity).trim(),
      allowClear: true,
      onPick: (id) => c.settings.set(defs.screensaverCelestialEntity, id ?? ''),
    );
  }
}

/// Where the chosen location source places the sky, or why it cannot:
/// under the Location select for the GPS and the home zone, under the
/// picker for an entity. Mirrored on the remote (settings.js).
class CelestialLocationStatusRow extends StatefulWidget {
  const CelestialLocationStatusRow({
    super.key,
    required this.container,
    required this.source,
  });

  final AppContainer container;
  final String source;

  @override
  State<CelestialLocationStatusRow> createState() =>
      _CelestialLocationStatusRowState();
}

class _CelestialLocationStatusRowState extends State<CelestialLocationStatusRow>
    with WidgetsBindingObserver {
  CelestialLocationStatus? _status;
  StreamSubscription<SettingChanged>? _settings;
  StreamSubscription<LocationChanged>? _fixes;
  int _ask = 0;
  final _returned = ReturnWatch();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final c = widget.container;
    _settings = c.bus.on<SettingChanged>().listen((event) {
      if (event.key == defs.screensaverCelestialEntity.key ||
          event.key == defs.haUrl.key ||
          event.key == defs.haToken.key) {
        _refresh();
      }
    });
    _fixes = c.bus.on<LocationChanged>().listen((_) {
      if (widget.source == 'gps') _refresh();
    });
    _refresh();
  }

  @override
  void didUpdateWidget(CelestialLocationStatusRow old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) _refresh();
  }

  void _refresh() {
    final ask = ++_ask;
    setState(() => _status = null);
    unawaited(
      widget.container.celestial.resolve(widget.source).then((status) {
        if (mounted && ask == _ask) setState(() => _status = status);
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the location dialog or the system settings, which report
    // nothing: ask again.
    if (_returned.returned(state)) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settings?.cancel();
    _fixes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final lat = status?.latitude, lon = status?.longitude;
    final String text = status == null
        ? screensaverText(context, 'Checking...')
        : lat != null && lon != null
        ? formatCelestialPlace(lat, lon)
        : screensaverError(context, status.message ?? '');
    return SettingsRow(
      leading: const Icon(Icons.my_location_outlined),
      title: Text(screensaverText(context, 'Current location')),
      subtitle: Text(text),
    );
  }
}
