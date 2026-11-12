import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/xmly_experience.dart';
import '../api/xmly_history.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/confirmation_dialog.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import 'catalogue_page.dart';
import 'player_panel.dart';

class _BookmarkNoteDialog extends StatefulWidget {
  const _BookmarkNoteDialog({
    required this.title,
    required this.position,
    required this.note,
    required this.save,
  });
  final String title, note;
  final double position;
  final Future<void> Function(String) save;

  @override
  State<_BookmarkNoteDialog> createState() => _BookmarkNoteDialogState();
}

class _BookmarkNoteDialogState extends State<_BookmarkNoteDialog> {
  late final _note = TextEditingController(text: widget.note);
  final _form = GlobalKey<FormState>();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save(_note.text.trim());
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is XmlyException ? error.message : '备注保存失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('书签备注'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              Text('书签位置 ${playbackTime(widget.position)}'),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('bookmarkNote'),
                controller: _note,
                enabled: !_saving,
                autofocus: true,
                minLines: 2,
                maxLines: 5,
                maxLength: 1000,
                decoration: const InputDecoration(
                  labelText: '备注（可选）',
                  hintText: '例如：重点概念、例题；清空可移除备注',
                ),
                validator: (text) => (text ?? '').characters.length > 1000
                    ? '备注不能超过 1000 字'
                    : null,
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '正在保存…' : '保存备注'),
        ),
      ],
    ),
  );
}

class ListeningPage extends StatefulWidget {
  const ListeningPage({
    required this.runtime,
    required this.onDownload,
    required this.onPlayAlbum,
    super.key,
  });
  final AppRuntime runtime;
  final Future<void> Function(List<Track>) onDownload;
  final AlbumPlayback onPlayAlbum;

  @override
  State<ListeningPage> createState() => _ListeningPageState();
}

class _ListeningPageState extends State<ListeningPage>
    with SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  late final TabController _tabs;
  Timer? _favoriteSearchTimer;
  bool _favoriteSearchPaused = false;
  final _busy = [false, false, false, false];
  final List<String?> _errors = [null, null, null, null];
  final _requests = [0, 0, 0, 0];
  List<UpdateItem> _updates = [];
  List<SubscriptionItem> _subscriptions = [];
  List<Map<String, dynamic>> _cloudHistory = [];
  List<Track> _favorites = [];
  bool _moreFavorites = false;
  int _favoritePage = 0;
  late int _libraryRevision;
  late bool _accountAvailable;
  bool _moreUpdates = false, _moreSubscriptions = false, _acting = false;
  int? _before;
  int _subscriptionPage = 0, _accountEpoch = 0;
  late String _accountKey;
  AppRuntime get _runtime => widget.runtime;
  String get _currentKey => _runtime.client.cacheIdentity;
  bool get _signedIn => _runtime.client.accountAvailable;
  String get _query => _search.text.trim().toLowerCase();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this)
      ..addListener(_searchTabChanged);
    _accountKey = _currentKey;
    _libraryRevision = _runtime.libraryRevision;
    _accountAvailable = _signedIn;
    _runtime.addListener(_runtimeChanged);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant ListeningPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_runtimeChanged);
      _runtime.addListener(_runtimeChanged);
      _resetAccount();
    }
  }

  void _runtimeChanged() {
    if (_accountKey != _currentKey || _accountAvailable != _signedIn) {
      _resetAccount();
    } else if (mounted) {
      if (_libraryRevision != _runtime.libraryRevision) {
        _libraryRevision = _runtime.libraryRevision;
        _refreshLibrary();
      }
      setState(() {});
    }
  }

  void _resetAccount() {
    _favoriteSearchTimer?.cancel();
    _favoriteSearchPaused = false;
    _accountKey = _currentKey;
    _libraryRevision = _runtime.libraryRevision;
    _accountAvailable = _signedIn;
    ++_accountEpoch;
    setState(() {
      _updates = [];
      _subscriptions = [];
      _cloudHistory = [];
      _favorites = [];
      _favoritePage = 0;
      _moreFavorites = false;
      _before = null;
      _subscriptionPage = 0;
      _moreUpdates = false;
      _moreSubscriptions = false;
      for (var i = 0; i < _busy.length; i++) {
        _busy[i] = false;
        _errors[i] = null;
        ++_requests[i];
      }
    });
    _refresh();
  }

  void _refreshLibrary() {
    if (!_signedIn) return;
    unawaited(_loadUpdates(reset: true));
    unawaited(_loadSubscriptions(reset: true));
    unawaited(_loadFavorites(reset: true));
  }

  void _refresh() {
    _refreshLibrary();
    unawaited(_loadHistory());
  }

  bool _valid(int section, int request, int epoch, String key) =>
      mounted &&
      _signedIn &&
      epoch == _accountEpoch &&
      request == _requests[section] &&
      key == _currentKey;

  Future<void> _loadUpdates({bool reset = false}) async {
    if (!_signedIn || (!reset && (_busy[0] || !_moreUpdates))) return;
    final client = _runtime.client,
        epoch = _accountEpoch,
        request = ++_requests[0];
    final key = client.cacheIdentity;
    final before = reset ? null : _before;
    setState(() {
      _busy[0] = true;
      _errors[0] = null;
    });
    try {
      final result = await XmlyExperience(client)
          .updates(before: before, pageSize: 50);
      if (!_valid(0, request, epoch, key)) return;
      final known = reset
          ? <String>{}
          : _updates.map((item) => item.track.id).toSet();
      final added = result.items
          .where((item) => known.add(item.track.id))
          .toList();
      if ((!reset && result.hasMore && added.isEmpty) ||
          (result.hasMore &&
              (result.nextTimeline == null || result.nextTimeline == before))) {
        throw const XmlyException('repeated_page', '更新列表没有前进，请稍后重试');
      }
      if ((reset ? 0 : _updates.length) + added.length > 5000) {
        throw const XmlyException('feed_limit', '已加载 5000 条更新，请搜索或刷新列表');
      }
      setState(() {
        _updates = [if (!reset) ..._updates, ...added];
        _before = result.nextTimeline;
        _moreUpdates = result.hasMore;
      });
    } catch (error) {
      if (_valid(0, request, epoch, key))
        setState(() {
          _errors[0] = error is XmlyException && error.code == 'repeated_page'
              ? '更多更新分页暂不可用，已保留当前列表'
              : _message(error);
          if (error is XmlyException && error.code == 'repeated_page')
            _moreUpdates = false;
        });
    } finally {
      if (_valid(0, request, epoch, key)) setState(() => _busy[0] = false);
    }
  }

  Future<void> _loadSubscriptions({bool reset = false}) async {
    if (!_signedIn || (!reset && (_busy[1] || !_moreSubscriptions))) return;
    final client = _runtime.client,
        epoch = _accountEpoch,
        request = ++_requests[1];
    final key = client.cacheIdentity, page = reset ? 1 : _subscriptionPage + 1;
    setState(() {
      _busy[1] = true;
      _errors[1] = null;
    });
    try {
      final result = await XmlyExperience(client).subscriptions(page: page);
      if (!_valid(1, request, epoch, key)) return;
      final known = reset
          ? <String>{}
          : _subscriptions.map((item) => item.album.id).toSet();
      final added = result.items
          .where((item) => known.add(item.album.id))
          .toList();
      if (!reset && result.hasMore && added.isEmpty) {
        throw const XmlyException('repeated_page', '订阅列表没有前进，请稍后重试');
      }
      if ((reset ? 0 : _subscriptions.length) + added.length > 5000) {
        throw const XmlyException('subscription_limit', '已加载 5000 个订阅');
      }
      setState(() {
        _subscriptions = [if (!reset) ..._subscriptions, ...added];
        _subscriptionPage = page;
        _moreSubscriptions = result.hasMore;
      });
    } catch (error) {
      if (_valid(1, request, epoch, key))
        setState(() => _errors[1] = _message(error));
    } finally {
      if (_valid(1, request, epoch, key)) setState(() => _busy[1] = false);
    }
  }

  Future<void> _loadHistory() async {
    if (!_signedIn) return;
    final client = _runtime.client,
        epoch = _accountEpoch,
        request = ++_requests[2];
    final key = client.cacheIdentity;
    setState(() {
      _busy[2] = true;
      _errors[2] = null;
    });
    try {
      final result = await XmlyHistory(client).records();
      if (_valid(2, request, epoch, key))
        setState(() => _cloudHistory = result);
    } catch (error) {
      if (_valid(2, request, epoch, key))
        setState(() => _errors[2] = _message(error));
    } finally {
      if (_valid(2, request, epoch, key)) setState(() => _busy[2] = false);
    }
  }

  Future<void> _loadFavorites({bool reset = false}) async {
    if (!_signedIn || (!reset && (_busy[3] || !_moreFavorites))) return;
    final client = _runtime.client,
        epoch = _accountEpoch,
        request = ++_requests[3];
    final key = client.cacheIdentity, page = reset ? 1 : _favoritePage + 1;
    setState(() {
      _busy[3] = true;
      _errors[3] = null;
    });
    try {
      final result = await XmlyExperience(client).favorites(page: page);
      if (!_valid(3, request, epoch, key)) return;
      final known = reset
          ? <String>{}
          : _favorites.map((track) => track.id).toSet();
      final added = result.items.where((track) => known.add(track.id)).toList();
      if (!reset && result.hasMore && added.isEmpty) {
        throw const XmlyException('repeated_page', '收藏列表没有前进，请稍后重试');
      }
      if ((reset ? 0 : _favorites.length) + added.length > 5000) {
        throw const XmlyException('favorite_limit', '已加载 5000 条收藏，请搜索或刷新列表');
      }
      setState(() {
        _favorites = [if (!reset) ..._favorites, ...added];
        _favoritePage = page;
        _moreFavorites = result.hasMore;
      });
    } catch (error) {
      if (_valid(3, request, epoch, key)) {
        setState(() => _errors[3] = _message(error));
      }
    } finally {
      if (_valid(3, request, epoch, key)) {
        setState(() => _busy[3] = false);
        _scheduleFavoriteSearch();
      }
    }
  }

  void _searchTabChanged() {
    _scheduleFavoriteSearch();
  }

  void _searchChanged() {
    setState(() => _favoriteSearchPaused = false);
    _scheduleFavoriteSearch();
  }

  void _scheduleFavoriteSearch() {
    _favoriteSearchTimer?.cancel();
    if (!mounted ||
        !_signedIn ||
        _tabs.index != 3 ||
        _query.isEmpty ||
        _favoriteSearchPaused ||
        _busy[3] ||
        !_moreFavorites ||
        _errors[3] != null)
      return;
    _favoriteSearchTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted &&
          _tabs.index == 3 &&
          _query.isNotEmpty &&
          !_favoriteSearchPaused) {
        unawaited(_loadFavorites());
      }
    });
  }

  Widget _favoriteSearchStatus(int matches) {
    final complete =
        _favoritePage > 0 && !_moreFavorites && !_busy[3] && _errors[3] == null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Text(
            complete
                ? '已搜索全部 ${_favorites.length} 条收藏，匹配 $matches 条'
                : '${_favoriteSearchPaused || _errors[3] != null ? '搜索已暂停' : '正在搜索'}：已检索 ${_favorites.length} 条收藏，匹配 $matches 条，尚未检索完整列表',
          ),
          if (!complete)
            TextButton(
              onPressed: () {
                final failed = _errors[3] != null;
                setState(() {
                  _favoriteSearchPaused =
                      !_favoriteSearchPaused && _errors[3] == null;
                  if (!_favoriteSearchPaused) _errors[3] = null;
                });
                if (!_favoriteSearchPaused && failed && !_busy[3]) {
                  unawaited(
                    _loadFavorites(
                      reset: !_moreFavorites || _favoritePage == 0,
                    ),
                  );
                } else {
                  _scheduleFavoriteSearch();
                }
              },
              child: Text(
                _favoriteSearchPaused || _errors[3] != null ? '继续搜索' : '暂停搜索',
              ),
            ),
        ],
      ),
    );
  }

  bool _active(int epoch, String key, String identity) =>
      mounted &&
      epoch == _accountEpoch &&
      key == _currentKey &&
      identity == _runtime.player.libraryIdentity;

  Future<void> _changeLibrary(
    Future<void> Function(XmlyExperience api) change,
  ) async {
    if (!_signedIn) throw const XmlyException('login_required', '请先登录');
    final client = _runtime.client, epoch = _accountEpoch;
    final identity = _runtime.player.libraryIdentity;
    var attempted = false;
    try {
      await _runtime.accounts.runWithAccount(client.identity, (admitted) async {
        if (!_active(epoch, client.cacheIdentity, identity) ||
            !identical(admitted, client) ||
            !client.accountAvailable) {
          throw const XmlyException('account_changed', '账号已变更，请重试');
        }
        attempted = true;
        await change(XmlyExperience(client));
      });
    } catch (error) {
      if (attempted &&
          _active(epoch, client.cacheIdentity, identity) &&
          (error is! XmlyException || !error.definitive)) {
        _runtime.libraryChanged();
      }
      rethrow;
    }
    if (_active(epoch, client.cacheIdentity, identity))
      _runtime.libraryChanged();
  }

  Future<void> _removeBookmark(
    int index,
    Map record,
    int epoch,
    String key,
    String identity,
  ) async {
    if (!_active(epoch, key, identity) ||
        !await showConfirmationDialog(context, const Text('删除此书签？')) ||
        !_active(epoch, key, identity))
      return;
    await _act(
      () => _runtime.storage.transaction((state) {
        if (!_active(epoch, key, identity)) return;
        final library = (state['library'] as Map)[identity] as Map?;
        final bookmarks = library?['bookmarks'] as List? ?? const [];
        if (index >= bookmarks.length ||
            jsonEncode(bookmarks[index]) != jsonEncode(record)) {
          throw const XmlyException('stale_bookmark', '书签列表已变化，请重新选择');
        }
        bookmarks.removeAt(index);
      }),
    );
  }

  Future<void> _editBookmarkNote(
    int index,
    Map record,
    int epoch,
    String key,
    String identity,
  ) async {
    if (_acting || !_active(epoch, key, identity)) return;
    final track = Track.fromJson(xmlyMap(record['track']));
    await showDialog<void>(
      context: context,
      builder: (_) => _BookmarkNoteDialog(
        title: track.title.isEmpty ? track.id : track.title,
        position: record['position'] is num
            ? (record['position'] as num).toDouble()
            : 0,
        note: record['note'] is String ? record['note'] as String : '',
        save: (note) async {
          await _runtime.storage.transaction((state) {
            if (!_active(epoch, key, identity)) {
              throw const XmlyException('account_changed', '账号已变化，请重新打开书签');
            }
            final library = (state['library'] as Map)[identity] as Map?;
            final bookmarks = library?['bookmarks'] as List? ?? const [];
            if (index >= bookmarks.length ||
                jsonEncode(bookmarks[index]) != jsonEncode(record)) {
              throw const XmlyException('stale_bookmark', '书签列表已变化，请重新选择');
            }
            final updated = Map<String, dynamic>.from(bookmarks[index] as Map);
            if (note.isEmpty) {
              updated.remove('note');
            } else {
              updated['note'] = note;
            }
            bookmarks[index] = updated;
          });
          _runtime.changed();
        },
      ),
    );
  }

  static String _message(Object error) =>
      error is XmlyException ? error.message : '加载失败，请重试';

  Future<void> _act(Future<void> Function() action) async {
    if (_acting) return;
    final epoch = _accountEpoch;
    setState(() => _acting = true);
    try {
      await action();
    } catch (error) {
      if (mounted && epoch == _accountEpoch)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_message(error))));
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  void _openAlbum(String id) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AlbumPageView(
        runtime: _runtime,
        albumId: id,
        onDownload: widget.onDownload,
        onPlayAlbum: widget.onPlayAlbum,
      ),
    ),
  );

  bool _matches(Track track, {String extra = ''}) =>
      _query.isEmpty ||
      '${track.title} ${track.album} ${track.artist} ${track.id} $extra'
          .toLowerCase()
          .contains(_query);

  List<_ListeningRecord> _history() {
    final records = <String, _ListeningRecord>{};
    for (final raw in _cloudHistory) {
      final track = Track.fromApi({
        'trackId': raw['track_id'],
        'albumId': raw['album_id'],
        'title': raw['title'],
        'albumTitle': raw['album_title'],
        'duration': raw['duration'],
        'cover_url': raw['cover_url'],
      });
      records[track.id] = _ListeningRecord(
        track,
        (raw['position'] as num).toDouble(),
        ((raw['updated_at'] as num) * 1000).toInt(),
      );
    }
    return records.values.where((row) => _matches(row.track)).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  String _day(int timestamp) {
    if (timestamp <= 0) return '更早';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    if (day == today) return '今天';
    if (day == DateTime(today.year, today.month, today.day - 1)) return '昨天';
    return '${date.year}年${date.month}月${date.day}日';
  }

  Widget _empty(String message) => Padding(
    padding: const EdgeInsets.all(28),
    child: Center(child: Text(message)),
  );

  Widget _sectionState(int section, VoidCallback refresh) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (_busy[section]) const LinearProgressIndicator(),
      if (_errors[section] != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_errors[section]!),
              TextButton(
                onPressed: _busy[section] ? null : refresh,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
    ],
  );

  Widget _trackTile(
    Track track, {
    required VoidCallback? play,
    double position = 0,
    String? removeLabel,
    VoidCallback? remove,
    String positionLabel = '已听',
    String note = '',
    VoidCallback? editNote,
  }) {
    final compact = MediaQuery.sizeOf(context).width < 320;
    final epoch = _accountEpoch, key = _currentKey;
    final identity = _runtime.player.libraryIdentity;
    final duration = track.duration;
    final progress = duration > 0
        ? (position / duration).clamp(0.0, 1.0).toDouble()
        : null;
    return ListTile(
      contentPadding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 16,
        vertical: 6,
      ),
      leading: compact ? null : CoverImage(uri: track.coverUrl, size: 56),
      title: AdaptiveText(track.title.isEmpty ? track.id : track.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (note.isNotEmpty)
            Text(note, maxLines: 3, overflow: TextOverflow.ellipsis),
          if (track.album.isNotEmpty) AdaptiveText(track.album),
          AdaptiveText(
            position > 0
                ? '$positionLabel ${playbackTime(position)}${duration > 0 ? ' / ${playbackTime(duration)}' : ''}'
                : playbackTime(duration),
          ),
          if (position > 0 && progress != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(value: progress, minHeight: 2),
            ),
        ],
      ),
      onTap: _acting || play == null
          ? null
          : () {
              if (_active(epoch, key, identity)) play();
            },
      trailing: PopupMenuButton<String>(
        tooltip: '声音操作',
        enabled: !_acting,
        onSelected: (value) {
          if (!_active(epoch, key, identity)) return;
          switch (value) {
            case 'play':
              play?.call();
              break;
            case 'queue':
              _act(() => _runtime.player.addToQueue(track));
              break;
            case 'next':
              _act(() => _runtime.player.playNext(track));
              break;
            case 'download':
              _act(() => widget.onDownload([track]));
              break;
            case 'album':
              _openAlbum(track.albumId);
              break;
            case 'remove':
              remove?.call();
              break;
            case 'note':
              editNote?.call();
              break;
          }
        },
        itemBuilder: (_) => [
          if (play != null)
            const PopupMenuItem(value: 'play', child: Text('播放')),
          const PopupMenuItem(value: 'queue', child: Text('加入播放队列')),
          const PopupMenuItem(value: 'next', child: Text('下一集播放')),
          const PopupMenuItem(value: 'download', child: Text('下载')),
          if (track.albumId.isNotEmpty)
            const PopupMenuItem(value: 'album', child: Text('查看专辑')),
          if (editNote != null)
            PopupMenuItem(
              value: 'note',
              child: Text(note.isEmpty ? '添加备注' : '编辑备注'),
            ),
          if (remove != null)
            PopupMenuItem(value: 'remove', child: Text(removeLabel ?? '移除')),
        ],
      ),
    );
  }

  Widget _dated<T>(
    List<T> items,
    int Function(T) timestamp,
    Widget Function(T) tile, {
    Widget? footer,
    List<Widget> headers = const [],
    String emptyMessage = '暂无记录',
  }) {
    final rows = <Object>[];
    String? previous;
    for (final item in items) {
      final day = _day(timestamp(item));
      if (day != previous) {
        rows.add(day);
        previous = day;
      }
      rows.add(item as Object);
    }
    return Scrollbar(
      child: CustomScrollView(
        slivers: [
          for (final header in headers) SliverToBoxAdapter(child: header),
          if (items.isEmpty && footer == null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _empty(emptyMessage),
            ),
          SliverList.builder(
            itemCount: rows.length + (footer == null ? 0 : 1),
            itemBuilder: (_, index) {
              if (index == rows.length) return footer!;
              final row = rows[index];
              return row is String
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                      child: AdaptiveText(
                        row,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    )
                  : tile(row as T);
            },
          ),
        ],
      ),
    );
  }

  Widget _subscriptionStrip() {
    final compact = MediaQuery.sizeOf(context).width < 320;
    final epoch = _accountEpoch, key = _currentKey;
    final identity = _runtime.player.libraryIdentity;
    return SizedBox(
      height: compact ? 48 : 98 + MediaQuery.textScalerOf(context).scale(16),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 16,
          vertical: compact ? 0 : 8,
        ),
        itemCount: _subscriptions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, index) {
          final item = _subscriptions[index];
          return SizedBox(
            width: 82,
            child: InkWell(
              onTap: () {
                if (_active(epoch, key, identity)) _openAlbum(item.album.id);
              },
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!compact) CoverImage(uri: item.album.coverUrl, size: 70),
                  if (!compact) const SizedBox(height: 4),
                  AdaptiveText(item.album.title),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _updatesTab() {
    final visible = _updates.where((row) => _matches(row.track)).toList();
    return _dated<UpdateItem>(
      visible,
      (row) => row.publishedAt,
      (row) => _trackTile(
        row.track,
        play: () => _act(
          () => _runtime.player.playUpdates(
            visible.map((item) => item.track).toList(),
            row.track.id,
          ),
        ),
      ),
      headers: [
        if (_subscriptions.isNotEmpty) _subscriptionStrip(),
        if (_updates.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text('当前 API 返回的最近 ${_updates.length} 条更新'),
          ),
        _sectionState(0, () => _loadUpdates(reset: true)),
        if (_subscriptions.isEmpty)
          _sectionState(1, () => _loadSubscriptions(reset: true)),
      ],
      emptyMessage: _signedIn ? '暂无更新' : '登录后查看订阅更新',
      footer: _moreUpdates
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: OutlinedButton(
                  onPressed: _busy[0] ? null : () => _loadUpdates(),
                  child: const Text('加载更多更新'),
                ),
              ),
            )
          : null,
    );
  }

  Widget _subscriptionsTab() {
    final epoch = _accountEpoch, key = _currentKey;
    final identity = _runtime.player.libraryIdentity;
    final items = _subscriptions
        .where(
          (row) =>
              _query.isEmpty ||
              '${row.album.title} ${row.latestTitle} ${row.album.artist}'
                  .toLowerCase()
                  .contains(_query),
        )
        .toList();
    return _dated<SubscriptionItem>(
      items,
      (row) => row.updatedAt,
      (row) => ListTile(
        leading: MediaQuery.sizeOf(context).width < 320
            ? null
            : CoverImage(uri: row.album.coverUrl, size: 56),
        title: AdaptiveText(row.album.title),
        subtitle: AdaptiveText(row.latestTitle),
        trailing: PopupMenuButton<String>(
          tooltip: '专辑操作',
          enabled: !_acting,
          icon: row.unreadCount > 0
              ? Badge(
                  label: Text('${row.unreadCount}'),
                  child: const Icon(Icons.more_vert),
                )
              : const Icon(Icons.more_vert),
          onSelected: (value) async {
            if (!_active(epoch, key, identity)) return;
            if (value == 'album') {
              _openAlbum(row.album.id);
            } else if (value == 'unsubscribe' &&
                await showConfirmationDialog(context, const Text('取消订阅此专辑？')) &&
                _active(epoch, key, identity)) {
              await _act(
                () => _changeLibrary(
                  (api) => api.setSubscribed(row.album.id, subscribed: false),
                ),
              );
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'album', child: Text('查看专辑')),
            PopupMenuItem(value: 'unsubscribe', child: Text('取消订阅')),
          ],
        ),
        onTap: () {
          if (_active(epoch, key, identity)) _openAlbum(row.album.id);
        },
      ),
      headers: [_sectionState(1, () => _loadSubscriptions(reset: true))],
      emptyMessage: _signedIn ? '暂无订阅' : '登录后查看订阅',
      footer: _moreSubscriptions
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: OutlinedButton(
                  onPressed: _busy[1] ? null : () => _loadSubscriptions(),
                  child: const Text('加载更多订阅'),
                ),
              ),
            )
          : null,
    );
  }

  Widget _historyTab() {
    final rows = _history();
    return _dated<_ListeningRecord>(
      rows,
      (row) => row.updatedAt,
      (row) => _trackTile(
        row.track,
        position: row.position,
        play: () => _act(
          () => row.track.albumId.isEmpty
              ? _runtime.player.playTrack(
                  row.track,
                  resumePosition: row.position,
                )
              : _runtime.player.playAlbum(
                  row.track.albumId,
                  row.track.id,
                  track: row.track,
                  resumePosition: row.position,
                ),
        ),
      ),
      headers: [_sectionState(2, _loadHistory)],
      emptyMessage: !_signedIn
          ? '登录后查看云历史记录'
          : _query.isEmpty
          ? '暂无云历史记录'
          : '没有匹配的历史记录',
    );
  }

  Widget _favoritesTab() {
    final epoch = _accountEpoch, key = _currentKey;
    final identity = _runtime.player.libraryIdentity;
    final items = _favorites.where(_matches).toList();
    return Scrollbar(
      child: ListView.builder(
        itemCount: items.length + 2 + (_moreFavorites ? 1 : 0),
        itemBuilder: (_, index) {
          if (index == 0)
            return Column(
              children: [
                _sectionState(3, () => _loadFavorites(reset: true)),
                if (_signedIn && _query.isNotEmpty)
                  _favoriteSearchStatus(items.length),
              ],
            );
          if (index == 1) {
            return items.isEmpty
                ? _empty(
                    !_signedIn
                        ? '登录后查看收藏'
                        : _query.isEmpty
                        ? '暂无收藏'
                        : _moreFavorites ||
                              _busy[3] ||
                              _errors[3] != null ||
                              _favoritePage == 0
                        ? '已加载收藏中没有匹配项'
                        : '全部收藏中没有匹配项',
                  )
                : const SizedBox.shrink();
          }
          if (index == items.length + 2) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: OutlinedButton(
                  onPressed: _busy[3] ? null : () => _loadFavorites(),
                  child: const Text('加载更多收藏'),
                ),
              ),
            );
          }
          final track = items[index - 2];
          return _trackTile(
            track,
            play: () => _act(
              () => track.albumId.isEmpty
                  ? _runtime.player.playTrack(track)
                  : widget.onPlayAlbum(track.albumId, track.id, track: track),
            ),
            removeLabel: '取消收藏',
            remove: () async {
              if (await showConfirmationDialog(
                    context,
                    const Text('取消收藏此声音？'),
                  ) &&
                  _active(epoch, key, identity)) {
                await _act(
                  () => _changeLibrary(
                    (api) => api.setFavorite(track, favorite: false),
                  ),
                );
              }
            },
          );
        },
      ),
    );
  }

  Widget _bookmarksTab() {
    final epoch = _accountEpoch, key = _currentKey;
    final identity = _runtime.player.libraryIdentity;
    final library =
        (_runtime.storage.state['library'] as Map)[identity] as Map?;
    final bookmarks = library?['bookmarks'] as List? ?? const [];
    final rows = <({int index, Map record, Track track, String note})>[];
    for (var i = 0; i < bookmarks.length; i++) {
      final record = bookmarks[i];
      if (record is! Map || record['track'] is! Map) continue;
      try {
        final track = Track.fromJson(xmlyMap(record['track']));
        final note = record['note'] is String ? record['note'] as String : '';
        if (_matches(track, extra: note)) {
          rows.add((index: i, record: record, track: track, note: note));
        }
      } on XmlyException {
        continue;
      } on FormatException {
        continue;
      }
    }
    return _dated(
      rows,
      (row) =>
          row.record['createdAt'] is int ? row.record['createdAt'] as int : 0,
      (row) {
        final (:index, :record, :track, :note) = row;
        final saved = record['position'];
        final position = saved is num && saved.isFinite && saved >= 0
            ? saved.toDouble()
            : 0.0;
        return _trackTile(
          track,
          position: position,
          positionLabel: '书签位置',
          note: note,
          editNote: () =>
              _editBookmarkNote(index, record, epoch, key, identity),
          play: () => _act(
            () => _runtime.player.playTrack(
              track,
              resumePosition: position,
              manualPosition: true,
            ),
          ),
          removeLabel: '删除书签',
          remove: () => _removeBookmark(index, record, epoch, key, identity),
        );
      },
      emptyMessage: _query.isEmpty ? '暂无书签' : '没有匹配的书签',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
                  8,
                  8,
                  8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _search,
                        onChanged: (_) => _searchChanged(),
                        decoration: const InputDecoration(
                          hintText: '搜索更新、订阅、历史、收藏和书签',
                          prefixIcon: Icon(Icons.search),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新收听列表',
                      icon: const Icon(Icons.refresh),
                      onPressed: !_signedIn
                          ? null
                          : () {
                              _runtime.libraryChanged();
                              unawaited(_loadHistory());
                            },
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: const [
                  Tab(text: '听更新'),
                  Tab(text: '订阅'),
                  Tab(text: '历史'),
                  Tab(text: '收藏'),
                  Tab(text: '书签'),
                ],
              ),
            ),
            if (_acting)
              const SliverToBoxAdapter(child: LinearProgressIndicator()),
          ],
          body: TabBarView(
            controller: _tabs,
            children: [
              _updatesTab(),
              _subscriptionsTab(),
              _historyTab(),
              _favoritesTab(),
              _bookmarksTab(),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    ++_accountEpoch;
    _favoriteSearchTimer?.cancel();
    _tabs.removeListener(_searchTabChanged);
    _tabs.dispose();
    _runtime.removeListener(_runtimeChanged);
    _search.dispose();
    super.dispose();
  }
}

class _ListeningRecord {
  const _ListeningRecord(this.track, this.position, this.updatedAt);
  final Track track;
  final double position;
  final int updatedAt;
}
