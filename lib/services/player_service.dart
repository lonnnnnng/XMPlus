import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../api/xmly_client.dart';
import '../api/xmly_history.dart';
import '../models/xmly_models.dart';
import '../storage/app_storage.dart';
import 'account_service.dart';
import 'audio_cache.dart';
import 'audio_driver.dart';
import 'download_service.dart';
import 'media_pipeline.dart';
import 'official_progress.dart';
import 'playback_policy.dart';
import 'usage_ledger.dart';

export 'audio_driver.dart';
export 'playback_policy.dart';

/// An admitted local source, never an upstream authorization URL. The callback
/// releases its cache lease after the device has stopped reading it.
class PlaybackSource {
  PlaybackSource({
    required this.uri,
    required this.identity,
    required this.kind,
    this.requiresReward = false,
    this.taskId,
    this.release,
    bool supportsRanges = true,
    this.cache,
  }) : _supportsRanges = supportsRanges {
    requireLocalAudio(uri);
    if (!const {'online', 'local', 'prepaid'}.contains(kind)) {
      throw ArgumentError('无效播放来源');
    }
  }
  final Uri uri;
  final String identity, kind;
  final bool requiresReward, _supportsRanges;
  final AudioCache? cache;
  bool get supportsRanges => cache?.supportsRanges ?? _supportsRanges;
  final String? taskId;
  final Future<void> Function()? release;
}

class PlayerService {
  PlayerService({
    required this.storage,
    required this.accounts,
    required this.ledger,
    required this.downloads,
    required this.pipeline,
    required this.anonymous,
    AudioDriver? driver,
    this.prepareDownload,
    this.confirmDownload,
    this.exitApplication,
    DateTime Function()? clock,
  }) : _driver = driver ?? MediaKitAudioDriver(),
       _clock = clock ?? DateTime.now,
       policy = PlaybackPolicy(clock: clock) {
    _driverEvents = _driver.snapshots.listen((snapshot) {
      _background(() => _commands.synchronized(() => _observe(snapshot)));
    });
    _downloadEvents = downloads.changes.listen((_) {
      _background(() => _commands.synchronized(_downloadChanged));
    });
    _official = OfficialProgress(
      client: () => _historyClient,
      readPending: (identity) => xmlyMap(_history(identity)['pending']),
      savePending: (identity, pending) => storage.transaction((state) {
        _mutableHistory(state, identity)['pending'] = pending;
      }),
      enabled: () => _syncHistory,
      clock: _clock,
    );
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _background(tick),
    );
  }

  final AppStorage storage;
  final AccountService accounts;
  final UsageLedger ledger;
  final DownloadService downloads;
  final MediaPipeline pipeline;
  final XmlyClient anonymous;
  final AudioDriver _driver;
  final Future<DownloadBatch> Function(List<Track>)? prepareDownload;
  final Future<bool> Function(DownloadBatch)? confirmDownload;
  final Future<void> Function()? exitApplication;
  final DateTime Function() _clock;
  final PlaybackPolicy policy;
  final Lock _commands = Lock();
  final _changes = StreamController<void>.broadcast();
  late final OfficialProgress _official;
  late final StreamSubscription<AudioSnapshot> _driverEvents;
  late final StreamSubscription<void> _downloadEvents;
  Timer? _timer;
  AudioProxy? _proxy;
  PlaybackSource? _source;
  List<Track> _queue = [];
  Completer<void> _requestChanged = Completer<void>();
  int cursor = -1, generation = 0;
  int _request = 0, _epoch = 0, _advanceIntent = 0;
  String sourceAlbumId = '';
  int? albumPage, albumTotal, albumPageSize;
  String queueSource = 'custom';
  String get queueSourceLabel => queueSource == 'updates'
      ? '听更新'
      : queueSource == 'album'
      ? '专辑 $sourceAlbumId'
      : '自选队列';
  String get queueOrderLabel => queueSource == 'updates' ? '倒序（由旧到新）' : '队列顺序';
  bool playing = false, buffering = false;
  double position = 0, duration = 0, rate = 1, volume = 100;
  double _observedPosition = 0;
  String? error, warning, status;
  bool _closed = false, _loaded = false, _actual = false, _atEnd = false;
  bool _awaitingDuration = false, _manualChapterPosition = false;
  bool _sleepStopped = false, _manualPaused = false;
  int _savedAt = 0;
  Future<void>? _tailFlight;
  int? _tailGeneration, _tailRequest;
  final Set<int> _checkedEpochs = {};
  Future<void>? _prefetchFlight;
  int _prefetchEpoch = -1, _prefetchGeneration = -1;
  bool _loading = false;
  int _seekRevision = 0;

  Stream<void> get changes => _changes.stream;
  List<Track> get queue => List.unmodifiable(_queue);
  Track? get current =>
      cursor >= 0 && cursor < _queue.length ? _queue[cursor] : null;
  String get sourceKind => _source?.kind ?? '';
  bool get loading => _loading;
  int get seekRevision => _seekRevision;
  String? get currentTaskId => _source?.taskId;
  String get libraryIdentity => accounts.activeClient?.identity ?? 'anonymous';
  String get _progressIdentity => _source?.identity ?? libraryIdentity;
  XmlyClient? get _historyClient {
    final identity = _source?.identity;
    if (identity == null || identity == 'anonymous') return null;
    try {
      return accounts.clientFor(identity);
    } catch (_) {
      return null;
    }
  }

  Map get _settings => storage.state['settings'] as Map;
  bool get _syncHistory =>
      (_settings['playback'] as Map?)?['syncHistory'] == true;
  PlaybackSettings get effectiveSettings => PlaybackSettings.resolve(
    _settings['playback'] as Map? ?? const {},
    (_settings['albumOverrides'] as Map?)?[current?.albumId] as Map? ??
        const {},
  );
  Map<String, dynamic> _history(String identity) =>
      xmlyMap((storage.state['history'] as Map)[identity]);
  static Map _mutableHistory(Map<String, dynamic> state, String identity) =>
      (state['history'] as Map).putIfAbsent(identity, () => <String, dynamic>{})
          as Map;

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _background(Future<void> Function() action) {
    if (_closed) return;
    unawaited(
      action().catchError((Object failure) async {
        if (failure is DownloadStopped || _closed) return;
        error = _message(failure);
        // A failed journal or admission must never leave audio consuming time.
        await _driver.pause();
        playing = false;
        _notify();
      }),
    );
  }

  static String _message(Object failure) {
    if (failure is XmlyException) {
      switch (failure.code) {
        case 'file_missing':
          return '音频文件已丢失，请重新下载';
        case 'usage_uncertain':
          return '请先核对未确认的听时扣除';
        case 'insufficient_quota':
          return '听时不足，请在官方 App 获取听时';
        case 'rate_limited':
          return '请求过于频繁，请稍后重试';
        case 'confirmation_required':
          return '请先确认边听边下的整集听时';
        case 'invalid_album':
        case 'invalid_page':
        case 'missing_track':
        case 'catalogue_limit':
        case 'duplicate_page':
        case 'catalogue_changed':
          return failure.message;
      }
    }
    return '播放操作未完成，请重试';
  }

  int _newRequest() {
    ++_advanceIntent;
    final previous = _requestChanged;
    _requestChanged = Completer<void>();
    ++_request;
    previous.complete();
    return _request;
  }

  /// Account switching can hold its mutex while quiescing playback. Never keep
  /// the command lock waiting on an admission queued behind that same mutex.
  Future<T> _admission<T>(
    int request,
    Future<T> Function() action, {
    Future<void> Function(T)? discard,
  }) async {
    if (request != _request) throw const DownloadStopped();
    final cancelled = _requestChanged.future;
    final result = action().then((value) async {
      if (request != _request) {
        await discard?.call(value);
        throw const DownloadStopped();
      }
      return value;
    });
    // Future.any observes late errors too; a cancelled admission is not replayed.
    return Future.any([
      result,
      cancelled.then<T>((_) => throw const DownloadStopped()),
    ]);
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_closed) throw StateError('播放器已关闭');
    try {
      await operation();
    } catch (failure) {
      if (failure is DownloadStopped) return;
      error = _message(failure);
      _notify();
      rethrow;
    }
  }

  Future<void> load() async {
    if (_loaded) return;
    final restored = PlaybackQueue.fromJson(storage.state['queue']);
    if (restored.needsRepair) {
      await storage.transaction((state) => state['queue'] = restored.toJson());
    }
    _queue = restored.tracks;
    cursor = restored.cursor;
    sourceAlbumId = restored.sourceAlbumId;
    queueSource = restored.source;
    albumPage = restored.albumPage;
    albumTotal = restored.albumTotal;
    albumPageSize = restored.albumPageSize;
    playing = false;
    buffering = false;
    _actual = false;
    _atEnd = false;
    _sleepStopped = false;
    duration = current?.duration ?? 0;
    position = current == null ? 0 : _localPosition(current!).$1;
    _loaded = true;
    await applySettings();
    _notify();
  }

  /// Restore has already atomically committed queue data. Do not save the old
  /// in-memory queue or touch media/network while reading that committed state.
  Future<void> reload() async {
    if (_closed || _source != null || playing) {
      throw StateError('请先暂停并释放播放来源');
    }
    _newRequest();
    ++generation;
    ++_epoch;
    _loaded = false;
    await load();
    error = null;
    warning = null;
    status = null;
    _notify();
  }

  Future<AlbumPage> _albumPage(
    XmlyClient client,
    String album,
    int page,
  ) async {
    if (page < 1 || page > 5000 ~/ xmlyAlbumPageSize) {
      throw const XmlyException('catalogue_limit', '专辑播放队列最多 5000 集');
    }
    final result = await client.album(
      album,
      page: page,
      pageSize: xmlyAlbumPageSize,
      ascending: true,
    );
    if (result.total < 0 || result.total > 5000) {
      throw const XmlyException('catalogue_limit', '专辑播放队列最多 5000 集');
    }
    final tracks = result.tracks, offset = (page - 1) * xmlyAlbumPageSize;
    if (result.page != page ||
        result.pageSize != xmlyAlbumPageSize ||
        result.album.id != album ||
        tracks.length > xmlyAlbumPageSize ||
        tracks.any((track) => track.albumId != album) ||
        tracks.map((track) => track.id).toSet().length != tracks.length ||
        (tracks.isNotEmpty &&
            result.total > 0 &&
            result.total < offset + tracks.length) ||
        (tracks.length < xmlyAlbumPageSize &&
            result.total > offset + tracks.length)) {
      throw const XmlyException('invalid_album', '专辑分页不完整，请刷新重试');
    }
    int? previousOrder;
    for (var index = 0; index < tracks.length; index++) {
      final track = tracks[index], order = xmlyPositive(tracks[index].orderNo);
      if (track.officialPosition != offset + index + 1 ||
          (previousOrder != null && order != null && order <= previousOrder)) {
        throw const XmlyException('invalid_album', '专辑分页顺序无效，请刷新重试');
      }
      previousOrder = order ?? previousOrder;
    }
    return result;
  }

  Future<void> _saveQueue(
    List<Track> tracks,
    int index,
    String album, {
    String? source,
    int? page,
    int? total,
    int pageSize = xmlyAlbumPageSize,
  }) async {
    final next = PlaybackQueue(
      tracks: tracks,
      cursor: index,
      sourceAlbumId: album,
      source: source,
      albumPage: page,
      albumTotal: total,
      albumPageSize: page == null ? null : pageSize,
    );
    await storage.transaction((state) => state['queue'] = next.toJson());
    queueSource = next.source;
    albumPage = next.albumPage;
    albumTotal = next.albumTotal;
    albumPageSize = next.albumPageSize;
  }

  Future<void> playAlbum(
    String albumId,
    String trackId, {
    int? page,
    Track? track,
  }) => _run(() async {
    final album = xmlyIdentifier(albumId),
        id = 'xmly:${xmlyIdentifier(trackId)}';
    if (page != null && (page < 1 || page > 5000 ~/ xmlyAlbumPageSize)) {
      throw XmlyException(
        'invalid_page',
        '播放页码范围为 1 到 ${5000 ~/ xmlyAlbumPageSize}',
      );
    }
    final intent = ++generation, request = _newRequest();
    final client = accounts.activeClient ?? anonymous;
    final hint =
        track ??
        (page == null
            ? await _admission(request, () => client.track(id))
            : null);
    if (hint != null &&
        (hint.id != id || hint.albumId.isNotEmpty && hint.albumId != album)) {
      throw const XmlyException('missing_track', '声音与专辑不匹配，请刷新重试');
    }
    final ordinal = hint?.officialPosition ?? xmlyPositive(hint?.orderNo);
    final selectedPage =
        page ?? (ordinal == null ? 1 : (ordinal - 1) ~/ xmlyAlbumPageSize + 1);
    final result = await _admission(
      request,
      () => _albumPage(client, album, selectedPage),
    );
    final tracks = result.tracks,
        index = result.tracks.indexWhere((track) => track.id == id);
    if (index < 0) {
      throw const XmlyException('missing_track', '此页没有找到所选声音，请刷新专辑后重试');
    }
    await _commands.synchronized(() async {
      if (intent != generation ||
          request != _request ||
          accounts.admissionPaused ||
          !identical(client, accounts.activeClient ?? anonymous))
        return;
      await _stopSource();
      await _saveQueue(
        tracks,
        index,
        album,
        page: selectedPage,
        total: result.total,
      );
      _queue = tracks;
      cursor = index;
      sourceAlbumId = album;
      await _openCurrent(request);
    });
  });

  /// The visible feed is newest-first. Reverse that exact snapshot, preserving
  /// timestamp ties and mixed-album order; never reload an album to build it.
  Future<void> playUpdates(List<Track> displayedLatestFirst, String trackId) =>
      _run(() async {
        final tracks = displayedLatestFirst.reversed.toList(growable: false);
        final id = 'xmly:${xmlyIdentifier(trackId)}';
        final index = tracks.indexWhere((track) => track.id == id);
        if (tracks.isEmpty ||
            tracks.length > 5000 ||
            index < 0 ||
            tracks.map((track) => track.id).toSet().length != tracks.length) {
          throw const XmlyException('invalid_feed', '更新列表无效，请刷新后重试');
        }
        final request = _newRequest();
        ++generation;
        await _commands.synchronized(() async {
          if (request != _request) return;
          await _stopSource();
          await _saveQueue(tracks, index, '', source: 'updates');
          _queue = tracks;
          cursor = index;
          sourceAlbumId = '';
          await _openCurrent(request);
        });
      });

  Future<void> playTrack(Track track, {double? resumePosition}) =>
      _run(() async {
        final request = _newRequest();
        ++generation;
        await _commands.synchronized(() async {
          if (request != _request) return;
          await _stopSource();
          await _saveQueue([track], 0, '');
          _queue = [track];
          cursor = 0;
          sourceAlbumId = '';
          await _openCurrent(request, resumePosition: resumePosition);
        });
      });
  Future<void> playQueueItem(int index) => _run(() async {
    RangeError.checkValidIndex(index, _queue);
    final request = _newRequest();
    await _commands.synchronized(() => _select(index, request));
  });
  Future<void> _select(int index, int request) async {
    if (request != _request) return;
    RangeError.checkValidIndex(index, _queue);
    await _stopSource();
    await _saveQueue(
      _queue,
      index,
      sourceAlbumId,
      source: queueSource,
      page: albumPage,
      total: albumTotal,
      pageSize: albumPageSize ?? xmlyAlbumPageSize,
    );
    cursor = index;
    await _openCurrent(request);
  }

  Future<void> playCurrent() => _run(() async {
    final request = _newRequest();
    await _commands.synchronized(() => _openCurrent(request));
  });
  Future<void> previous() async {
    if (cursor > 0)
      await playQueueItem(cursor - 1);
    else if (current != null)
      await replay();
  }

  Future<void> next() => _run(() async {
    if (cursor + 1 < _queue.length) {
      await playQueueItem(cursor + 1);
      return;
    }
    if (current == null) return;
    if (queueSource != 'album' || sourceAlbumId.isEmpty) {
      await pause();
      status = '已听到最新一集';
      _notify();
      return;
    }
    final intent = ++_advanceIntent,
        expectedGeneration = generation,
        epoch = _epoch;
    final id = current!.id, album = sourceAlbumId;
    // The tail commits under _commands; never join its network work under that lock.
    await refreshAlbumTail(album);
    await _commands.synchronized(() async {
      if (intent != _advanceIntent ||
          expectedGeneration != generation ||
          epoch != _epoch ||
          current?.id != id ||
          _sleepStopped)
        return;
      final sleep = policy.onChapterEnd() ?? policy.pollSleep();
      if (sleep != null) {
        await _sleep(sleep);
        return;
      }
      if (cursor + 1 < _queue.length)
        await _select(cursor + 1, _newRequest());
      else {
        await _pause();
        status = '已听到最新一集';
        _notify();
      }
    });
  });
  Future<void> replay() => _run(() async {
    final request = _newRequest();
    await _commands.synchronized(
      () => _openCurrent(request, resumePosition: 0, manualReplay: true),
    );
  });

  (double, int) _localPosition(Track track) {
    final entry = xmlyMap(
      xmlyMap(_history(_progressIdentity)['positions'])[track.id],
    );
    final value = entry['position'];
    return (
      value is num && value.isFinite && value >= 0 ? value.toDouble() : 0,
      entry['updatedAt'] is int ? entry['updatedAt'] as int : 0,
    );
  }

  Future<double> _resumePosition(Track track) async {
    final local = _localPosition(track);
    final client = _historyClient;
    if (!_syncHistory || client == null) return local.$1;
    try {
      final cloud = await XmlyHistory(client, clock: _clock).progress(
        albumId: track.albumId,
        trackId: track.albumId.isEmpty ? track.id : '',
      );
      if (cloud != null &&
          cloud['track_id'] == track.id &&
          (cloud['updated_at'] as num) * 1000 > local.$2) {
        return (cloud['position'] as num).toDouble();
      }
    } catch (_) {
      warning = '云进度暂不可用，已使用本地进度';
    }
    return local.$1;
  }

  Future<void> _openCurrent(
    int request, {
    double? resumePosition,
    bool manualReplay = false,
    String? localTaskId,
  }) async {
    if (current == null || request != _request) return;
    _loading = true;
    try {
      await _openCurrentSource(
        request,
        resumePosition: resumePosition,
        manualReplay: manualReplay,
        localTaskId: localTaskId,
      );
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<void> _openCurrentSource(
    int request, {
    double? resumePosition,
    bool manualReplay = false,
    String? localTaskId,
  }) async {
    final track = current;
    if (track == null || request != _request) return;
    final saved = resumePosition;
    final previousTaskId = _source?.taskId;
    final preferredPrepaid =
        previousTaskId != null &&
            sourceKind == 'prepaid' &&
            downloads.task(previousTaskId).track.id == track.id
        ? previousTaskId
        : null;
    await _stopSource();
    if (request != _request) return;
    status = '正在准备音频';
    error = null;
    warning = null;
    _notify();
    final settings = effectiveSettings;
    final source = await _admission(
      request,
      () => localTaskId != null
          ? _local(downloads.task(localTaskId))
          : _prepare(
              track,
              settings.listenAndDownload,
              request,
              existingTaskId: preferredPrepaid,
            ),
      discard: (source) async {
        await source.release?.call();
      },
    );
    if (request != _request || _closed) {
      await source.release?.call();
      return;
    }
    _source = source;
    try {
      final resume =
          saved ??
          await _admission(request, () => _resumePosition(track)) ??
          0.0;
      if (request != _request) {
        await _release();
        return;
      }
      if (source.requiresReward &&
          source.kind == 'online' &&
          ledger.isBlocked(source.identity)) {
        throw const XmlyException('usage_uncertain', '请先核对听时');
      }
      await ledger.startWatch(
        identity: source.identity,
        trackId: track.id,
        requiresReward: source.requiresReward,
        prepaid: source.kind != 'online',
        speed: settings.speed,
      );
      _atEnd = false;
      _actual = false;
      _sleepStopped = false;
      _manualPaused = false;
      _checkedEpochs.clear();
      final epoch = ++_epoch;
      duration = track.duration;
      _awaitingDuration = duration <= 0;
      _manualChapterPosition = manualReplay;
      position = policy.start(
        duration: duration,
        resumePosition: resume,
        settings: settings,
        manualReplay: manualReplay,
      );
      warning = policy.warning ?? warning;
      rate = settings.speed;
      volume = settings.volume;
      await _driver.open(source.uri, epoch: epoch);
      await _driver.setRate(rate);
      await _driver.setVolume(volume);
      if (position > 0) await _driver.seek(position);
      if (request != _request) {
        await _stopSource();
        return;
      }
      _official.start('player', track, source.identity);
      await _driver.play();
      status = source.supportsRanges ? null : '此音频暂不支持快速跳转，跳转时可能需要等待';
      _notify();
    } catch (_) {
      await _driver.stop();
      await _release();
      rethrow;
    }
  }

  Future<PlaybackSource> _local(DownloadTask task) async {
    if (task.state != DownloadState.completed ||
        task.finalPath == null ||
        !await File(task.finalPath!).exists()) {
      throw const XmlyException('file_missing', '音频文件已丢失，请重新下载');
    }
    return PlaybackSource(
      uri: File(task.finalPath!).absolute.uri,
      identity: task.accountIdentity,
      kind: 'local',
      taskId: task.id,
    );
  }

  Future<DownloadTask?> _downloaded(Track track) async {
    for (final task in downloads.tasks) {
      if (task.track.id == track.id &&
          task.state == DownloadState.completed &&
          task.finalPath != null &&
          await File(task.finalPath!).exists())
        return task;
    }
    return null;
  }

  Future<PlaybackSource> _prepare(
    Track track,
    bool save,
    int request, {
    String? existingTaskId,
  }) async {
    final identity = libraryIdentity;
    final local = await _downloaded(track);
    if (local != null) return _local(local);
    final missingDownload = downloads.tasks.any(
      (task) =>
          task.track.id == track.id && task.state == DownloadState.completed,
    );
    if (!missingDownload && (save || existingTaskId != null)) {
      return _prepareDownload(track, request, existingTaskId: existingTaskId);
    }
    final quality = (_settings['download'] as Map?)?['quality'] as String?;
    Future<ResolvedAudio> resolve(XmlyClient client) =>
        client.resolve(track.id, quality: quality, preferCached: true);
    final audio = identity == 'anonymous'
        ? await resolve(anonymous)
        : await accounts.runWithAccount(identity, resolve);
    if (_closed || request != _request) throw const DownloadStopped();
    if (audio.accountIdentity != identity || audio.track.id != track.id) {
      throw const XmlyException('identity_mismatch', '声音授权与账号不符');
    }
    final reward = audio.requiresReward;
    if (reward && ledger.isBlocked(identity)) {
      throw const XmlyException('usage_uncertain', '请先核对听时');
    }
    final directory = p.join(
      storage.directory,
      'playback-cache',
      identity,
      track.number,
      const Uuid().v4(),
    );
    final cache = await AudioCache.open(
      directory: directory,
      audio: audio,
      refresh: (isActive) {
        Future<ResolvedAudio> refresh(XmlyClient client) {
          if (!isActive() || _closed || request != _request) {
            throw const DownloadStopped();
          }
          return client.resolve(track.id, force: true, quality: quality);
        }

        return identity == 'anonymous'
            ? refresh(anonymous)
            : accounts.runWithAccount(identity, refresh);
      },
    );
    try {
      _proxy ??= await AudioProxy.start();
      return PlaybackSource(
        uri: _proxy!.mount(cache),
        identity: identity,
        kind: 'online',
        requiresReward: reward,
        cache: cache,
        release: () async {
          await _proxy?.unmount(cache);
          await cache.close();
          final folder = Directory(directory);
          if (await folder.exists()) await folder.delete(recursive: true);
        },
      );
    } catch (_) {
      await cache.close();
      rethrow;
    }
  }

  Future<PlaybackSource> _prepareDownload(
    Track track,
    int request, {
    String? existingTaskId,
  }) async {
    String? retained;
    try {
      var task = existingTaskId != null
          ? downloads.task(existingTaskId)
          : downloads.tasks
                .where(
                  (item) =>
                      item.accountIdentity == libraryIdentity &&
                      item.track.id == track.id &&
                      item.deduplicates,
                )
                .firstOrNull;
      if (task == null) {
        final prepare = prepareDownload;
        final confirm = confirmDownload;
        if (prepare == null || confirm == null) {
          throw const XmlyException('confirmation_required', '请先确认边听边下');
        }
        warning = '边听边下按整集预扣听时，已产生的在线听时不会抵扣';
        _notify();
        final batch = await prepare([track]);
        if (request != _request || !await confirm(batch)) {
          throw const XmlyException('cancelled', '已取消边听边下');
        }
        await downloads.enqueue(
          batch,
          confirmed: true,
          beforeStart: (items) async {
            if (request != _request) throw const DownloadStopped();
            final selected = items
                .where((item) => item.track.id == track.id)
                .firstOrNull;
            if (selected != null) {
              retained = selected.id;
              pipeline.retainTask(selected.id);
            }
          },
        );
        task = downloads.tasks
            .where(
              (item) =>
                  item.accountIdentity == batch.accountIdentity &&
                  item.track.id == track.id &&
                  item.deduplicates,
            )
            .firstOrNull;
      }
      if (task == null) throw const XmlyException('task_missing', '没有可用的下载任务');
      if (retained == null) {
        retained = task.id;
        pipeline.retainTask(task.id);
      }
      if (task.state == DownloadState.completed) {
        final source = await _local(task);
        await pipeline.releaseTask(retained!);
        retained = null;
        return source;
      }
      downloads.prioritize(task.id);
      if (!task.active) await downloads.resume(task.id);
      AudioCache? cache;
      while ((cache = pipeline.taskCache(task.id)) == null) {
        if (request != _request || _closed) throw const DownloadStopped();
        final latest = downloads.task(task.id);
        if (latest.state == DownloadState.completed) {
          final source = await _local(latest);
          await pipeline.releaseTask(retained!);
          retained = null;
          return source;
        }
        if (!latest.active)
          throw const XmlyException('download_stopped', '下载尚未就绪，请检查任务');
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      _proxy ??= await AudioProxy.start();
      final leased = retained!;
      final mounted = cache!;
      final source = PlaybackSource(
        uri: _proxy!.mount(mounted),
        identity: task.accountIdentity,
        kind: 'prepaid',
        taskId: task.id,
        cache: mounted,
        release: () async {
          await _proxy?.unmount(mounted);
          await pipeline.releaseTask(leased);
        },
      );
      retained = null;
      return source;
    } finally {
      if (retained != null) await pipeline.releaseTask(retained!);
    }
  }

  Future<void> playLocal(String taskId) => _run(() async {
    final task = downloads.task(taskId);
    // Check before replacing the user's queue.
    await _local(task);
    final request = _newRequest();
    ++generation;
    await _commands.synchronized(() async {
      if (request != _request) return;
      await _stopSource();
      await _saveQueue([task.track], 0, '');
      _queue = [task.track];
      cursor = 0;
      sourceAlbumId = '';
      await _openCurrent(request, localTaskId: taskId);
    });
  });
  Future<void> continueListening() async {
    final history = _history(libraryIdentity);
    final id = history['lastTrackId'];
    final entry = xmlyMap(xmlyMap(history['positions'])[id]);
    if (entry['track'] is! Map)
      throw const XmlyException('history_missing', '暂无收听记录');
    final track = Track.fromJson(xmlyMap(entry['track']));
    await playTrack(track);
  }

  Future<void> pause() {
    ++_advanceIntent;
    _manualPaused = true;
    return _run(() => _commands.synchronized(() => _pause()));
  }

  Future<void> _pause({bool sleep = false}) async {
    await _driver.pause();
    playing = false;
    await ledger.observe(playing: false, buffering: buffering, speed: rate);
    await _saveProgress(terminal: true);
    final task = currentTaskId;
    final download = _settings['download'] as Map? ?? const {};
    if (task != null &&
        (sleep
            ? download['continueDownloadAfterSleep'] != true
            : download['pauseDownloadWithPlayback'] == true))
      await downloads.pause(task);
    _notify();
  }

  Future<void> resume() => _run(() async {
    final request = _newRequest();
    await _commands.synchronized(() async {
      if (_source == null || _atEnd) {
        await _openCurrent(request);
        return;
      }
      if (sourceKind != 'local' &&
          (_source!.taskId != null || await _downloaded(current!) != null)) {
        final saved = position;
        await _openCurrent(request, resumePosition: saved);
        return;
      }
      _official.start('player', current!, _progressIdentity);
      _manualPaused = false;
      final previousError = error;
      await _driver.play();
      // long: 音频焦点恢复后清除上次播放失败，保留等待期间新到达的设备错误。
      if (request == _request && identical(error, previousError)) error = null;
      _notify();
    });
  });
  Future<void> switchToLocal() => _run(() async {
    final track = current;
    if (track == null) return;
    final task = await _downloaded(track);
    if (task == null) throw const XmlyException('file_missing', '请先下载本集');
    final request = _newRequest(), saved = position;
    await _commands.synchronized(
      () => _openCurrent(request, resumePosition: saved, localTaskId: task.id),
    );
  });
  Future<void> seek(double seconds) {
    ++_advanceIntent;
    return _run(
      () => _commands.synchronized(() async {
        if (!seconds.isFinite || seconds < 0) throw ArgumentError('播放位置无效');
        if (_source == null) return;
        _manualChapterPosition = true;
        position = policy.manualSeek(seconds);
        await _driver.seek(position);
        ++_seekRevision;
        // Seeking itself is never an actual listening observation or history POST.
        _notify();
      }),
    );
  }

  Future<void> seekBackward() => seek(
    (position - effectiveSettings.seekBackwardSeconds)
        .clamp(0, double.infinity)
        .toDouble(),
  );
  Future<void> seekForward() =>
      seek(position + effectiveSettings.seekForwardSeconds);

  void _prefetchNext(AudioSnapshot snapshot) {
    final source = _source;
    if (source == null ||
        _atEnd ||
        _sleepStopped ||
        !snapshot.playing ||
        snapshot.buffering ||
        snapshot.duration <= 0 ||
        snapshot.position / snapshot.duration <= 0.8 ||
        cursor < 0 ||
        effectiveSettings.loopMode == 'single' ||
        policy.sleepWaitingForEnd ||
        policy.sleepRequest?.mode == SleepMode.endOfTrack ||
        _prefetchFlight != null ||
        accounts.admissionPaused ||
        (_prefetchEpoch == _epoch && _prefetchGeneration == generation))
      return;
    final epoch = _epoch, expectedGeneration = generation, request = _request;
    final advanceIntent = _advanceIntent;
    final quality = (_settings['download'] as Map?)?['quality'] as String?;
    _prefetchEpoch = epoch;
    _prefetchGeneration = expectedGeneration;
    bool active() =>
        !_closed &&
        !_atEnd &&
        !_sleepStopped &&
        playing &&
        request == _request &&
        epoch == _epoch &&
        advanceIntent == _advanceIntent &&
        expectedGeneration == generation &&
        identical(_source, source) &&
        !accounts.admissionPaused;
    final flight = () async {
      try {
        if (cursor + 1 >= _queue.length &&
            queueSource == 'album' &&
            sourceAlbumId == current?.albumId &&
            ((_tailFlight != null &&
                    _tailGeneration == generation &&
                    _tailRequest == request) ||
                _checkedEpochs.add(epoch))) {
          await refreshAlbumTail(sourceAlbumId);
        }
        if (!active() || cursor + 1 >= _queue.length) return;
        final next = _queue[cursor + 1];
        if (await _downloaded(next) != null || !active()) return;
        Future<void> resolve(XmlyClient client) async {
          if (active())
            await client.resolve(next.id, quality: quality, preferCached: true);
        }

        final identity = libraryIdentity;
        if (identity == 'anonymous') {
          await resolve(anonymous);
        } else {
          await accounts.runWithAccount(identity, resolve);
        }
      } catch (_) {
        // A speculative page or authorization failure never pauses this chapter.
      }
    }();
    _prefetchFlight = flight;
    unawaited(
      flight.whenComplete(() {
        if (identical(_prefetchFlight, flight)) _prefetchFlight = null;
      }),
    );
  }

  Future<void> _observe(AudioSnapshot snapshot) async {
    if (_closed || _source == null || snapshot.epoch != _epoch) return;
    if (snapshot.error != null)
      throw const XmlyException('audio_device', '音频播放失败');
    if (!snapshot.position.isFinite ||
        snapshot.position < 0 ||
        !snapshot.duration.isFinite ||
        snapshot.duration < 0)
      return;
    playing = snapshot.playing;
    buffering = snapshot.buffering;
    position = snapshot.position;
    _observedPosition = snapshot.position;
    if (snapshot.duration > 0) duration = snapshot.duration;
    if (_awaitingDuration && duration > 0) {
      _awaitingDuration = false;
      final initial = policy.start(
        duration: duration,
        resumePosition: position,
        settings: effectiveSettings,
        manualReplay: _manualChapterPosition,
      );
      if (initial != position) {
        position = initial;
        await _driver.seek(initial);
      }
    }
    if (playing && !buffering) _actual = true;
    await ledger.observe(playing: playing, buffering: buffering, speed: rate);
    if (_actual)
      await _official.observe(
        'player',
        _observedPosition,
        actual: playing && !buffering,
      );
    final sleep = policy.pollSleep();
    if (sleep != null) {
      await _sleep(sleep);
      return;
    }
    final finished = policy.observe(
      position,
      duration: duration,
      completed: snapshot.completed && _actual,
    );
    warning = policy.warning ?? warning;
    if (finished && _actual && !_atEnd)
      await _finish();
    else
      _prefetchNext(snapshot);
    _notify();
  }

  /// Polls sleep deadlines and persists actual listening progress.
  Future<void> tick() => _commands.synchronized(() async {
    if (_closed) return;
    final sleep = policy.pollSleep();
    if (sleep != null) {
      await _sleep(sleep);
      return;
    }
    if (_source != null) {
      if (!_source!.supportsRanges) status = '此音频暂不支持快速跳转，跳转时可能需要等待';
      await ledger.observe(playing: playing, buffering: buffering, speed: rate);
      if (_actual && _clock().millisecondsSinceEpoch - _savedAt >= 5000) {
        await _saveProgress();
      }
    }
    _notify();
  });
  Future<void> _finish() async {
    _atEnd = true;
    final sleep = policy.onChapterEnd();
    await _pause();
    if (sleep != null) {
      await _sleep(sleep);
      return;
    }
    if (_manualPaused) return;
    if (effectiveSettings.loopMode == 'single') {
      await _openCurrent(_newRequest(), resumePosition: 0, manualReplay: true);
      return;
    }
    if (queueSource == 'album' &&
        cursor == _queue.length - 1 &&
        sourceAlbumId.isNotEmpty &&
        current?.albumId == sourceAlbumId) {
      if ((_tailFlight != null &&
              _tailGeneration == generation &&
              _tailRequest == _request) ||
          _checkedEpochs.add(_epoch)) {
        // _finish owns _commands. The flight takes that lock only to commit.
        unawaited(refreshAlbumTail(sourceAlbumId).catchError((Object _) {}));
      }
      return;
    }
    if (effectiveSettings.autoNext && cursor + 1 < _queue.length) {
      await _select(cursor + 1, _newRequest());
    }
  }

  Future<void> refreshAlbumTail(String albumId) {
    final album = xmlyIdentifier(albumId),
        expectedGeneration = generation,
        request = _request;
    if (queueSource != 'album' || sourceAlbumId != album || _queue.isEmpty)
      return Future.value();
    if (_tailFlight != null &&
        _tailGeneration == expectedGeneration &&
        _tailRequest == request) {
      return _tailFlight!;
    }
    final endEpoch = _epoch, advanceIntent = _advanceIntent;
    final client = accounts.activeClient ?? anonymous, snapshot = _queue;
    final savedPage = albumPage, savedTotal = albumTotal;
    final savedSize = albumPageSize;
    if (current?.id == snapshot.last.id) _checkedEpochs.add(endEpoch);
    bool active() =>
        !_closed &&
        generation == expectedGeneration &&
        request == _request &&
        queueSource == 'album' &&
        sourceAlbumId == album &&
        !accounts.admissionPaused &&
        identical(client, accounts.activeClient ?? anonymous);
    final flight = () async {
      try {
        if (!active()) return;
        final last = snapshot.last;
        final officialPosition = last.officialPosition;
        final candidate = officialPosition ?? xmlyPositive(last.orderNo);
        if (candidate == null || candidate > 5000) {
          throw const XmlyException('invalid_album', '队列缺少专辑页码，请从专辑页重新选择声音');
        }
        void validateBoundary(int position) {
          if ((savedPage != null &&
                  (savedSize == null ||
                      position <= (savedPage - 1) * savedSize ||
                      position > savedPage * savedSize)) ||
              snapshot.any(
                (track) => (track.officialPosition ?? 0) > position,
              )) {
            throw const XmlyException(
              'catalogue_changed',
              '队列顺序已变化，请从专辑页重新选择声音',
            );
          }
        }

        // A persisted 50-row page number is never a 200-row page number.
        if (officialPosition != null) validateBoundary(officialPosition);
        var loadedPage = (candidate - 1) ~/ xmlyAlbumPageSize + 1;
        var loadedCount = (candidate - 1) % xmlyAlbumPageSize + 1;
        var total = savedTotal ?? 0;
        final known = snapshot.map((track) => track.id).toSet(),
            added = <Track>[];
        var previousOrder = xmlyPositive(last.orderNo);
        void append(AlbumPage result, {required bool samePage}) {
          var start = 0;
          if (samePage) {
            final anchor = result.tracks.indexWhere(
              (track) => track.id == last.id,
            );
            if (anchor != loadedCount - 1) {
              throw const XmlyException('catalogue_changed', '专辑末页发生变化，请刷新后重试');
            }
            final retained = snapshot.length < loadedCount
                ? snapshot.length
                : loadedCount;
            for (var index = 0; index < retained; index++) {
              if (snapshot[snapshot.length - retained + index].id !=
                  result.tracks[loadedCount - retained + index].id) {
                throw const XmlyException(
                  'catalogue_changed',
                  '专辑末页发生变化，请刷新后重试',
                );
              }
            }
            start = anchor + 1;
          }
          for (final track in result.tracks.skip(start)) {
            final order = xmlyPositive(track.orderNo);
            if (!known.add(track.id) ||
                (previousOrder != null &&
                    order != null &&
                    order <= previousOrder!)) {
              throw const XmlyException('duplicate_page', '专辑分页重复或倒退，请刷新后重试');
            }
            added.add(track);
            previousOrder = order ?? previousOrder;
          }
          if (result.tracks.length > start) loadedPage = result.page;
          if (result.total > 0) total = result.total;
          if (snapshot.length + added.length > 5000) {
            throw const XmlyException('catalogue_limit', '专辑播放队列最多 5000 集');
          }
        }

        // A queue may start mid-album; its length is not a catalogue position.
        // Without an official position, orderNo selects only a candidate page.
        final samePage =
            officialPosition == null ||
            loadedCount < xmlyAlbumPageSize ||
            loadedPage == 5000 ~/ xmlyAlbumPageSize;
        final page = samePage ? loadedPage : loadedPage + 1;
        final result = await _admission(
          request,
          () => _albumPage(client, album, page),
        );
        if (!active()) return;
        if (officialPosition == null) {
          final anchor = result.tracks.indexWhere(
            (track) => track.id == last.id,
          );
          if (anchor < 0) {
            throw const XmlyException(
              'catalogue_changed',
              '此页没有找到队列末集，请从专辑页重新选择声音',
            );
          }
          loadedCount = anchor + 1;
          validateBoundary((page - 1) * xmlyAlbumPageSize + loadedCount);
        }
        append(result, samePage: samePage);
        if (samePage &&
            result.tracks.length == xmlyAlbumPageSize &&
            result.total > page * xmlyAlbumPageSize) {
          final following = await _admission(
            request,
            () => _albumPage(client, album, page + 1),
          );
          if (!active()) return;
          if (following.tracks.isEmpty && following.total == 0) {
            throw const XmlyException('invalid_album', '专辑分页未能继续，请刷新后重试');
          }
          append(following, samePage: false);
        }
        await _commands.synchronized(() async {
          if (!active()) return;
          final next = added.isEmpty ? snapshot : [...snapshot, ...added];
          if (added.isNotEmpty ||
              savedPage != loadedPage ||
              savedTotal != total ||
              savedSize != xmlyAlbumPageSize) {
            await _saveQueue(
              next,
              cursor,
              album,
              page: loadedPage,
              total: total,
            );
          }
          _queue = next;
          error = null;
          status = added.isEmpty ? '已听到最新一集' : '已更新 ${added.length} 集';
          _notify();
          if (_atEnd &&
              _epoch == endEpoch &&
              advanceIntent == _advanceIntent &&
              current?.id == last.id &&
              cursor + 1 < _queue.length &&
              !_sleepStopped &&
              !_manualPaused &&
              effectiveSettings.autoNext &&
              effectiveSettings.loopMode != 'single') {
            final sleep = policy.onChapterEnd() ?? policy.pollSleep();
            if (sleep != null) {
              await _sleep(sleep);
              return;
            }
            await _run(() => _select(cursor + 1, _newRequest()));
          }
        });
      } catch (failure) {
        if (failure is DownloadStopped || !active()) return;
        error = _message(failure);
        status = '检查更新失败，请重试';
        _notify();
        rethrow;
      }
    }();
    _tailGeneration = expectedGeneration;
    _tailRequest = request;
    _tailFlight = flight;
    unawaited(
      flight.then(
        (_) {
          if (identical(_tailFlight, flight)) _tailFlight = null;
        },
        onError: (Object _, StackTrace __) {
          if (identical(_tailFlight, flight)) _tailFlight = null;
        },
      ),
    );
    return flight;
  }

  void setSleep(SleepRequest request) {
    policy.armSleep(request);
    _notify();
  }

  void cancelSleep() {
    policy.cancelSleep();
    _notify();
  }

  Future<void> _sleep(SleepAction action) async {
    ++_advanceIntent;
    _sleepStopped = true;
    await _pause(sleep: true);
    status = '定时已结束';
    _notify();
    if (action == SleepAction.exit) {
      await downloads.pauseAll();
      await ledger.stopWatch();
      await ledger.settle();
      // Called outside the command lock: normal application close quiesces us.
      final exit = exitApplication;
      if (exit == null) throw StateError('未配置应用退出处理');
      scheduleMicrotask(() => _background(exit));
    }
  }

  Future<void> _saveProgress({bool terminal = false, bool sync = true}) async {
    final track = current;
    if (track == null || _source == null || !_actual) return;
    final identity = _progressIdentity, actualPosition = _observedPosition;
    final timestamp = _clock().millisecondsSinceEpoch;
    await storage.transaction((state) {
      final history = _mutableHistory(state, identity);
      final positions =
          history.putIfAbsent('positions', () => <String, dynamic>{}) as Map;
      positions[track.id] = {
        'position': actualPosition,
        'updatedAt': timestamp,
        'albumId': track.albumId,
        'track': track.toJson(),
      };
      history['lastTrackId'] = track.id;
    });
    _savedAt = timestamp;
    if (sync)
      await _official.observe('player', actualPosition, terminal: terminal);
  }

  Future<void> retryHistory() async {
    await _official.flush(retry: true);
    _notify();
  }

  Future<void> applySettings() => _run(
    () => _commands.synchronized(() async {
      final settings = effectiveSettings;
      final wasDownload = sourceKind == 'prepaid' || sourceKind == 'local';
      policy.updateSettings(settings);
      await ledger.observe(
        playing: playing,
        buffering: buffering,
        speed: settings.speed,
      );
      rate = settings.speed;
      volume = settings.volume;
      await _driver.setRate(rate);
      await _driver.setVolume(volume);
      if (_source != null && settings.listenAndDownload && !wasDownload) {
        final saved = position;
        await _pause();
        await ledger.stopWatch();
        await _openCurrent(_newRequest(), resumePosition: saved);
      }
      _notify();
    }),
  );

  Future<void> addToQueue(Track track) => _run(
    () => _commands.synchronized(() async {
      if (_queue.any((item) => item.id == track.id)) return;
      if (_queue.length >= 5000)
        throw const XmlyException('queue_full', '队列最多 5000 集');
      final next = [..._queue, track], index = cursor < 0 ? 0 : cursor;
      await _saveQueue(next, index, '');
      _queue = next;
      cursor = index;
      sourceAlbumId = '';
      ++generation;
      _notify();
    }),
  );
  Future<void> removeQueueItem(int index) => _run(() async {
    RangeError.checkValidIndex(index, _queue);
    _newRequest();
    await _commands.synchronized(() async {
      final next = List<Track>.from(_queue)..removeAt(index);
      var selected = cursor;
      if (index == cursor) {
        await _stopSource();
        selected = index
            .clamp(0, next.length - 1 < 0 ? 0 : next.length - 1)
            .toInt();
      } else if (index < cursor) {
        selected--;
      }
      if (next.isEmpty) selected = -1;
      await _saveQueue(next, selected, '');
      _queue = next;
      cursor = selected;
      sourceAlbumId = '';
      ++generation;
      _notify();
    });
  });
  Future<void> moveQueueItem(int from, int to) => _run(
    () => _commands.synchronized(() async {
      RangeError.checkValidIndex(from, _queue);
      RangeError.checkValidIndex(to, _queue);
      final selected = current?.id;
      final next = List<Track>.from(_queue);
      next.insert(to, next.removeAt(from));
      final index = next.indexWhere((item) => item.id == selected);
      await _saveQueue(next, index, '');
      _queue = next;
      cursor = index;
      sourceAlbumId = '';
      ++generation;
      _notify();
    }),
  );
  Future<void> clearQueue() => _run(() async {
    _newRequest();
    await _commands.synchronized(() async {
      await _stopSource();
      await _saveQueue([], -1, '');
      _queue = [];
      cursor = -1;
      sourceAlbumId = '';
      ++generation;
      position = 0;
      duration = 0;
      _notify();
    });
  });

  Future<void> _library(void Function(Map library) update) async {
    final identity = libraryIdentity;
    await storage.transaction((state) {
      final library = (state['library'] as Map).putIfAbsent(
        identity,
        () => <String, dynamic>{},
      ) as Map;
      update(library);
    });
    _notify();
  }

  Future<void> toggleFavorite([Track? track]) async {
    final favorite = track ?? current;
    if (favorite == null) return;
    await _library((library) {
      final favorites =
          library.putIfAbsent('favorites', () => <String, dynamic>{}) as Map;
      if (favorites.containsKey(favorite.id))
        favorites.remove(favorite.id);
      else {
        favorites[favorite.id] = favorite.toJson();
      }
    });
  }

  Future<void> removeFavorite(String trackId) => _library((library) {
    (library['favorites'] as Map?)?.remove(trackId);
  });
  Future<void> bookmark() async {
    final track = current;
    if (track == null) return;
    final savedPosition = position;
    await _library((library) {
      (library.putIfAbsent('bookmarks', () => <dynamic>[]) as List).add({
        'track': track.toJson(),
        'position': savedPosition,
        'createdAt': _clock().millisecondsSinceEpoch,
      });
    });
  }

  Future<void> removeBookmark(int index) => _library((library) {
    final bookmarks = library['bookmarks'] as List? ?? [];
    RangeError.checkValidIndex(index, bookmarks);
    bookmarks.removeAt(index);
  });

  Future<void> _downloadChanged() async {
    final id = currentTaskId;
    if (id == null || sourceKind == 'local') return;
    final task = downloads.task(id);
    if (task.state == DownloadState.cancelled) {
      await _stopSource();
      _notify();
      return;
    }
    if (task.state == DownloadState.paused ||
        task.state == DownloadState.failed) {
      await _driver.pause();
      playing = false;
      await ledger.observe(playing: false, buffering: buffering, speed: rate);
      await _saveProgress(terminal: true);
      _notify();
    }
  }

  Future<void> _release() async {
    final source = _source;
    _source = null;
    await source?.release?.call();
  }

  Future<void> _stopSource({bool preserveUnknown = false}) async {
    await _driver.pause();
    playing = false;
    if (preserveUnknown) {
      await ledger.captureForRestore();
      await _saveProgress(terminal: true, sync: false);
    } else {
      await ledger.observe(playing: false, buffering: buffering, speed: rate);
      await _saveProgress(terminal: true);
      await ledger.stopWatch();
    }
    await _driver.stop();
    ++_epoch;
    await _release();
    buffering = false;
    _actual = false;
  }

  Future<void> stopTaskReference(String taskId) async {
    if (currentTaskId != taskId) return;
    _newRequest();
    await _commands.synchronized(() async {
      if (currentTaskId == taskId) {
        await _stopSource();
        _notify();
      }
    });
  }

  Future<void> quiesce({bool preserveUnknown = false}) async {
    if (_closed) return;
    _newRequest();
    await _commands.synchronized(() async {
      await _stopSource(preserveUnknown: preserveUnknown);
      _notify();
    });
  }

  Future<void> close({bool quiesced = false}) async {
    if (_closed) return;
    if (!quiesced) await quiesce();
    _timer?.cancel();
    await _official.close();
    _closed = true;
    await _driverEvents.cancel();
    await _downloadEvents.cancel();
    await _driver.close();
    await _proxy?.close();
    await _changes.close();
  }
}
