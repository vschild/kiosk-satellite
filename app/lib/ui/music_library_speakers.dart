import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../l10n/generated/ui_strings.dart';
import '../l10n/messages.dart';
import '../managers/music_library/music_library_manager.dart';
import '../managers/sendspin/remote_player.dart';
import 'kit.dart';
import 'music_library_overlay.dart' show LibraryMenuText;
import 'theme.dart';

/// The Speakers sheet: the player the music plays on, its volume and its
/// group up top, every other speaker of the source below. Tapping one
/// follows it, so the library, the floating player and Now Playing all
/// move to it. Opened from the library's speaker pill and Now Playing's
/// player chip.
///
/// [source] is the source whose speakers are listed: the library's own,
/// or for Now Playing the followed player's.
Future<void> showSpeakersSheet(
  BuildContext context,
  AppContainer c, {
  required String? source,
  String? prompt,
}) {
  final size = MediaQuery.sizeOf(context);
  final narrow = size.width < 640;
  final short = !narrow && size.height < 600;
  final sheet = LibraryMenuText(
    container: c,
    child: _SpeakersSheet(container: c, source: source, prompt: prompt),
  );
  if (narrow) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxHeight: size.height * 0.85),
      builder: (_) => sheet,
    );
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black38,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, short ? 8 : 64, short ? 8 : 20, 8),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Ks.radiusCard),
            clipBehavior: Clip.antiAlias,
            elevation: 6,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 440,
                maxHeight: short ? double.infinity : size.height - 96,
              ),
              child: SizedBox(
                width: 440,
                height: short ? size.height - 16 : null,
                child: sheet,
              ),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
  );
}

class _SpeakersSheet extends StatefulWidget {
  const _SpeakersSheet({
    required this.container,
    required this.source,
    this.prompt,
  });

  final AppContainer container;
  final String? source;
  final String? prompt;

  @override
  State<_SpeakersSheet> createState() => _SpeakersSheetState();
}

class _SpeakersSheetState extends State<_SpeakersSheet> {
  AppContainer get c => widget.container;

  List<LibrarySpeaker>? _speakers;
  String? _note;
  RemoteGroup? _group;
  String _following = '';
  double? _volume;
  final _levels = <String, double>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    c.sendspin.nowPlaying.addListener(_changed);
  }

  @override
  void dispose() {
    c.sendspin.nowPlaying.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final source = widget.source;
    final results = await Future.wait<Object?>([
      if (source != null)
        c.musicLibrary
            .speakers(source)
            .then<Object?>((r) => r)
            .catchError((Object e) => (const <LibrarySpeaker>[], '$e')),
      if (c.sendspin.groupAvailable)
        c.sendspin.fetchGroup().catchError((Object _) => null),
    ]);
    if (!mounted) return;
    setState(() {
      var i = 0;
      if (source != null) {
        final (list, note) = results[i++]! as (List<LibrarySpeaker>, String?);
        _speakers = list;
        _note = list.isEmpty ? note : null;
      } else {
        _speakers = const [];
      }
      if (c.sendspin.groupAvailable) _group = results[i] as RemoteGroup?;
    });
  }

  Future<void> _follow(LibrarySpeaker speaker) async {
    setState(() => _following = speaker.pick);
    final ok = await c.musicLibrary.follow(speaker);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).maybePop();
    } else {
      setState(() => _following = '');
    }
  }

  Future<void> _openGroup() async {
    await showDialog<void>(
      context: context,
      builder: (_) => LibraryMenuText(
        container: c,
        child: _GroupDialog(container: c, initial: _group),
      ),
    );
    if (mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = l10n(context);
    final pick = c.musicLibrary.pick.value;
    // Whether the player Now Playing follows is one of this source's
    // speakers. When it is not, there is nothing to show as playing here
    // yet: the sheet asks for one of the source's speakers instead.
    final source = widget.source;
    final current = source == null || c.musicLibrary.pickIn(source);
    final prompt = widget.prompt ?? (current ? null : s.libraryPickSpeakerHint);
    final speakers = [
      for (final sp in _speakers ?? const <LibrarySpeaker>[])
        if (sp.pick != pick) sp,
    ];
    final members = [
      for (final m in _group?.members ?? const <GroupMember>[])
        if (m.inGroup && m.id != _group?.selfId) m,
    ];
    final grouped = members.isNotEmpty;
    final volume = c.sendspin.volumeAvailable ? c.sendspin.volumeLevel : null;
    final label = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: .8,
      color: scheme.onSurfaceVariant,
    );
    return Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
            child: Text(
              s.librarySpeakers,
              style: theme.textTheme.titleLarge?.copyWith(fontSize: 20),
            ),
          ),
          if (prompt != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
              child: Text(
                prompt,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          Flexible(
            child: EdgeFade(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  if (current)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 12),
                      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              _Disc(
                                icon: grouped
                                    ? Icons.speaker_group_outlined
                                    : Icons.speaker_outlined,
                                color: scheme.secondaryContainer,
                                onColor: scheme.onSecondaryContainer,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      s.libraryPlayingOn.toUpperCase(),
                                      style: label,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _shownName(s),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleMedium,
                                    ),
                                  ],
                                ),
                              ),
                              if (c.sendspin.groupAvailable)
                                OutlinedButton(
                                  onPressed: _openGroup,
                                  child: Text(s.libraryGroup),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          if (volume != null)
                            _VolumeRow(
                              label: grouped
                                  ? s.libraryGroupAll
                                  : s.mediaVolume,
                              strong: grouped,
                              value: _volume ?? volume.toDouble(),
                              onChanged: (v) => setState(() => _volume = v),
                              onChangeEnd: (v) =>
                                  unawaited(c.sendspin.setVolume(v.round())),
                            ),
                          for (final m in members)
                            if (m.volume != null)
                              _VolumeRow(
                                label: m.name,
                                value: _levels[m.id] ?? m.volume!.toDouble(),
                                onChanged: (v) =>
                                    setState(() => _levels[m.id] = v),
                                onChangeEnd: (v) => unawaited(
                                  c.sendspin.setMemberVolume(m.id, v.round()),
                                ),
                              ),
                        ],
                      ),
                    ),
                  if (widget.source != null) ...[
                    if (current)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
                        child: Text(
                          s.libraryOtherSpeakers.toUpperCase(),
                          style: label,
                        ),
                      ),
                    if (_speakers == null)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      )
                    else if (speakers.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                        child: Text(
                          _note ?? s.libraryNoOtherSpeakers,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    else
                      for (final sp in speakers)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 24,
                          ),
                          enabled: sp.available,
                          leading: _Disc(
                            icon: sp.self
                                ? Icons.tablet_android_outlined
                                : Icons.speaker_outlined,
                            color: scheme.surfaceContainerHighest,
                            onColor: scheme.onSurface,
                          ),
                          title: Text(
                            sp.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: sp.self
                              ? Text(s.libraryThisDevice)
                              : sp.available
                              ? null
                              : Text(s.libraryUnavailable),
                          trailing: _following == sp.pick
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : null,
                          onTap: _following.isEmpty ? () => _follow(sp) : null,
                        ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The followed player's name, with its group's other members.
  String _shownName(UiStrings s) {
    final name = c.sendspin.playerChipName;
    final others = [
      for (final m in _group?.members ?? const <GroupMember>[])
        if (m.inGroup && m.id != _group?.selfId) m.name,
    ];
    if (_group != null && !_group!.leads) {
      return s.libraryGroupName(_group!.leaderName, '${others.length}');
    }
    return others.isEmpty ? name : s.libraryGroupName(name, '${others.length}');
  }
}

class _Disc extends StatelessWidget {
  const _Disc({required this.icon, required this.color, required this.onColor});

  final IconData icon;
  final Color color;
  final Color onColor;

  @override
  Widget build(BuildContext context) => Container(
    width: 40,
    height: 40,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Icon(icon, size: 22, color: onColor),
  );
}

class _VolumeRow extends StatelessWidget {
  const _VolumeRow({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    this.strong = false,
  });

  final String label;
  final double value;
  final bool strong;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(0, 100),
              max: 100,
              semanticFormatterCallback: (v) => '$label: ${v.round()}%',
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '${value.round()}%',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// Which players join the followed one: a checkbox each, sent as it is
/// ticked, the way the Now Playing chip's group menu always did.
class _GroupDialog extends StatefulWidget {
  const _GroupDialog({required this.container, this.initial});

  final AppContainer container;
  final RemoteGroup? initial;

  @override
  State<_GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends State<_GroupDialog> {
  RemoteGroup? _group;
  final _pending = <String>{};
  final _asked = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _group = widget.initial;
    unawaited(_load());
  }

  Future<void> _load() async {
    final group = await widget.container.sendspin.fetchGroup().catchError(
      (Object _) => null,
    );
    if (!mounted) return;
    setState(() {
      _group = group ?? _group;
      for (final m in group?.members ?? const <GroupMember>[]) {
        if (_asked[m.id] == m.inGroup) _asked.remove(m.id);
      }
    });
  }

  Future<void> _toggle(GroupMember m, bool want) async {
    setState(() {
      _pending.add(m.id);
      _asked[m.id] = want;
    });
    final ok = await widget.container.sendspin.setGrouped(m.id, want);
    if (!mounted) return;
    if (!ok) _asked.remove(m.id);
    setState(() => _pending.remove(m.id));
    // Music Assistant reports the new group a moment later.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = l10n(context);
    final group = _group;
    final members = RemoteGroup.ordered([
      for (final m in group?.members ?? const <GroupMember>[])
        if (m.id != group?.selfId || !group!.leads)
          GroupMember(
            id: m.id,
            name: m.name,
            inGroup: _asked[m.id] ?? m.inGroup,
            available: m.available,
            volume: m.volume,
          ),
    ]);
    return AlertDialog(
      title: Text(s.libraryGroupWith(group?.leaderName ?? '')),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: 420,
        child: group == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Text(s.libraryGroupHint),
                  ),
                  Flexible(
                    child: EdgeFade(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final m in members)
                            CheckboxListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                              value: m.inGroup,
                              title: Text(m.name),
                              subtitle: m.available
                                  ? null
                                  : Text(s.libraryUnavailable),
                              secondary: _pending.contains(m.id)
                                  ? const SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                      ),
                                    )
                                  : null,
                              onChanged: !m.available || _pending.contains(m.id)
                                  ? null
                                  : (v) => _toggle(m, v ?? false),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s.commonClose),
        ),
      ],
    );
  }
}
