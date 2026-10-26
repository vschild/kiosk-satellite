import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../l10n/messages.dart';
import '../managers/music_library/library_model.dart';
import 'kit.dart';
import 'music_library_overlay.dart' show LibraryArt, LibraryMenuText;
import 'toast.dart';

/// The queue of the player the library plays on, to manage rather than
/// just read: the playing track, then what comes next, which drags into a
/// new order, swipes away and plays now or next from its menu. Docked to
/// the right of the library on a roomy screen, the whole library on a
/// smaller one.
class LibraryQueuePanel extends StatefulWidget {
  const LibraryQueuePanel({
    super.key,
    required this.container,
    required this.onClose,
    required this.present,
    this.docked = false,
  });

  final AppContainer container;
  final VoidCallback onClose;
  final bool docked;

  /// Opens the panel's menus and dialogs as the library's own, so they
  /// close with it.
  final Future<T> Function<T>(Future<T> Function() show) present;

  @override
  State<LibraryQueuePanel> createState() => _LibraryQueuePanelState();
}

class _LibraryQueuePanelState extends State<LibraryQueuePanel> {
  AppContainer get c => widget.container;

  /// The rows in the order a drag or a swipe just left them, shown until
  /// the player's queue is read back.
  List<Map<String, Object?>>? _local;
  bool _loading = true;
  String _trackKey = '';
  Timer? _refreshSoon;

  @override
  void initState() {
    super.initState();
    c.sendspin.queueItems.addListener(_queueChanged);
    c.sendspin.nowPlaying.addListener(_trackChanged);
    _trackKey = _key();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    c.sendspin.queueItems.removeListener(_queueChanged);
    c.sendspin.nowPlaying.removeListener(_trackChanged);
    _refreshSoon?.cancel();
    super.dispose();
  }

  String _key() {
    final now = c.sendspin.nowPlaying.value;
    return '${now?['title'] ?? ''}|${now?['artist'] ?? ''}';
  }

  void _queueChanged() {
    if (mounted) setState(() => _local = null);
  }

  /// A new track moves the playing row: read the queue again.
  void _trackChanged() {
    final key = _key();
    if (key == _trackKey) return;
    _trackKey = key;
    _refreshLater();
  }

  void _refreshLater([Duration delay = const Duration(milliseconds: 700)]) {
    _refreshSoon?.cancel();
    _refreshSoon = Timer(delay, () => unawaited(_refresh()));
  }

  Future<void> _refresh() async {
    await c.sendspin.refreshQueue();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _run(Future<bool> Function() edit) async {
    final ok = await edit();
    if (!mounted) return;
    if (!ok) {
      showToast(
        context,
        source: 'music_library',
        title: l10n(context).libraryQueueFailed,
        kind: ToastKind.error,
      );
      setState(() => _local = null);
    }
    // The player settles its queue a moment after the command.
    _refreshLater(const Duration(milliseconds: 400));
  }

  Future<void> _clear() async {
    final s = l10n(context);
    final ok = await widget.present(
      () => showConfirmDialog(
        context,
        title: s.libraryClearQueueTitle,
        message: s.libraryClearQueueMessage,
        confirmLabel: s.libraryClear,
        destructive: true,
      ),
    );
    if (!ok || !mounted) return;
    setState(() => _local = const []);
    await _run(c.sendspin.clearQueue);
  }

  Future<void> _menu(
    BuildContext anchor,
    Map<String, Object?> row, {
    required bool editable,
  }) async {
    final s = l10n(context);
    final id = '${row['id']}';
    final actions = <(IconData, String, Future<void> Function())>[
      (
        Icons.play_arrow_rounded,
        s.libraryPlayNow,
        () => _run(() => c.sendspin.playQueueItem(id)),
      ),
      if (editable) ...[
        (
          Icons.queue_play_next_rounded,
          s.libraryPlayNext,
          () => _run(() => c.sendspin.playQueueItemNext(id)),
        ),
        (
          Icons.remove_circle_outline_rounded,
          s.libraryRemoveFromQueue,
          () => _remove(row),
        ),
      ],
    ];
    final box = anchor.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final chosen = await widget.present(
      () => showMenu<Future<void> Function()>(
        context: context,
        position: RelativeRect.fromRect(
          topLeft & box.size,
          Offset.zero & overlay.size,
        ),
        items: [
          for (final (icon, label, run) in actions)
            PopupMenuItem(
              value: run,
              child: LibraryMenuText(
                container: c,
                child: Row(
                  children: [
                    Icon(icon),
                    const SizedBox(width: 14),
                    Text(label),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    await chosen?.call();
  }

  Future<void> _remove(Map<String, Object?> row) async {
    final rows = [...(_local ?? c.sendspin.queueItems.value)]..remove(row);
    setState(() => _local = rows);
    await _run(() => c.sendspin.removeQueueItem('${row['id']}'));
  }

  @override
  Widget build(BuildContext context) {
    final s = l10n(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = _local ?? c.sendspin.queueItems.value;
    final editable = c.sendspin.queueEditable;
    final current = rows.indexWhere((r) => r['current'] == true);
    final upcoming = rows.sublist(current + 1);
    final heading = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: .8,
      color: scheme.onSurfaceVariant,
    );

    Widget body;
    if (rows.isEmpty) {
      body = Center(
        child: _loading
            ? const CircularProgressIndicator()
            : Text(
                s.mediaNothingQueued,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
      );
    } else {
      body = EdgeFade(
        child: CustomScrollView(
          slivers: [
            if (current >= 0) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                  child: Text(s.mediaNowPlaying.toUpperCase(), style: heading),
                ),
              ),
              SliverToBoxAdapter(
                child: _QueueRow(
                  container: c,
                  row: rows[current],
                  playing: true,
                  onTap: null,
                  onMore: (anchor) =>
                      _menu(anchor, rows[current], editable: false),
                ),
              ),
            ],
            if (upcoming.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
                  child: Text(
                    '${s.mediaUpNext.toUpperCase()}  ·  ${upcoming.length}',
                    style: heading,
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 16),
              sliver: SliverReorderableList(
                itemCount: upcoming.length,
                onReorderItem: (from, to) {
                  if (!editable || to == from) return;
                  final row = upcoming[from];
                  final moved = [...upcoming]
                    ..removeAt(from)
                    ..insert(to, row);
                  setState(
                    () => _local = [...rows.sublist(0, current + 1), ...moved],
                  );
                  final base = current + 1;
                  unawaited(
                    _run(
                      () => c.sendspin.moveQueueItem(
                        '${row['id']}',
                        base + from,
                        base + to,
                      ),
                    ),
                  );
                },
                itemBuilder: (context, i) {
                  final row = upcoming[i];
                  final id = '${row['id']}';
                  final tile = _QueueRow(
                    container: c,
                    row: row,
                    handle: editable
                        ? ReorderableDragStartListener(
                            index: i,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 12,
                              ),
                              child: Icon(
                                Icons.drag_handle_rounded,
                                color: scheme.onSurfaceVariant,
                                semanticLabel: s.libraryReorder,
                              ),
                            ),
                          )
                        : null,
                    onTap: () => _run(() => c.sendspin.playQueueItem(id)),
                    onMore: (anchor) => _menu(anchor, row, editable: editable),
                  );
                  return editable
                      ? Dismissible(
                          key: ValueKey('queue-$id'),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            color: scheme.errorContainer,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 24),
                            child: Icon(
                              Icons.delete_outline_rounded,
                              color: scheme.onErrorContainer,
                            ),
                          ),
                          onDismissed: (_) => unawaited(_remove(row)),
                          child: tile,
                        )
                      : KeyedSubtree(key: ValueKey('queue-$id'), child: tile);
                },
              ),
            ),
          ],
        ),
      );
    }

    final panel = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    s.libraryQueueTitle,
                    style: theme.textTheme.titleLarge?.copyWith(fontSize: 21),
                  ),
                ),
                if (editable && rows.isNotEmpty)
                  TextButton(onPressed: _clear, child: Text(s.libraryClear)),
                IconButton(
                  tooltip: s.libraryCloseQueue,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
        ),
        Expanded(child: body),
      ],
    );
    return Material(
      color: widget.docked ? scheme.surfaceContainerLow : scheme.surface,
      child: widget.docked
          ? DecoratedBox(
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: scheme.outlineVariant)),
              ),
              child: panel,
            )
          : panel,
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.container,
    required this.row,
    required this.onTap,
    required this.onMore,
    this.handle,
    this.playing = false,
  });

  final AppContainer container;
  final Map<String, Object?> row;
  final VoidCallback? onTap;
  final void Function(BuildContext anchor) onMore;
  final Widget? handle;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final s = l10n(context);
    final scheme = Theme.of(context).colorScheme;
    final title = '${row['title'] ?? ''}';
    final artist = '${row['artist'] ?? ''}';
    final art = row['artworkUrl'] as String?;
    final length = formatTrackLength((row['durationMs'] as num?)?.toInt());
    return Material(
      color: playing ? scheme.surfaceContainerHighest : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          // Taller with Text scale, so the rows keep their breathing room.
          height: math.max(60, MediaQuery.textScalerOf(context).scale(60)),
          child: Row(
            children: [
              handle ?? const SizedBox(width: 16),
              LibraryArt(
                container: container,
                item: LibraryItem(
                  id: art ?? title,
                  kind: LibraryKind.track,
                  title: title,
                  art: art,
                ),
                size: 42,
                radius: 6,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: playing ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    if (artist.isNotEmpty)
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (length.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    length,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              Builder(
                builder: (anchor) => IconButton(
                  tooltip: s.libraryMore,
                  icon: const Icon(Icons.more_vert_rounded),
                  color: scheme.onSurfaceVariant,
                  onPressed: () => onMore(anchor),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}
