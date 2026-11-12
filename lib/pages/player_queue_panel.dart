import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../common/widgets/adaptive_text.dart';
import '../common/widgets/confirmation_dialog.dart';
import '../common/widgets/local_panel.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';

// Shared by the mini and expanded player; released with the player service.
final _positions = Expando<_QueuePosition>();

class _QueuePosition {
  String? trackId;
  double fraction = 0;
}

Future<void> showPlayerQueuePanel(BuildContext context, AppRuntime runtime) =>
    showLocalPanel<void>(
      context: context,
      title: '播放列表',
      builder: (_) => _QueuePanel(
        runtime: runtime,
        position: _positions[runtime.player] ??= _QueuePosition(),
      ),
    );

class _QueuePanel extends StatefulWidget {
  const _QueuePanel({required this.runtime, required this.position});
  final AppRuntime runtime;
  final _QueuePosition position;

  @override
  State<_QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<_QueuePanel> {
  ScrollController? _scroll;
  List<Track> _tracks = const [];
  double _rowExtent = 76;
  bool _busy = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scaler = MediaQuery.textScalerOf(context);
    _rowExtent = math.max(76, scaler.scale(16) + scaler.scale(14) + 36);
    if (_scroll != null) return;
    _tracks = widget.runtime.player.queue;
    final anchor = _tracks.indexWhere(
      (track) => track.id == widget.position.trackId,
    );
    final index = anchor >= 0 ? anchor : widget.runtime.player.cursor;
    _scroll = ScrollController(
      initialScrollOffset:
          (math.max(0, index) + (anchor >= 0 ? widget.position.fraction : 0)) *
          _rowExtent,
      keepScrollOffset: false,
    )..addListener(_remember);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _remember();
    });
  }

  void _remember() {
    final scroll = _scroll;
    if (scroll == null || !scroll.hasClients || _tracks.isEmpty) return;
    final row = math.max(0, scroll.offset) / _rowExtent;
    final index = row.floor().clamp(0, _tracks.length - 1);
    widget.position
      ..trackId = _tracks[index].id
      ..fraction = (row - index).clamp(0, 1);
  }

  @override
  void dispose() {
    _remember();
    _scroll?.dispose();
    super.dispose();
  }

  void _showCurrent() {
    final scroll = _scroll, index = widget.runtime.player.cursor;
    if (scroll == null || !scroll.hasClients || index < 0) return;
    final target =
        index * _rowExtent -
        (scroll.position.viewportDimension - _rowExtent) / 2;
    scroll.animateTo(
      target.clamp(0, scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _run(Future<void> Function() command) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await command();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is XmlyException ? error.message : '队列操作失败，请重试';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final confirmed = await showConfirmationDialog(
      context,
      const Text('清空播放队列？'),
    );
    if (confirmed && mounted) {
      await _run(widget.runtime.player.clearQueue);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: LayoutBuilder(
      builder: (context, constraints) => ListenableBuilder(
        listenable: widget.runtime,
        builder: (context, _) {
          final player = widget.runtime.player;
          _tracks = player.queue;
          return Column(
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.max(
                    0,
                    constraints.maxHeight - _rowExtent - 4,
                  ),
                ),
                child: SingleChildScrollView(
                  primary: false,
                  child: Column(
                    children: [
                      ListTile(
                        title: AdaptiveText(
                          '${_tracks.length} 集 · ${player.queueSourceLabel}',
                        ),
                        subtitle: AdaptiveText(player.queueOrderLabel),
                        trailing: TextButton(
                          onPressed: _busy || _tracks.isEmpty ? null : _clear,
                          child: const Text('清空'),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: player.current == null
                                  ? null
                                  : _showCurrent,
                              icon: const Icon(Icons.my_location),
                              label: const Text('回到当前播放'),
                            ),
                            if (player.queueSource == 'album' &&
                                player.sourceAlbumId.isNotEmpty)
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _run(
                                        () => player.refreshAlbumTail(
                                          player.sourceAlbumId,
                                        ),
                                      ),
                                child: const Text('检查专辑更新'),
                              ),
                          ],
                        ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: 4,
                child: _busy ? const LinearProgressIndicator() : null,
              ),
              Expanded(
                child: _tracks.isEmpty
                    ? const Center(child: Text('队列为空'))
                    : Scrollbar(
                        controller: _scroll,
                        child: ReorderableListView.builder(
                          scrollController: _scroll,
                          padding: EdgeInsets.zero,
                          itemExtent: _rowExtent,
                          itemCount: _tracks.length,
                          buildDefaultDragHandles: false,
                          onReorderItem: (from, to) =>
                              _run(() => player.moveQueueItem(from, to)),
                          itemBuilder: (context, index) {
                            final track = _tracks[index];
                            return ListTile(
                              key: ValueKey('queue:$index:${track.id}'),
                              selected: index == player.cursor,
                              minTileHeight: _rowExtent,
                              minLeadingWidth: 32,
                              horizontalTitleGap: 12,
                              leading: ReorderableDragStartListener(
                                index: index,
                                enabled: !_busy,
                                child: Tooltip(
                                  message: '拖动调整顺序',
                                  child: SizedBox(
                                    width: 32,
                                    height: 48,
                                    child: Icon(
                                      index == player.cursor
                                          ? Icons.graphic_eq
                                          : Icons.drag_handle,
                                    ),
                                  ),
                                ),
                              ),
                              title: AdaptiveText(
                                track.title.isEmpty ? track.id : track.title,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              subtitle: track.album.isEmpty
                                  ? null
                                  : AdaptiveText(
                                      track.album,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                              onTap: _busy
                                  ? null
                                  : () =>
                                        _run(() => player.playQueueItem(index)),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: '下一集播放',
                                    icon: const Icon(Icons.playlist_play),
                                    onPressed: _busy || index == player.cursor
                                        ? null
                                        : () => _run(
                                            () => player.playNext(track),
                                          ),
                                  ),
                                  IconButton(
                                    tooltip: '移出队列',
                                    icon: const Icon(Icons.close),
                                    onPressed: _busy
                                        ? null
                                        : () => _run(
                                            () => player.removeQueueItem(index),
                                          ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
