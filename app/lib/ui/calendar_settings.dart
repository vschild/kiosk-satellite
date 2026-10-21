import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../core/events.dart';
import '../l10n/messages.dart';
import '../managers/calendar/calendar_model.dart';
import '../managers/settings/definitions.dart' as defs;
import 'calendar_overlay.dart';
import 'color_picker.dart';
import 'entity_picker.dart';
import 'kit.dart';
import 'settings_search.dart' show SearchLandingTarget;
import 'toast.dart';

/// Settings > Calendar's first card: open the calendar on this kiosk.
class CalendarOpenCard extends StatelessWidget {
  const CalendarOpenCard({super.key, required this.container});

  final AppContainer container;

  @override
  Widget build(BuildContext context) {
    final s = l10n(context);
    return SettingsCard(
      children: [
        SearchLandingTarget(
          id: 'x:calendar_open',
          child: SettingsRow(
            leading: const Icon(Icons.calendar_month_outlined),
            title: Text(s.calendarOpen),
            subtitle: Text(s.calendarOpenHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).popUntil((route) => route.isFirst);
              unawaited(container.commands.execute('openCalendar', const {}));
            },
          ),
        ),
      ],
    );
  }
}

/// The calendars the kiosk shows: each with its avatar, name, entity and a
/// switch, a tap to edit its name, color and person, and Add a calendar.
/// Mirrored by the Calendars card on the remote's Calendar page.
class CalendarSourcesCard extends StatelessWidget {
  const CalendarSourcesCard({super.key, required this.container});

  final AppContainer container;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      container.calendar.calendars,
      container.calendar.pictures,
    ]),
    builder: (context, _) {
      final s = l10n(context);
      final cal = container.calendar;
      final list = cal.calendars.value;
      final paint = CalendarPaint(context, cal);
      return SettingsCard(
        children: [
          for (final source in list)
            SettingsRow(
              leading: CalendarAvatar(
                container: container,
                entity: source.entity,
                paint: paint,
                size: 36,
              ),
              title: Text(source.name.isEmpty ? source.entity : source.name),
              subtitle: Text(source.entity),
              trailing: Switch(
                value: source.on,
                onChanged: (on) => _save([
                  for (final c in list)
                    c.entity == source.entity ? c.copyWith(on: on) : c,
                ]),
              ),
              onTap: () => _edit(context, source),
            ),
          SearchLandingTarget(
            id: 'x:calendar_add',
            child: SettingsRow(
              leading: const Icon(Icons.add),
              title: Text(s.calendarAdd),
              subtitle: list.isEmpty ? Text(s.calendarEmptyTitle) : null,
              onTap: () => _add(context),
            ),
          ),
        ],
      );
    },
  );

  Future<void> _save(List<CalendarSource> list) =>
      container.calendar.saveCalendars(list);

  Future<void> _add(BuildContext context) async {
    final s = l10n(context);
    final picked = await showEntityPicker(
      context,
      container,
      title: s.calendarPickCalendar,
      domains: const ['calendar'],
    );
    final id = picked?.id;
    if (id == null || id.isEmpty || !context.mounted) return;
    final list = container.calendar.calendars.value;
    if (list.any((c) => c.entity == id)) {
      showToast(context, title: s.calendarAlreadyAdded, kind: ToastKind.info);
      return;
    }
    final catalog = await loadEntityCatalog(container.commands);
    final name = catalog?.items
        .where((item) => item.id == id)
        .map((item) => item.name)
        .firstOrNull;
    final source = CalendarSource(
      entity: id,
      name: name ?? id.substring('calendar.'.length),
      color: nextCalendarColor(list),
    );
    await _save([...list, source]);
    if (context.mounted) await _edit(context, source);
  }

  Future<void> _edit(BuildContext context, CalendarSource source) async {
    final result = await showDialog<_EditResult>(
      context: context,
      builder: (_) => _CalendarEditDialog(container: container, source: source),
    );
    if (result == null) return;
    final list = container.calendar.calendars.value;
    await _save([
      for (final c in list)
        if (c.entity != source.entity) c else ?result.source,
    ]);
  }
}

typedef _EditResult = ({CalendarSource? source});

class _CalendarEditDialog extends StatefulWidget {
  const _CalendarEditDialog({required this.container, required this.source});

  final AppContainer container;
  final CalendarSource source;

  @override
  State<_CalendarEditDialog> createState() => _CalendarEditDialogState();
}

class _CalendarEditDialogState extends State<_CalendarEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.source.name,
  );
  late String _color = widget.source.color;
  late String _person = widget.source.person;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Color _rgb(String raw) {
    final rgb = parseRgb(raw);
    return rgb == null
        ? Colors.grey
        : Color.fromARGB(255, rgb.$1, rgb.$2, rgb.$3);
  }

  String _colorName(BuildContext context, String name) {
    final s = l10n(context);
    return switch (name) {
      'Teal' => s.calendarColorTeal,
      'Rust' => s.calendarColorRust,
      'Blue' => s.calendarColorBlue,
      'Plum' => s.calendarColorPlum,
      'Ochre' => s.calendarColorOchre,
      'Sage' => s.calendarColorSage,
      'Rose' => s.calendarColorRose,
      'Slate' => s.calendarColorSlate,
      _ => name,
    };
  }

  Widget _swatch(Color color, bool on, String label, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Semantics(
        selected: on,
        button: true,
        label: label,
        child: InkResponse(
          onTap: onTap,
          radius: 24,
          child: Container(
            width: 40,
            height: 40,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: on ? color : Colors.transparent,
                width: 2,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.outlineVariant),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = l10n(context);
    final scheme = Theme.of(context).colorScheme;
    final inPalette = calendarPalette.any((p) => p.rgb == _color);
    final label = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: scheme.onSurfaceVariant,
    );
    return AlertDialog(
      title: Text(
        widget.source.name.isEmpty ? widget.source.entity : widget.source.name,
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: s.calendarEditName),
              ),
              Text(s.calendarEditColor, style: label),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final p in calendarPalette)
                    _swatch(
                      _rgb(p.rgb),
                      p.rgb == _color,
                      _colorName(context, p.name),
                      () => setState(() => _color = p.rgb),
                    ),
                  Tooltip(
                    message: s.calendarColorCustom,
                    child: InkResponse(
                      radius: 24,
                      onTap: () async {
                        final picked = await pickColor(
                          context,
                          initial: _color,
                          title: s.calendarColorCustom,
                        );
                        if (picked != null && mounted) {
                          setState(() => _color = picked);
                        }
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: inPalette
                                ? Colors.transparent
                                : _rgb(_color),
                            width: 2,
                          ),
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: inPalette ? null : _rgb(_color),
                            border: Border.all(color: scheme.outline),
                          ),
                          child: Icon(
                            Icons.palette_outlined,
                            size: 18,
                            color: inPalette
                                ? scheme.onSurfaceVariant
                                : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              PickRow(
                title: s.calendarEditPerson,
                description: s.calendarEditPersonHint,
                dialogTitle: s.calendarPickPerson,
                spec: entitySpec(
                  context,
                  widget.container.commands,
                  domains: const ['person'],
                ),
                value: _person,
                placeholder: s.calendarEditPersonNone,
                allowClear: true,
                onPick: (id) => setState(() => _person = id ?? ''),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: scheme.error),
          onPressed: () =>
              Navigator.of(context).pop<_EditResult>((source: null)),
          child: Text(s.commonRemove),
        ),
        const SizedBox(width: 24),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop<_EditResult>((
            source: widget.source.copyWith(
              name: _name.text.trim().isEmpty
                  ? widget.source.name
                  : _name.text.trim(),
              color: _color,
              person: _person,
            ),
          )),
          child: Text(s.commonSave),
        ),
      ],
    );
  }
}

/// The weather entity whose forecast goes on each day, picked from the
/// weather entities, never typed.
class CalendarWeatherRow extends StatefulWidget {
  const CalendarWeatherRow({super.key, required this.container});

  final AppContainer container;

  @override
  State<CalendarWeatherRow> createState() => _CalendarWeatherRowState();
}

class _CalendarWeatherRowState extends State<CalendarWeatherRow> {
  StreamSubscription<SettingChanged>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.container.bus.on<SettingChanged>().listen((e) {
      if (e.key == defs.calendarWeatherEntity.key && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.container;
    return PickRow(
      title: defs.calendarWeatherEntity.localizedTitle(context),
      description: defs.calendarWeatherEntity.localizedDescription(context),
      spec: entitySpec(context, c.commands, domains: const ['weather']),
      value: c.settings.get(defs.calendarWeatherEntity).trim(),
      allowClear: true,
      onPick: (id) => c.settings.set(defs.calendarWeatherEntity, id ?? ''),
    );
  }
}
