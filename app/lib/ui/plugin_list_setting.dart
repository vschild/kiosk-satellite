import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../core/command_registry.dart';
import '../l10n/messages.dart';
import 'color_picker.dart';
import 'dashboard_view_picker.dart';
import 'entity_picker.dart';
import 'kit.dart';
import 'mdi_icon.dart';
import 'theme.dart';

/// What plugin setting controls reach for: the commands behind the entity
/// picker, and the container for dashboards and camera views. Without a
/// container those two pickers stay read-only.
class PluginFieldServices {
  const PluginFieldServices({required this.commands, this.container});

  final CommandRegistry commands;
  final AppContainer? container;
}

/// The default a field starts with. Row fields may leave it out, and then
/// the type supplies one, the same as PluginManifest.defaultOf.
Object? pluginFieldDefault(Map field) {
  if (field.containsKey('default')) return _copy(field['default']);
  return switch (field['type']) {
    'boolean' => false,
    'number' => field['min'],
    'select' => (field['options'] as List).first,
    'color' => '#FFFFFF',
    'list' => <Object?>[],
    _ => '',
  };
}

/// Whether [field] shows, given the other values on its level. A field
/// under a hidden one hides too. Mirrors PluginManifest.visible.
bool pluginFieldVisible(Map field, Map values, List fields) {
  final condition = field['visibleWhen'];
  if (condition is! Map) return true;
  final target = fields
      .whereType<Map>()
      .where((f) => f['key'] == condition['key'])
      .firstOrNull;
  if (target == null) return true;
  if (!pluginFieldVisible(target, values, fields)) return false;
  final value = values.containsKey(target['key'])
      ? values[target['key']]
      : pluginFieldDefault(target);
  if (condition.containsKey('notEmpty')) {
    return value is String
        ? value.isNotEmpty
        : value is bool
        ? value
        : value != null;
  }
  List<Object?> expected(Object? v) => v is List ? v : [v];
  bool same(Object? a, Object? b) =>
      a is num && b is num ? a.toDouble() == b.toDouble() : a == b;
  if (condition.containsKey('equals')) {
    return expected(condition['equals']).any((e) => same(value, e));
  }
  return !expected(condition['notEquals']).any((e) => same(value, e));
}

/// Whether a required field shown on [row] is still empty, or a shown list
/// is short of its minimum. Save waits for both.
bool pluginFieldMissing(Map field, Map row, List fields) {
  if (!pluginFieldVisible(field, row, fields)) return false;
  final value = row[field['key']];
  if (field['type'] == 'list') {
    final rows = value is List ? value : const [];
    final nested = field['fields'] as List;
    return rows.length < ((field['minItems'] as num?)?.toInt() ?? 0) ||
        rows.whereType<Map>().any((r) => !pluginRowComplete(nested, r));
  }
  return field['required'] == true && '${value ?? ''}'.trim().isEmpty;
}

bool pluginRowComplete(List fields, Map row) =>
    !fields.whereType<Map>().any((f) => pluginFieldMissing(f, row, fields));

/// A fresh, complete copy of [row] for editing, every field filled in.
Map<String, Object?> pluginFilledRow(Map list, Map? row) => {
  for (final field in (list['fields'] as List).whereType<Map>())
    '${field['key']}': row != null && row.containsKey(field['key'])
        ? _copy(row[field['key']])
        : pluginFieldDefault(field),
};

Object? _copy(Object? value) =>
    value is List || value is Map ? jsonDecode(jsonEncode(value)) : value;

String? _rowKey(Map list, String part, String type) {
  final declared = (list['row'] as Map?)?[part];
  if (declared is String) return declared;
  // Without a declared title, the first text field names the row.
  final first = (list['fields'] as List)
      .whereType<Map>()
      .where((f) => f['type'] == type)
      .firstOrNull;
  return part == 'subtitle' ? null : first?['key']?.toString();
}

Map? _fieldOf(Map list, String? key) => key == null
    ? null
    : (list['fields'] as List)
          .whereType<Map>()
          .where((f) => f['key'] == key)
          .firstOrNull;

/// The entity a row's title names, when its title is an entity field that
/// holds one. Its item comes from the shared entity list once that loads.
({String id, PickItem? item})? _titleEntity(Map list, Map row) {
  final key = _rowKey(list, 'title', 'string');
  if (_fieldOf(list, key)?['type'] != 'entity') return null;
  final id = '${row[key] ?? ''}'.trim();
  if (id.isEmpty) return null;
  return (id: id, item: PickCatalog.of('entities').value?.find(id));
}

/// Whether a row's title or second line reads from the entity list.
bool _rowShowsEntities(Map list) {
  final declared = (list['row'] as Map?)?['subtitle'];
  return [
    _rowKey(list, 'title', 'string'),
    ...(declared is List ? declared : [?declared]),
  ].any((key) => _fieldOf(list, key?.toString())?['type'] == 'entity');
}

/// The name a row shows, its first text field unless the list names one.
/// An entity shows its friendly name, or its id until the list has it.
String pluginRowTitle(BuildContext context, Map list, Map row) {
  final entity = _titleEntity(list, row);
  if (entity != null) return entity.item?.name ?? entity.id;
  final key = _rowKey(list, 'title', 'string');
  final value = key == null ? '' : '${row[key] ?? ''}'.trim();
  return value.isEmpty ? pluginText(context, 'Untitled') : value;
}

String _addTitle(BuildContext context, Map list) =>
    list['addTitle']?.toString() ?? l10n(context).commonAdd;

/// One value as a row's second line shows it: a camera view by its name,
/// a number with its unit, an entity by its name and state. Null when
/// there is nothing to say.
String? _displayValue(Map field, Object? value, PluginFieldServices services) {
  switch (field['type']) {
    case 'boolean' || 'list' || 'color':
      return null;
    case 'number':
      return '$value ${field['unit'] ?? ''}'.trim();
    case 'entity':
      final item = PickCatalog.of('entities').value?.find('$value');
      if (item != null) {
        return [item.name, ?item.state].where((t) => t.isNotEmpty).join(' · ');
      }
    case 'cameraView':
      final views = services.container?.camera.config.views ?? const [];
      final view = views.where((v) => v.id == value).firstOrNull;
      if (view != null) return view.name;
  }
  final text = '${value ?? ''}'.trim();
  return text.isEmpty ? null : text;
}

/// A row's second line: the first declared subtitle with something to
/// say. Without one, an entity title adds its state and id, the way the
/// At a Glance rows do.
String? _rowSubtitle(Map list, Map row, PluginFieldServices services) {
  final declared = (list['row'] as Map?)?['subtitle'];
  final keys = declared is List ? declared : [?declared];
  final fields = list['fields'] as List;
  for (final key in keys) {
    final field = _fieldOf(list, '$key');
    if (field == null || !pluginFieldVisible(field, row, fields)) continue;
    final text = _displayValue(field, row[key], services);
    if (text != null) return text;
  }
  // An entity the list lacks already shows its id as the title.
  final item = _titleEntity(list, row)?.item;
  if (item == null) return null;
  final state = item.state ?? '';
  return state.isEmpty ? item.id : '$state · ${item.id}';
}

/// Material Design Icons by name for icon settings, as a grid of tiles
/// like the remote admin's. Names also read as words, so "garage open"
/// finds mdi:garage-open. Like the remote, at most 120 show at a time:
/// drawing all of them stalled even a fast tablet.
PickSpec pluginIconSpec(BuildContext context) => PickSpec(
  key: 'mdiIcons',
  loader: () async => PickList([
    for (final name in await MdiIcons.names())
      PickItem(
        id: 'mdi:$name',
        name: name.replaceAll('-', ' '),
        sub: name,
        icon: 'mdi:$name',
      ),
  ]),
  searchHint: pluginText(context, 'Search icons'),
  noGroup: '',
  chips: false,
  headings: false,
  grid: true,
  limit: 120,
);

/// The kiosk's camera views for camera view settings.
PickSpec pluginCameraViewSpec(
  BuildContext context,
  PluginFieldServices services,
) {
  final strings = l10n(context);
  return PickSpec(
    key: 'pluginCameraViews',
    loader: () async => PickList([
      for (final view in services.container?.camera.config.views ?? const [])
        PickItem(
          id: view.id,
          name: view.name,
          sub: (view.cameraIds.length == 1
              ? strings.screensaverMediaOneCamera
              : strings.screensaverMediaCameras)('${view.cameraIds.length}'),
          icon: 'mdi:cctv',
        ),
    ]),
    searchHint: pluginText(context, 'Search camera views'),
    noGroup: '',
    chips: false,
    headings: false,
  );
}

/// Opens the icon picker with every path held, so scrolling never reads a
/// shard per row. Resolves to the picked name, an empty string for Clear,
/// null when dismissed.
Future<String?> pickPluginIcon(
  BuildContext context, {
  required String title,
  required String value,
}) async {
  unawaited(MdiIcons.hold());
  try {
    final outcome = await showItemPicker(
      context,
      title: title,
      spec: pluginIconSpec(context),
      selected: value.isEmpty ? null : value,
      allowClear: true,
    );
    return outcome == null ? null : outcome.id ?? '';
  } finally {
    MdiIcons.release();
  }
}

/// An icon at rest in the control box: the glyph and its name.
class PluginIconBox extends StatelessWidget {
  const PluginIconBox({super.key, required this.value, required this.onTap});

  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: onTap == null ? 0.38 : 1,
      child: ControlBox(
        onTap: onTap,
        child: Row(
          children: [
            value.isEmpty
                ? Icon(
                    Icons.emoji_symbols_outlined,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  )
                : MdiIcon(
                    name: value,
                    size: 20,
                    color: scheme.primary,
                    fallback: Icons.help_outline,
                  ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                value.isEmpty ? pluginText(context, 'Choose an icon') : value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: value.isEmpty
                    ? TextStyle(fontSize: 15, color: scheme.onSurfaceVariant)
                    : TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13.5,
                        color: scheme.onSurface,
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.keyboard_arrow_down,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// The rows of a list setting and the row that adds one. Rows drag by
/// their handle only, so a touch panel scrolls the page without starting
/// a drag. [onOpen] gets the tapped row's index, or null to add one.
class PluginRows extends StatelessWidget {
  const PluginRows({
    super.key,
    required this.list,
    required this.rows,
    required this.services,
    required this.enabled,
    required this.onOpen,
    required this.onReorder,
    this.contentPadding,
  });

  final Map list;
  final List<Map> rows;
  final PluginFieldServices services;
  final bool enabled;
  final ValueChanged<int?> onOpen;
  final void Function(int oldIndex, int newIndex) onReorder;

  /// Rows inside the row editor sit closer to its border.
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    if (!_rowShowsEntities(list)) return _rows(context);
    // Entity names and states come from the shared list, so the rows
    // redraw once it loads.
    final catalog = PickCatalog.of('entities');
    if (catalog.value == null) unawaited(loadEntityCatalog(services.commands));
    return ValueListenableBuilder<PickList?>(
      valueListenable: catalog,
      builder: (context, _, _) => _rows(context),
    );
  }

  Widget _rows(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final max = (list['maxItems'] as num?)?.toInt() ?? 32;
    final iconKey = (list['row'] as Map?)?['icon'] as String?;
    final titleIsEntity =
        _fieldOf(list, _rowKey(list, 'title', 'string'))?['type'] == 'entity';
    final indent = contentPadding == null ? Ks.inset : 12.0;
    final divider = Divider(height: 1, indent: indent, endIndent: indent);
    // A picked icon wins. Without one, an entity title brings its own,
    // or a warning when Home Assistant no longer has it.
    Widget? leading(Map value) {
      final icon = iconKey == null ? '' : '${value[iconKey] ?? ''}';
      if (icon.isNotEmpty) {
        return MdiIcon(
          name: icon,
          size: 24,
          color: scheme.onSurfaceVariant,
          fallback: Icons.circle_outlined,
        );
      }
      if (titleIsEntity) {
        final entity = _titleEntity(list, value);
        final loaded = PickCatalog.of('entities').value != null;
        if (entity != null && entity.item == null && loaded) {
          return Icon(Icons.warning_amber_rounded, color: scheme.error);
        }
        return PickIcon(
          icon: entity?.item?.icon,
          size: 24,
          color: scheme.onSurfaceVariant,
        );
      }
      return iconKey == null ? null : const Icon(Icons.circle_outlined);
    }

    Widget row(int index) {
      final value = rows[index];
      final subtitle = _rowSubtitle(list, value, services);
      return SettingsRow(
        contentPadding: contentPadding,
        enabled: enabled,
        leading: leading(value),
        title: Text(pluginRowTitle(context, list, value)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: rows.length < 2
            ? const Icon(Icons.chevron_right)
            : ReorderableDragStartListener(
                index: index,
                enabled: enabled,
                child: Semantics(
                  label: pluginText(context, 'Drag to reorder'),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.drag_indicator),
                  ),
                ),
              ),
        onTap: enabled ? () => onOpen(index) : null,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (rows.isNotEmpty) ...[
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: rows.length,
            // newIndex is already adjusted for the removal.
            onReorderItem: onReorder,
            itemBuilder: (context, index) => Column(
              key: ObjectKey(rows[index]),
              mainAxisSize: MainAxisSize.min,
              children: [if (index > 0) divider, row(index)],
            ),
          ),
          if (rows.length < max) divider,
        ],
        if (rows.length < max)
          SettingsRow(
            contentPadding: contentPadding,
            enabled: enabled,
            leading: Icon(Icons.add_circle_outline, color: scheme.primary),
            title: Text(_addTitle(context, list)),
            onTap: enabled ? () => onOpen(null) : null,
          ),
      ],
    );
  }
}

/// A list setting on the plugin's page: the rows inline, each opening the
/// row editor. Every completed edit, delete and drag saves the whole list.
class PluginListSetting extends StatelessWidget {
  const PluginListSetting({
    super.key,
    required this.setting,
    required this.rows,
    required this.services,
    required this.enabled,
    required this.onChanged,
    this.showTitle = true,
  });

  final Map setting;
  final List<Map> rows;
  final PluginFieldServices services;
  final bool enabled;
  final ValueChanged<List<Map>> onChanged;

  /// False when the list is alone in its group, whose heading names it.
  final bool showTitle;

  Future<void> _open(BuildContext context, int? index) async {
    final result = await showPluginRowEditor(
      context,
      list: setting,
      row: index == null ? null : rows[index],
      services: services,
    );
    if (result == null) return;
    final next = [...rows];
    if (result.row == null) {
      next.removeAt(index!);
    } else if (index == null) {
      next.add(result.row!);
    } else {
      next[index] = result.row!;
    }
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final description = setting['description']?.toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showTitle) ...[
          SettingsRow(
            title: Text('${setting['title']}'),
            subtitle: description == null ? null : Text(description),
          ),
          const Divider(height: 1, indent: Ks.inset, endIndent: Ks.inset),
        ],
        PluginRows(
          list: setting,
          rows: rows,
          services: services,
          enabled: enabled,
          onOpen: (index) => _open(context, index),
          onReorder: (from, to) {
            final next = [...rows];
            next.insert(to, next.removeAt(from));
            onChanged(next);
          },
        ),
        if (!showTitle && description != null) HintRow(description),
      ],
    );
  }
}

/// What the row editor hands back: the saved row, or null for a deleted
/// one. Dismissing the editor resolves to no result at all.
class PluginRowEdit {
  const PluginRowEdit(this.row);

  final Map<String, Object?>? row;
}

/// Edits one row of [list] in a modal. A new row when [row] is null.
/// Save stays off until every shown required field is filled in.
Future<PluginRowEdit?> showPluginRowEditor(
  BuildContext context, {
  required Map list,
  Map? row,
  required PluginFieldServices services,
}) => showDialog<PluginRowEdit>(
  context: context,
  // A stray tap outside must not throw away a half-made row.
  barrierDismissible: false,
  builder: (_) => _PluginRowEditor(list: list, row: row, services: services),
);

/// A nested row being edited inside the row editor.
class _Entry {
  _Entry(this.list, this.index, this.draft, this.title);

  final Map list;

  /// Null for a new row.
  final int? index;
  final Map<String, Object?> draft;
  final String title;
}

class _PluginRowEditor extends StatefulWidget {
  const _PluginRowEditor({
    required this.list,
    required this.row,
    required this.services,
  });

  final Map list;
  final Map? row;
  final PluginFieldServices services;

  @override
  State<_PluginRowEditor> createState() => _PluginRowEditorState();
}

class _PluginRowEditorState extends State<_PluginRowEditor> {
  late final Map<String, Object?> _draft = pluginFilledRow(
    widget.list,
    widget.row,
  );

  /// The nested row shown in place of the outer one. Its Done or Cancel
  /// comes back here, so there is only ever one editing surface.
  _Entry? _entry;

  void _openEntry(Map field, int? index) {
    final rows = _draft[field['key']] as List;
    final row = index == null ? null : rows[index] as Map;
    setState(
      () => _entry = _Entry(
        field,
        index,
        pluginFilledRow(field, row),
        row == null
            ? _addTitle(context, field)
            : pluginRowTitle(context, field, row),
      ),
    );
  }

  void _closeEntry({bool save = false, bool delete = false}) {
    final entry = _entry!;
    final rows = _draft[entry.list['key']] as List;
    setState(() {
      if (delete) {
        rows.removeAt(entry.index!);
      } else if (save && entry.index == null) {
        rows.add(entry.draft);
      } else if (save) {
        rows[entry.index!] = entry.draft;
      }
      _entry = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = l10n(context);
    final scheme = Theme.of(context).colorScheme;
    final entry = _entry;
    final list = entry?.list ?? widget.list;
    final fields = (list['fields'] as List).whereType<Map>().toList();
    final draft = entry?.draft ?? _draft;
    final isNew = entry == null ? widget.row == null : entry.index == null;
    final complete = pluginRowComplete(fields, draft);
    final title =
        entry?.title ??
        (widget.row == null
            ? _addTitle(context, list)
            : pluginRowTitle(context, list, widget.row!));
    final body = Column(
      key: ObjectKey(draft),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 16,
      children: [
        for (final field in fields)
          if (pluginFieldVisible(field, draft, fields))
            _field(field, draft, fields),
      ],
    );
    final header = Row(
      children: [
        if (entry != null) ...[
          IconButton(
            tooltip: strings.commonBack,
            icon: const Icon(Icons.arrow_back),
            onPressed: _closeEntry,
          ),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
    final delete = isNew
        ? null
        : TextButton(
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: entry == null
                ? () => Navigator.pop(context, const PluginRowEdit(null))
                : () => _closeEntry(delete: true),
            child: Text(strings.commonDelete),
          );
    final buttons = Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        TextButton(
          onPressed: entry == null
              ? () => Navigator.pop(context)
              : () => _closeEntry(),
          child: Text(strings.commonCancel),
        ),
        FilledButton(
          onPressed: !complete
              ? null
              : entry == null
              ? () => Navigator.pop(context, PluginRowEdit(_draft))
              : () => _closeEntry(save: true),
          child: Text(
            entry == null ? strings.commonSave : pluginText(context, 'Done'),
          ),
        ),
      ],
    );
    final scroll = EdgeFade(child: SingleChildScrollView(child: body));
    final Widget dialog;
    if (MediaQuery.sizeOf(context).width < 640) {
      dialog = Dialog.fullscreen(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  entry == null ? 24 : 8,
                  16,
                  24,
                  12,
                ),
                child: DefaultTextStyle.merge(
                  style: Theme.of(context).textTheme.titleLarge,
                  child: header,
                ),
              ),
              Expanded(
                child: EdgeFade(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                    child: body,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(children: [?delete, const Spacer(), buttons]),
              ),
            ],
          ),
        ),
      );
    } else {
      dialog = AlertDialog(
        title: header,
        titlePadding: EdgeInsets.fromLTRB(entry == null ? 24 : 12, 20, 24, 0),
        content: SizedBox(width: 560, child: scroll),
        actionsAlignment: isNew
            ? MainAxisAlignment.end
            : MainAxisAlignment.spaceBetween,
        actions: [?delete, buttons],
      );
    }
    // Back on an entry returns to its row instead of closing the editor.
    return PopScope(
      canPop: entry == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _entry != null) _closeEntry();
      },
      child: dialog,
    );
  }

  Widget _field(Map field, Map<String, Object?> draft, List<Map> fields) {
    final key = '${field['key']}';
    final title = '${field['title']}';
    final description = field['description']?.toString();
    final value = draft[key];
    void set(Object? next) => setState(() => draft[key] = next);
    final missing = pluginFieldMissing(field, draft, fields);
    Widget labeled(Widget child) => _Labeled(
      label: title,
      helper: description,
      missing: missing,
      child: child,
    );
    final text = '${value ?? ''}';
    final services = widget.services;
    switch (field['type']) {
      case 'boolean':
        return SettingsRow(
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          subtitle: description == null ? null : Text(description),
          trailing: Switch(value: value == true, onChanged: set),
        );
      case 'number':
        return labeled(
          _NumberField(field: field, value: value as num, onChanged: set),
        );
      case 'select':
        return labeled(
          KsDropdown<String>(
            value: text,
            expand: true,
            items: [
              for (final option in field['options'] as List)
                DropdownMenuItem(value: '$option', child: Text('$option')),
            ],
            onChanged: set,
          ),
        );
      case 'color':
        final color = Color(
          0xff000000 | int.parse(text.substring(1), radix: 16),
        );
        return labeled(
          ControlBox(
            onTap: () async {
              final rgb = [1, 3, 5]
                  .map((i) => int.parse(text.substring(i, i + 2), radix: 16))
                  .join(',');
              final picked = await pickColor(
                context,
                initial: rgb,
                title: title,
              );
              if (picked != null) {
                set(
                  '#${picked.split(',').map((c) => int.parse(c.trim()).toRadixString(16).padLeft(2, '0')).join().toUpperCase()}',
                );
              }
            },
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(text),
              ],
            ),
          ),
        );
      case 'entity':
        final domain = field['domain'];
        final spec = entitySpec(
          context,
          services.commands,
          domains: [
            if (domain is String) domain,
            if (domain is List)
              for (final d in domain) '$d',
          ],
        );
        return labeled(
          PickFieldBox(
            spec: spec,
            value: text,
            onTap: () async {
              final outcome = await showItemPicker(
                context,
                title: title,
                spec: spec,
                selected: text.isEmpty ? null : text,
                allowClear: true,
              );
              if (outcome != null) set(outcome.id ?? '');
            },
          ),
        );
      case 'cameraView':
        final spec = pluginCameraViewSpec(context, services);
        return labeled(
          PickFieldBox(
            spec: spec,
            value: text,
            placeholder: pluginText(context, 'Choose a camera view'),
            enabled: services.container != null,
            onTap: () async {
              final outcome = await showItemPicker(
                context,
                title: title,
                spec: spec,
                selected: text.isEmpty ? null : text,
                allowClear: true,
              );
              if (outcome != null) set(outcome.id ?? '');
            },
          ),
        );
      case 'dashboard':
        final container = services.container;
        return labeled(
          Row(
            children: [
              Expanded(
                child: container == null
                    ? ChoiceBox(
                        text: text.isEmpty
                            ? haText(context, 'Choose a view')
                            : text,
                        onTap: null,
                      )
                    : DashboardField(
                        container: container,
                        value: text,
                        onTap: () async {
                          final picked = await showDashboardPicker(
                            context,
                            container: container,
                            title: title,
                            selected: text,
                          );
                          if (picked != null) set(picked);
                        },
                      ),
              ),
              // The dashboard picker has no Clear of its own.
              if (text.isNotEmpty && field['required'] != true)
                IconButton(
                  tooltip: l10n(context).commonClear,
                  icon: const Icon(Icons.close),
                  onPressed: () => set(''),
                ),
            ],
          ),
        );
      case 'icon':
        return labeled(
          PluginIconBox(
            value: text,
            onTap: () async {
              final picked = await pickPluginIcon(
                context,
                title: title,
                value: text,
              );
              if (picked != null) set(picked);
            },
          ),
        );
      case 'list':
        final rows = (value as List).whereType<Map>().toList();
        return labeled(
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(Ks.radiusRow),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Ks.radiusRow),
              child: Material(
                type: MaterialType.transparency,
                child: PluginRows(
                  list: field,
                  rows: rows,
                  services: services,
                  enabled: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  onOpen: (index) => _openEntry(field, index),
                  onReorder: (from, to) =>
                      setState(() => (value).insert(to, value.removeAt(from))),
                ),
              ),
            ),
          ),
        );
      default:
        return labeled(
          TextFormField(
            key: ValueKey('${identityHashCode(draft)}:$key'),
            initialValue: text,
            maxLength: 512,
            decoration: const InputDecoration(counterText: ''),
            onChanged: set,
          ),
        );
    }
  }
}

/// A field's label above it and its description beneath, the way
/// [LabeledField] lays them out, with Required beside an empty required
/// field.
class _Labeled extends StatelessWidget {
  const _Labeled({
    required this.label,
    required this.child,
    required this.missing,
    this.helper,
  });

  final String label;
  final Widget child;
  final bool missing;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = theme.textTheme.bodySmall?.copyWith(
      fontSize: 12.5,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: label),
              if (missing)
                TextSpan(
                  text: ' · ${pluginText(context, 'Required')}',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
            ],
          ),
          style: note,
        ),
        const SizedBox(height: 6),
        child,
        if (helper != null) ...[
          const SizedBox(height: 6),
          Text(helper!, style: note),
        ],
      ],
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.field,
    required this.value,
    required this.onChanged,
  });

  final Map field;
  final num value;
  final ValueChanged<num> onChanged;

  @override
  Widget build(BuildContext context) {
    final min = (field['min'] as num).toDouble();
    final max = (field['max'] as num).toDouble();
    final step = (field['step'] as num? ?? 1).toDouble();
    final unit = field['unit'] ?? '';
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: value.toDouble().clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / step).round(),
            label: '$value $unit'.trim(),
            onChanged: (v) {
              final snapped = double.parse(
                (min + ((v - min) / step).round() * step).toStringAsFixed(6),
              );
              onChanged(
                snapped == snapped.roundToDouble() && step % 1 == 0
                    ? snapped.round()
                    : snapped,
              );
            },
          ),
        ),
        Text('$value $unit'.trim()),
      ],
    );
  }
}
