import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/messages.dart';
import '../managers/plugins/plugin_manager.dart';
import 'entity_picker.dart';
import 'kit.dart';
import 'toast.dart';

/// A run on a settings button or a choices refresh, as the host reports it:
/// run, state (running, success or error), message, code, origin and
/// confirm. Null when nothing ran since the plugin started.
Map? pluginSetupRun(PluginManager plugins, String pluginId, String target) =>
    ((plugins.setup.value[pluginId]?['runs'] as Map?)?[target]) as Map?;

/// The choices a plugin listed for a setting, or null before it listed any.
List<Map>? pluginSetupChoices(
  PluginManager plugins,
  String pluginId,
  String key,
) => ((plugins.setup.value[pluginId]?['choices'] as Map?)?[key] as List?)
    ?.whereType<Map>()
    .toList();

/// Starts a run, with the toast every other plugin action shows when the
/// host refuses it.
Future<void> startPluginSetup(
  BuildContext context,
  PluginManager plugins,
  String pluginId, {
  required String target,
  required String key,
}) async {
  try {
    await plugins.runSetup(pluginId, target: target, key: key);
  } catch (error) {
    if (context.mounted) {
      showToast(
        context,
        title: pluginText(context, 'Plugin'),
        message: pluginError(context, '$error'),
        kind: ToastKind.error,
      );
    }
  }
}

/// The line under a run's row: its progress or outcome, in error color
/// when it failed. Null while there is nothing to say.
Widget? pluginSetupStatus(BuildContext context, Map? run) {
  if (run == null) return null;
  final timeout = run['code'] == 'timeout';
  final text = timeout
      ? pluginText(context, 'The plugin did not answer in time.')
      : '${run['message'] ?? ''}';
  if (text.isEmpty) return null;
  return Text(
    text,
    style: run['state'] == 'error'
        ? TextStyle(color: Theme.of(context).colorScheme.error)
        : null,
  );
}

Widget _spinner() => const SizedBox(
  width: 20,
  height: 20,
  child: CircularProgressIndicator(strokeWidth: 2),
);

/// A manifest button: its title and description, the run's progress or
/// outcome below, and the button, or Cancel while it runs. A button with a
/// confirm block asks first.
class PluginSetupButtonRow extends StatelessWidget {
  const PluginSetupButtonRow({
    super.key,
    required this.plugins,
    required this.pluginId,
    required this.button,
    required this.running,
  });

  final PluginManager plugins;
  final String pluginId;
  final Map button;

  /// The plugin is running, so it can answer.
  final bool running;

  Future<void> _press(BuildContext context) async {
    final confirm = button['confirm'];
    if (confirm is Map) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${confirm['title']}'),
          content: SizedBox(width: 420, child: Text('${confirm['message']}')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(pluginText(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('${confirm['confirmLabel']}'),
            ),
          ],
        ),
      );
      if (go != true || !context.mounted) return;
    }
    await startPluginSetup(
      context,
      plugins,
      pluginId,
      target: 'button',
      key: '${button['id']}',
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: plugins.setup,
    builder: (context, _, _) {
      final run = pluginSetupRun(plugins, pluginId, 'button:${button['id']}');
      final busy = run?['state'] == 'running';
      final status = pluginSetupStatus(context, run);
      final description = button['description'] as String?;
      return SettingsRow(
        title: Text('${button['title']}'),
        enabled: running,
        subtitle: description == null && status == null
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [if (description != null) Text(description), ?status],
              ),
        trailing: busy
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _spinner(),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () => unawaited(
                      plugins
                          .cancelSetup(pluginId, '${run!['run']}')
                          .catchError((_) {}),
                    ),
                    child: Text(pluginText(context, 'Cancel')),
                  ),
                ],
              )
            : OutlinedButton(
                onPressed: running ? () => _press(context) : null,
                child: Text('${button['label']}'),
              ),
      );
    },
  );
}

/// A text setting whose choices the plugin lists: the picked choice by its
/// label, Refresh to have the plugin look again, and the refresh's
/// progress or outcome below. The setting stores the choice's id.
class PluginChoiceRow extends StatelessWidget {
  const PluginChoiceRow({
    super.key,
    required this.plugins,
    required this.pluginId,
    required this.setting,
    required this.value,
    required this.running,
    required this.enabled,
    required this.onPick,
  });

  final PluginManager plugins;
  final String pluginId;
  final Map setting;
  final String value;
  final bool running;
  final bool enabled;
  final ValueChanged<String> onPick;

  String get _key => '${setting['key']}';

  PickList? _list() {
    final choices = pluginSetupChoices(plugins, pluginId, _key);
    if (choices == null) return null;
    return PickList([
      for (final choice in choices)
        PickItem(
          id: '${choice['id']}',
          name: '${choice['label']}',
          sub: choice['label'] == choice['id'] ? null : '${choice['id']}',
          subMono: true,
        ),
    ]);
  }

  Future<void> _open(BuildContext context) async {
    // The picker loads the list as it opens, so it starts on the latest.
    final outcome = await showItemPicker(
      context,
      title: '${setting['title']}',
      spec: PickSpec(
        key: 'pluginChoices:$pluginId:$_key',
        loader: () async => _list(),
        searchHint: pluginText(context, 'Search'),
        noGroup: '',
        chips: false,
        headings: false,
        byGroupName: false,
      ),
      selected: value.isEmpty ? null : value,
      allowClear: true,
    );
    if (outcome != null && (outcome.id ?? '') != value) {
      onPick(outcome.id ?? '');
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: plugins.setup,
    builder: (context, _, _) {
      final list = _list();
      final run = pluginSetupRun(plugins, pluginId, 'choices:$_key');
      final busy = run?['state'] == 'running';
      final missing = PickField.missing(value, list);
      final status =
          pluginSetupStatus(context, run) ??
          (running && (list == null || list.items.isEmpty)
              ? Text(
                  pluginText(
                    context,
                    'No choices yet. Refresh to look for them.',
                  ),
                )
              : null);
      final description = setting['description'] as String?;
      final field = PickField(
        value: value,
        list: list,
        placeholder: deviceText(context, 'Not set'),
        enabled: enabled,
        onTap: () => _open(context),
      );
      final refresh = busy
          ? IconButton(
              tooltip: pluginText(context, 'Cancel'),
              icon: _spinner(),
              onPressed: () => unawaited(
                plugins
                    .cancelSetup(pluginId, '${run!['run']}')
                    .catchError((_) {}),
              ),
            )
          : IconButton(
              tooltip: pluginText(context, 'Refresh'),
              icon: const Icon(Icons.refresh),
              onPressed: running
                  ? () => startPluginSetup(
                      context,
                      plugins,
                      pluginId,
                      target: 'choices',
                      key: _key,
                    )
                  : null,
            );
      final error = Theme.of(context).colorScheme.error;
      return SettingsRow(
        title: Text('${setting['title']}'),
        stack: true,
        enabled: enabled,
        subtitle: description == null && status == null && !missing
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (missing)
                    Text(
                      pluginText(context, 'This choice is no longer listed.'),
                      style: TextStyle(color: error),
                    ),
                  if (description != null) Text(description),
                  ?status,
                ],
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            tightPane(context)
                ? Flexible(child: field)
                : SizedBox(width: 300, child: field),
            refresh,
          ],
        ),
      );
    },
  );
}

/// Asks the questions a plugin poses during runs started on this device,
/// and cancels those runs when the page closes. The remote admin answers
/// its own.
class PluginSetupPrompts {
  PluginSetupPrompts(this.plugins, this.pluginId);

  final PluginManager plugins;
  final String pluginId;
  final _asked = <String>{};
  BuildContext? _context;

  void attach(BuildContext context) {
    _context = context;
    plugins.setup.addListener(_check);
    _check();
  }

  void _check() {
    final context = _context;
    if (context == null || !context.mounted) return;
    final runs = plugins.setup.value[pluginId]?['runs'] as Map? ?? const {};
    for (final run in runs.values.whereType<Map>()) {
      final confirm = run['confirm'];
      if (run['origin'] != 'device' || confirm is! Map) continue;
      // One dialog per question. A run asks again under a new title.
      final id = '${run['run']}/${confirm['title']}/${confirm['message']}';
      if (!_asked.add(id)) continue;
      unawaited(_ask(context, '${run['run']}', confirm));
    }
  }

  Future<void> _ask(BuildContext context, String run, Map confirm) async {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PluginSetupQuestion(
        plugins: plugins,
        pluginId: pluginId,
        run: run,
        confirm: confirm,
      ),
    );
    if (accepted == null) return;
    try {
      await plugins.answerSetup(pluginId, run, accepted: accepted);
    } catch (_) {
      // The run ended while the question was open.
    }
  }

  void detach() {
    plugins.setup.removeListener(_check);
    _context = null;
    final runs = plugins.setup.value[pluginId]?['runs'] as Map? ?? const {};
    for (final run in runs.values.whereType<Map>()) {
      if (run['origin'] == 'device' && run['state'] == 'running') {
        unawaited(
          plugins.cancelSetup(pluginId, '${run['run']}').catchError((_) {}),
        );
      }
    }
  }
}

/// The plugin's question, closed without an answer once the run moves on.
class _PluginSetupQuestion extends StatefulWidget {
  const _PluginSetupQuestion({
    required this.plugins,
    required this.pluginId,
    required this.run,
    required this.confirm,
  });

  final PluginManager plugins;
  final String pluginId;
  final String run;
  final Map confirm;

  @override
  State<_PluginSetupQuestion> createState() => _PluginSetupQuestionState();
}

class _PluginSetupQuestionState extends State<_PluginSetupQuestion> {
  var _closed = false;

  @override
  void initState() {
    super.initState();
    widget.plugins.setup.addListener(_check);
  }

  @override
  void dispose() {
    widget.plugins.setup.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final runs =
        widget.plugins.setup.value[widget.pluginId]?['runs'] as Map? ??
        const {};
    final waiting = runs.values.whereType<Map>().any(
      (r) => r['run'] == widget.run && r['confirm'] is Map,
    );
    if (!waiting) _close(null);
  }

  void _close(bool? accepted) {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop(accepted);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.confirm['title']}'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(child: Text('${widget.confirm['message']}')),
    ),
    actions: [
      TextButton(
        onPressed: () => _close(false),
        child: Text(pluginText(context, 'Cancel')),
      ),
      FilledButton(
        onPressed: () => _close(true),
        child: Text('${widget.confirm['confirmLabel']}'),
      ),
    ],
  );
}
