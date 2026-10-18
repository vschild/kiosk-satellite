import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../core/events.dart';
import '../l10n/messages.dart';
import '../managers/browser/url_filter.dart';
import '../managers/settings/definitions.dart';
import 'kit.dart';
import 'settings_screen.dart' show SettingTile;
import 'settings_search.dart';
import 'subpage_icons.dart';

/// Settings > Web Browsing > URL Filter: the addresses the dashboard and
/// external pages may not open, or the only ones they may, each rule with
/// its name, action, pattern and where it applies. Tapping a rule edits it,
/// Add rule opens the same dialog empty. The page follows changes made in
/// the remote admin while it is open.
class UrlFilterCard extends StatefulWidget {
  const UrlFilterCard({super.key, required this.container});

  final AppContainer container;

  @override
  State<UrlFilterCard> createState() => _UrlFilterCardState();
}

class _UrlFilterCardState extends State<UrlFilterCard> {
  AppContainer get c => widget.container;
  StreamSubscription<SettingChanged>? _echo;

  @override
  void initState() {
    super.initState();
    _echo = c.bus.on<SettingChanged>().listen((e) {
      if ((e.key == browserUrlFilter.key ||
              e.key == browserUrlFilterNotice.key) &&
          mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _echo?.cancel();
    super.dispose();
  }

  Future<void> _edit([int? index]) async {
    await showUrlFilterRuleDialog(context, c, index: index);
    if (mounted) setState(() {});
  }

  Future<void> _remove(int index) async {
    await c.commands.execute('removeUrlFilterRule', {'index': index});
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final strings = l10n(context);
    final scheme = Theme.of(context).colorScheme;
    final rules = c.browser.urlFilter;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCard(
          children: [
            IntroRow(
              icon: const SubpageGlyph('URL Filter'),
              title: strings.urlFilterIntroTitle,
              subtitle: strings.urlFilterIntroSub,
            ),
          ],
        ),
        SearchLandingTarget(
          id: 'x:url_filter',
          child: SettingsCard(
            children: [
              for (final (index, rule) in rules.indexed)
                SettingsRow(
                  leading: Icon(
                    rule.isAllow ? Icons.check_circle_outline : Icons.block,
                    color: scheme.primary,
                  ),
                  title: Text(rule.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rule.pattern,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        [
                          if (rule.isAllow) strings.urlFilterActionAllow,
                          urlFilterScopeLabel(context, rule.scope),
                          if (rule.isRegex) strings.urlFilterTypeRegex,
                        ].join(' · '),
                      ),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: strings.commonRemove,
                    onPressed: () => _remove(index),
                  ),
                  onTap: () => _edit(index),
                ),
              ListTile(
                leading: Icon(Icons.add_circle_outline, color: scheme.primary),
                title: Text(
                  strings.urlFilterAdd,
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () => _edit(),
              ),
            ],
          ),
        ),
        SettingsCard(
          children: [
            SettingTile(
              container: c,
              def: browserUrlFilterNotice,
              onChanged: () => setState(() {}),
            ),
          ],
        ),
      ],
    );
  }
}

/// The Applies to choice of a rule, in the kiosk's language.
String urlFilterScopeLabel(BuildContext context, String scope) =>
    switch (scope) {
      urlFilterDashboard => l10n(context).urlFilterScopeDashboard,
      urlFilterExternal => l10n(context).urlFilterScopeExternal,
      _ => l10n(context).urlFilterScopeAll,
    };

/// Why Save refused, in the kiosk's language (see the
/// saveUrlFilterRule command for the codes).
String urlFilterError(BuildContext context, String code) => switch (code) {
  'name' => l10n(context).urlFilterErrorName,
  'pattern' => l10n(context).urlFilterErrorPattern,
  'regex' => l10n(context).urlFilterErrorRegex,
  _ => l10n(context).commonSaveFailed,
};

/// Add a rule, or change the one at [index]. Save checks the rule on the
/// device: a usable one saves and closes, anything else shows why and keeps
/// the dialog open. Answers true when it saved.
Future<bool> showUrlFilterRuleDialog(
  BuildContext context,
  AppContainer container, {
  int? index,
}) async {
  final rules = container.browser.urlFilter;
  final rule = index != null && index < rules.length ? rules[index] : null;
  final name = TextEditingController(text: rule?.name ?? '');
  final pattern = TextEditingController(text: rule?.pattern ?? '');
  var type = rule?.type ?? urlFilterWildcard;
  var scope = rule?.scope ?? urlFilterAll;
  var action = rule?.action ?? urlFilterBlock;
  var saving = false;
  String? error;

  final route = DialogRoute<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final strings = l10n(ctx);
        final scheme = Theme.of(ctx).colorScheme;
        Future<void> save() async {
          setDialogState(() {
            saving = true;
            error = null;
          });
          final result = await container.commands.execute('saveUrlFilterRule', {
            'name': name.text,
            'pattern': pattern.text,
            'type': type,
            'scope': scope,
            'action': action,
            if (rule != null) 'index': index,
          });
          if (!ctx.mounted) return;
          if (result.ok) {
            Navigator.pop(ctx, true);
            return;
          }
          setDialogState(() {
            saving = false;
            error = urlFilterError(ctx, result.error ?? '');
          });
        }

        return AlertDialog(
          title: Text(
            rule == null
                ? strings.urlFilterAddTitle
                : strings.urlFilterEditTitle,
          ),
          content: SizedBox(
            width: 480,
            child: EdgeFade(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 16,
                  children: [
                    LabeledField(
                      label: strings.urlFilterName,
                      child: TextField(
                        controller: name,
                        enabled: !saving,
                        autofocus: rule == null,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(),
                      ),
                    ),
                    LabeledField(
                      label: strings.urlFilterAction,
                      helper: action == urlFilterAllow
                          ? strings.urlFilterActionAllowHint
                          : null,
                      child: KsDropdown<String>(
                        value: action,
                        expand: true,
                        items: [
                          DropdownMenuItem(
                            value: urlFilterBlock,
                            child: Text(strings.urlFilterActionBlock),
                          ),
                          DropdownMenuItem(
                            value: urlFilterAllow,
                            child: Text(strings.urlFilterActionAllow),
                          ),
                        ],
                        onChanged: saving
                            ? null
                            : (v) => setDialogState(() => action = v ?? action),
                      ),
                    ),
                    LabeledField(
                      label: strings.urlFilterType,
                      child: KsDropdown<String>(
                        value: type,
                        expand: true,
                        items: [
                          DropdownMenuItem(
                            value: urlFilterWildcard,
                            child: Text(strings.urlFilterTypeWildcard),
                          ),
                          DropdownMenuItem(
                            value: urlFilterRegex,
                            child: Text(strings.urlFilterTypeRegex),
                          ),
                        ],
                        onChanged: saving
                            ? null
                            : (v) => setDialogState(() => type = v ?? type),
                      ),
                    ),
                    LabeledField(
                      label: strings.urlFilterPattern,
                      helper: type == urlFilterRegex
                          ? strings.urlFilterPatternRegexHint
                          : strings.urlFilterPatternWildcardHint,
                      child: TextField(
                        controller: pattern,
                        enabled: !saving,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        style: const TextStyle(fontFamily: 'monospace'),
                        onSubmitted: (_) => saving ? null : save(),
                        decoration: const InputDecoration(),
                      ),
                    ),
                    LabeledField(
                      label: strings.urlFilterScope,
                      helper: strings.urlFilterScopeHint,
                      child: KsDropdown<String>(
                        value: scope,
                        expand: true,
                        items: [
                          for (final s in urlFilterScopes)
                            DropdownMenuItem(
                              value: s,
                              child: Text(urlFilterScopeLabel(ctx, s)),
                            ),
                        ],
                        onChanged: saving
                            ? null
                            : (v) => setDialogState(() => scope = v ?? scope),
                      ),
                    ),
                    if (error != null)
                      Text(
                        error!,
                        style: Theme.of(
                          ctx,
                        ).textTheme.bodyMedium?.copyWith(color: scheme.error),
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx, false),
              child: Text(strings.commonCancel),
            ),
            FilledButton(
              onPressed: saving ? null : save,
              child: Text(strings.commonSave),
            ),
          ],
        );
      },
    ),
  );
  final saved = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  name.dispose();
  pattern.dispose();
  return saved ?? false;
}
