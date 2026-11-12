import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../api/xmly_client.dart';
import '../models/download_task.dart';
import '../models/xmly_models.dart';
import '../storage/app_storage.dart';
import 'account_service.dart';
import 'usage_ledger.dart';
import 'download_paths.dart';
import 'media_processor.dart';
import 'file_paths.dart';

export '../models/download_task.dart';

typedef DownloadTransfer = Future<String> Function(
  DownloadTask task,
  ResolvedAudio audio,
  DownloadControl control,
);

typedef DownloadProcessing = Future<String> Function(
  DownloadTask task,
  DownloadControl control,
);

class DownloadStopped implements Exception {
  const DownloadStopped();
}

/// Cooperative cancellation also interrupts cooldowns. A backend must checkpoint
/// before opening a request and between chunks, and close its response on stop.
class DownloadControl {
  DownloadControl._(this._progress, this._processing, this._warning);
  final void Function(int, int?, double) _progress;
  final Future<void> Function() _processing;
  final Future<void> Function(String) _warning;
  // Processing warnings describe an already committed output. Persisting them
  // must not discard that output when a stop arrives after the commit.
  Future<void> warning(String message) => _warning(message);

  final Completer<void> _stopped = Completer<void>();
  bool _paused = false, _cancelled = false;
  bool get paused => _paused;
  bool get cancelled => _cancelled;

  /// Allows backends to interrupt waits that do not reach a checkpoint.
  Future<void> get stopped => _stopped.future;
  Future<void> checkpoint() async {
    if (_paused || _cancelled) throw const DownloadStopped();
  }

  void onProgress(int received, int? total, double bytesPerSecond) {
    if (_paused || _cancelled) return;
    if (received < 0 ||
        (total != null && (total < received || total < 0)) ||
        !bytesPerSecond.isFinite ||
        bytesPerSecond < 0) {
      throw const XmlyException('invalid_progress', '下载进度无效');
    }
    _progress(received, total, bytesPerSecond);
  }

  Future<void> processing() async {
    await checkpoint();
    await _processing();
  }

  Future<void> wait(Duration duration) async {
    await checkpoint();
    final timer = Completer<void>();
    final handle = Timer(duration, timer.complete);
    try {
      await Future.any([timer.future, _stopped.future]);
      await checkpoint();
    } finally {
      handle.cancel();
    }
  }

  void _stop({required bool cancel}) {
    _cancelled = cancel;
    _paused = !cancel;
    if (!_stopped.isCompleted) _stopped.complete();
  }
}

class DownloadBatchItem {
  DownloadBatchItem._(
    this.track,
    this.seconds,
    this.expectedBalance,
    this.taskId,
    this.accountIdentity, [
    this.error,
    this.attemptedAccounts = const [],
  ]);
  final Track track;

  /// New seconds to debit; zero for a free track or the original paid task.
  final int seconds;
  final int? expectedBalance;
  final String? taskId;
  final String accountIdentity;
  final String? error;
  final List<String> attemptedAccounts;
}

class DownloadBatch {
  DownloadBatch._({
    required this.accountIdentity,
    required this.rootDirectory,
    required this.settings,
    required this.items,
    required this.balance,
    required this.createdAt,
    required this.owner,
    this.album,
  });
  final String accountIdentity, rootDirectory;
  final Map<String, dynamic> settings;
  final List<DownloadBatchItem> items;
  final int? balance;
  final DateTime createdAt;
  final DownloadService owner;
  final DownloadAlbumJob? album;
  String? get albumId => album?.albumId;
  int? get albumTotalCount => album?.total;
  List<Track> get tracks => List.unmodifiable(items.map((item) => item.track));
  int get totalSeconds => items.fold(0, (sum, item) => sum + item.seconds);
}

class DownloadAlbumJob {
  DownloadAlbumJob({
    required this.id,
    required this.albumId,
    required this.title,
    required this.accountIdentity,
    required this.rootDirectory,
    required this.settings,
    required this.total,
    this.page = 1,
    this.state = 'queued',
    this.error,
    this.taskIds = const [],
    this.seen = const [],
  });
  final String id, albumId, title, accountIdentity, rootDirectory;
  final Map<String, dynamic> settings;
  final int total;
  int page;
  String state;
  String? error;
  List<String> taskIds, seen;
  Map<String, dynamic> toJson() => {
    'id': id,
    'albumId': albumId,
    'title': title,
    'accountIdentity': accountIdentity,
    'rootDirectory': rootDirectory,
    'settings': settings,
    'total': total,
    'page': page,
    'state': state,
    'error': error,
    'taskIds': taskIds,
    'seen': seen,
  };
  factory DownloadAlbumJob.fromJson(Map value) => DownloadAlbumJob(
    id: value['id'] as String,
    albumId: value['albumId'] as String,
    title: value['title'] as String,
    accountIdentity: value['accountIdentity'] as String,
    rootDirectory: absoluteFilePath(value['rootDirectory'] as String),
    settings: Map<String, dynamic>.from(value['settings'] as Map),
    total: value['total'] as int,
    page: value['page'] as int,
    state: value['state'] as String,
    error: value['error'] as String?,
    taskIds: List<String>.from(value['taskIds'] as List),
    seen: List<String>.from(value['seen'] as List),
  );
}

class DownloadService {
  DownloadService({
    required this.storage,
    required this.accounts,
    required this.ledger,
    required this.transfer,
    required this.anonymous,
    this.processOnly,
    this.discardSource,
    this.beforeAdmission,
  });

  final AppStorage storage;
  final AccountService accounts;
  final UsageLedger ledger;
  final DownloadTransfer transfer;
  final DownloadProcessing? processOnly;
  final Future<void> Function(DownloadTask)? discardSource;
  final XmlyClient anonymous;
  final Future<int?> Function(String identity, XmlyClient client)?
  beforeAdmission;
  final Map<String, DownloadAlbumJob> _albums = {};
  final Set<String> _albumWorkers = {};
  List<DownloadAlbumJob> get albumJobs => List.unmodifiable(_albums.values);
  // Continue commands must observe the final snapshot after stopped workers drain.
  final Lock _queueCommands = Lock();
  final Lock _updates = Lock();
  final Map<String, Lock> _admissionOrder = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final Map<String, DownloadTask> _tasks = {};
  final Map<String, ({DownloadControl control, Future<void> done})> _workers =
      {};
  final Map<String, int> _stopping = {};
  final Map<String, int> _stoppingAlbums = {};
  final Map<String, bool Function()> _automaticGuards = {};
  final Map<String, Completer<void>> _albumStops = {};
  final Set<String> _albumRechecks = {};
  final Set<String> _freshResolves = {};
  bool _loaded = false, _closed = false, _suspended = false;
  String? _priority;

  Stream<void> get changes => _changes.stream;
  List<DownloadTask> get tasks => List.unmodifiable(_tasks.values);
  DownloadTask task(String id) =>
      _tasks[id] ?? (throw const XmlyException('task_missing', '下载任务不存在'));

  Future<void> load() => _updates.synchronized(() async {
    if (_loaded) return;
    if (_closed) throw const XmlyException('closed', '下载服务已关闭');
    final restored = <String, DownloadTask>{};
    try {
      for (final value in storage.state['downloads'] as List) {
        var item = DownloadTask.fromJson(
          Map<String, dynamic>.from(value as Map),
        );
        if (!p.isAbsolute(item.rootDirectory) ||
            restored.containsKey(item.id)) {
          throw const FormatException();
        }
        item = item.copyWith(
          rootDirectory: absoluteFilePath(item.rootDirectory),
        );
        if (item.active) {
          item = item.copyWith(
            state: DownloadState.paused,
            bytesPerSecond: 0,
            retryAt: null,
            processingFailed:
                item.processingFailed || item.state == DownloadState.processing,
          );
        }
        if (item.state == DownloadState.completed &&
            !await _outputExists(item)) {
          item = _missingOutput(item);
        }
        restored[item.id] = item;
      }
      for (final value
          in storage.state['downloadAlbums'] as List? ?? const []) {
        final job = DownloadAlbumJob.fromJson(value as Map);
        if (job.state != 'completed' && job.state != 'cancelled')
          job.state = 'paused';
        _albums[job.id] = job;
      }
    } catch (_) {
      throw const XmlyException('downloads_corrupt', '下载资料损坏，请恢复备份');
    }
    await _save(restored);
    _tasks.addAll(restored);
    _option(storage.state['settings'] as Map, 'parallelism', 3, 1, 6);
    _loaded = true;
    _notify();
    // Restoring never schedules, resolves, claims, or debits.
  });

  Future<void> reload() async {
    await _updates.synchronized(() async {
      if (_workers.isNotEmpty)
        throw const XmlyException('task_busy', '请先暂停所有任务');
      _tasks.clear();
      _automaticGuards.clear();
      _albums.clear();
      _loaded = false;
      _suspended = true;
    });
    await load();
  }

  static Map<String, dynamic> _taskSettings(
    Map<String, dynamic> settings,
    Track track,
  ) {
    final tags = Map<String, dynamic>.from(
      settings['tags'] as Map? ?? const {},
    );
    final overrides = Map<String, dynamic>.from(
      tags['overrides'] as Map? ?? const {},
    );
    final album = (settings['albumTags'] as Map?)?[track.albumId];
    if (album is Map) overrides.addAll(Map<String, dynamic>.from(album));
    tags['overrides'] = overrides;
    return {
      for (final entry in settings.entries)
        if (entry.key != 'albumTags') entry.key: entry.value,
      'tags': tags,
    };
  }

  /// Metadata and permission checks only. No media body is requested here.
  Future<DownloadBatch> prepare(
    List<Track> tracks, {
    required String accountIdentity,
    required String rootDirectory,
    required Map<String, dynamic> settings,
    bool previewBilling = true,
    Future<void>? cancelled,
    Future<void> Function()? checkpoint,
  }) async {
    _ensureOpen();
    await _reconcileOutputs(tracks.map((track) => track.id).toSet());
    if (tracks.length > 5000) {
      throw const XmlyException('batch_too_large', '每批最多选择 5000 集');
    }
    await _checkRoot(rootDirectory, settings);
    // Reuse the durable model's immutable, secret-free settings boundary.
    final snapshot = DownloadTask(
      id: 'preview',
      accountIdentity: accountIdentity,
      track: Track(id: '1'),
      rootDirectory: absoluteFilePath(rootDirectory),
      settings: settings,
      createdAt: DateTime.now(),
    ).settings;
    _option(snapshot, 'parallelism', 3, 1, 6);
    _option(snapshot, 'retryLimit', 3, 0, 1000);
    final seen = <String>{};
    final sorted = <({Track track, int position, String? taskId})>[];
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      if (seen.add(track.id) && !_duplicate(accountIdentity, track.id)) {
        sorted.add((
          track: track,
          position: i,
          taskId: _missingTask(track.id)?.id,
        ));
      }
    }
    sorted.sort((a, b) {
      final first =
          a.track.orderNo ?? a.track.officialPosition ?? a.position + 1;
      final second =
          b.track.orderNo ?? b.track.officialPosition ?? b.position + 1;
      final order = first.compareTo(second);
      if (order != 0) return order;
      return a.position.compareTo(b.position);
    });
    return _preview(
      accountIdentity,
      rootDirectory,
      snapshot,
      sorted
          .map((entry) => (track: entry.track, taskId: entry.taskId))
          .toList(),
      previewBilling: previewBilling,
      cancelled: cancelled,
      checkpoint: checkpoint,
    );
  }

  Future<DownloadBatch> prepareAlbum(
    String albumId, {
    required String accountIdentity,
    required String rootDirectory,
    required Map<String, dynamic> settings,
    bool previewBilling = true,
  }) async {
    _ensureOpen();
    await _checkRoot(rootDirectory, settings);
    final first = await _albumPage(accountIdentity, settings, albumId, 1);
    await _reconcileOutputs(first.tracks.map((track) => track.id).toSet());
    final snapshot = DownloadTask(
      id: 'preview',
      accountIdentity: accountIdentity,
      track: Track(id: '1'),
      rootDirectory: absoluteFilePath(rootDirectory),
      settings: settings,
      createdAt: DateTime.now(),
    ).settings;
    final job = DownloadAlbumJob(
      id: const Uuid().v4(),
      albumId: albumId,
      title: first.album.title,
      accountIdentity: accountIdentity,
      rootDirectory: absoluteFilePath(rootDirectory),
      settings: snapshot,
      total: first.total,
      seen: first.tracks.map((track) => track.id).toList(),
    );
    return _preview(
      accountIdentity,
      rootDirectory,
      snapshot,
      [
        for (final track in first.tracks)
          if (!_duplicate(accountIdentity, track.id))
            (track: track, taskId: _missingTask(track.id)?.id),
      ],
      album: job,
      previewBilling: previewBilling,
    );
  }

  Future<AlbumPage> _albumPage(
    String identity,
    Map settings,
    String albumId,
    int page, {
    int? total,
    List<String> seen = const [],
    Future<void>? cancelled,
    Future<void> Function()? checkpoint,
  }) async {
    Object? failure;
    for (final candidate in _candidates(identity, settings)) {
      try {
        Future<AlbumPage> read(XmlyClient client) => readRequests(
          client,
          settings,
          () => client.album(
            albumId,
            page: page,
            pageSize: xmlyAlbumPageSize,
            ascending: true,
          ),
          cancelled: cancelled,
          checkpoint: checkpoint,
        );
        final result = candidate == 'anonymous'
            ? await read(anonymous)
            : await _previewAccount(
                candidate,
                read,
                null,
                cancelled: cancelled,
                checkpoint: checkpoint,
              );
        final offset = (page - 1) * xmlyAlbumPageSize;
        if (result.total > 5000) {
          throw const XmlyException('catalogue_limit', '专辑超过 5000 集下载上限');
        }
        if (total != null && result.total != total) {
          throw const XmlyException('catalogue_changed', '专辑总集数已变化');
        }
        if (result.total < 0 ||
            result.page != page ||
            result.pageSize != xmlyAlbumPageSize ||
            result.album.id != albumId ||
            result.tracks.length !=
                (result.total - offset).clamp(0, xmlyAlbumPageSize)) {
          throw const XmlyException('invalid_catalogue', '专辑分页不完整或无效');
        }
        final ids = seen.toSet();
        for (var index = 0; index < result.tracks.length; index++) {
          final track = result.tracks[index];
          if (track.albumId != albumId ||
              track.officialPosition != offset + index + 1 ||
              !ids.add(track.id)) {
            throw const XmlyException('invalid_catalogue', '专辑声音顺序无效');
          }
        }
        return result;
      } catch (error) {
        failure = error;
        if (!_requestFailure(error)) rethrow;
      }
    }
    throw failure!;
  }

  Future<void> pauseAlbum(String id) =>
      _stopTasks(_albums[id]!.taskIds, cancel: false, albumId: id);

  Future<void> cancelAlbum(String id) =>
      _stopTasks(_albums[id]!.taskIds, cancel: true, albumId: id);

  Future<void> resumeAlbum(String id) => _queueCommands.synchronized(() async {
    _ensureOpen();
    final job = _albums[id]!;
    if (job.state == 'completed' || job.state == 'cancelled') return;
    _albumRechecks.add(id);
    job.state = 'running';
    job.error = null;
    await _updates.synchronized(() => _save(_tasks));
    for (final taskId in job.taskIds) {
      final item = task(taskId);
      if (item.state == DownloadState.paused && !item.needsConfirmation)
        await _resume(taskId);
    }
    _suspended = false;
    _notify();
    _pump();
  });

  void _pumpAlbums() {
    for (final job in _albums.values.toList()) {
      if (job.state != 'running' ||
          _stoppingAlbums.containsKey(job.id) ||
          _albumWorkers.contains(job.id) ||
          job.taskIds.any(
            (id) =>
                _workers.containsKey(id) ||
                task(id).active && !task(id).needsConfirmation,
          ))
        continue;
      _albumWorkers.add(job.id);
      unawaited(
        _advanceAlbum(job).whenComplete(() {
          _albumWorkers.remove(job.id);
          _pump();
        }),
      );
    }
  }

  Future<void> _advanceAlbum(DownloadAlbumJob job) async {
    final stop = Completer<void>();
    _albumStops[job.id] = stop;
    bool allowed() =>
        !_closed &&
        !_suspended &&
        !stop.isCompleted &&
        !_stoppingAlbums.containsKey(job.id) &&
        _albums[job.id]?.state == 'running';
    Future<void> checkpoint() async {
      if (!allowed()) throw const DownloadStopped();
    }

    try {
      if (_albumRechecks.remove(job.id)) {
        await _refreshAlbum(job, stop.future, checkpoint, allowed);
        return;
      }
      if (job.page * xmlyAlbumPageSize >= job.total) {
        job.state = 'completed';
        await _updates.synchronized(() => _save(_tasks));
        for (final id in job.taskIds) {
          _automaticGuards.remove(id);
        }
        _notify();
        return;
      }
      AlbumPage page;
      try {
        page = await _albumPage(
          job.accountIdentity,
          job.settings,
          job.albumId,
          job.page + 1,
          total: job.total,
          seen: job.seen,
          cancelled: stop.future,
          checkpoint: checkpoint,
        );
      } on XmlyException catch (error) {
        if (!const {
          'catalogue_changed',
          'invalid_catalogue',
        }.contains(error.code))
          rethrow;
        await checkpoint();
        await _refreshAlbum(job, stop.future, checkpoint, allowed);
        return;
      }
      await checkpoint();
      await _reconcileOutputs(page.tracks.map((track) => track.id).toSet());
      final next = DownloadAlbumJob.fromJson(job.toJson())
        ..page = job.page + 1
        ..seen = [...job.seen, ...page.tracks.map((track) => track.id)];
      await _admitAlbumPage(
        job,
        next,
        page.tracks,
        stop.future,
        checkpoint,
        allowed,
      );
    } on DownloadStopped {
      // No cursor is committed after this generation is stopped.
    } catch (error) {
      if (!allowed()) return;
      job.state = 'failed';
      job.error = _message(error);
      try {
        await _updates.synchronized(() => _save(_tasks));
      } catch (_) {}
      _notify();
    } finally {
      if (identical(_albumStops[job.id], stop)) _albumStops.remove(job.id);
    }
  }

  Future<void> _refreshAlbum(
    DownloadAlbumJob job,
    Future<void> cancelled,
    Future<void> Function() checkpoint,
    bool Function() allowed,
  ) async {
    // Read one complete strict snapshot before admitting anything. A second
    // change during this bounded pass stops visibly rather than looping.
    final tracks = <Track>[];
    final first = await _albumPage(
      job.accountIdentity,
      job.settings,
      job.albumId,
      1,
      cancelled: cancelled,
      checkpoint: checkpoint,
    );
    tracks.addAll(first.tracks);
    for (var page = 2; tracks.length < first.total; page++) {
      await checkpoint();
      final result = await _albumPage(
        job.accountIdentity,
        job.settings,
        job.albumId,
        page,
        total: first.total,
        seen: tracks.map((track) => track.id).toList(),
        cancelled: cancelled,
        checkpoint: checkpoint,
      );
      tracks.addAll(result.tracks);
    }
    await checkpoint();
    await _reconcileOutputs(tracks.map((track) => track.id).toSet());
    final next = DownloadAlbumJob.fromJson({
      ...job.toJson(),
      'total': first.total,
      'page': (first.total + xmlyAlbumPageSize - 1) ~/ xmlyAlbumPageSize,
      'seen': tracks.map((track) => track.id).toList(),
    });
    await _admitAlbumPage(job, next, tracks, cancelled, checkpoint, allowed);
  }

  Future<void> _admitAlbumPage(
    DownloadAlbumJob job,
    DownloadAlbumJob next,
    List<Track> tracks,
    Future<void> cancelled,
    Future<void> Function() checkpoint,
    bool Function() allowed,
  ) async {
    final batch = await _preview(
      job.accountIdentity,
      job.rootDirectory,
      job.settings,
      [
        for (final track in tracks)
          if (!_duplicate(job.accountIdentity, track.id) &&
              !_tasks.values.any(
                (item) =>
                    item.track.id == track.id &&
                    (item.outputDeleted ||
                        item.state == DownloadState.cancelled &&
                            !_hasDebit(
                              item.accountIdentity,
                              item.id,
                              track.id,
                            )),
              ))
            (track: track, taskId: _missingTask(track.id)?.id),
      ],
      album: next,
      previewBilling: job.settings['billingPreviewPending'] != true,
      cancelled: cancelled,
      checkpoint: checkpoint,
    );
    await checkpoint();
    await _enqueue(batch, confirmed: true, allowed: allowed);
  }

  Future<void> refreshAlbum(String id) async {
    _albumRechecks.add(id);
    await resumeAlbum(id);
  }

  /// Re-confirming a changed fee/balance keeps the original task and its receipt.
  Future<DownloadBatch> prepareRetry(String taskId) async {
    _ensureOpen();
    final item = task(taskId);
    if (_workers.containsKey(taskId) || item.state == DownloadState.completed) {
      throw const XmlyException('task_busy', '请先暂停此任务');
    }
    await _checkRoot(item.rootDirectory, item.settings);
    return _preview(item.accountIdentity, item.rootDirectory, item.settings, [
      (track: item.track, taskId: item.id),
    ]);
  }

  Future<DownloadBatch> _preview(
    String identity,
    String root,
    Map<String, dynamic> settings,
    List<({Track track, String? taskId})> selected, {
    DownloadAlbumJob? album,
    DownloadControl? control,
    bool previewBilling = true,
    Future<void>? cancelled,
    Future<void> Function()? checkpoint,
  }) async {
    await _requireMediaTools();
    if (!previewBilling) {
      final deferred = {...settings, 'billingPreviewPending': true};
      return DownloadBatch._(
        accountIdentity: identity,
        rootDirectory: absoluteFilePath(root),
        settings: deferred,
        items: List.unmodifiable([
          for (final selection in selected)
            DownloadBatchItem._(
              selection.track,
              0,
              null,
              selection.taskId,
              _selectionIdentity(identity, selection.taskId),
            ),
        ]),
        balance: null,
        createdAt: DateTime.now(),
        owner: this,
        album: album == null
            ? null
            : DownloadAlbumJob.fromJson({
                ...album.toJson(),
                'settings': deferred,
              }),
      );
    }
    final items = <DownloadBatchItem>[];
    final balances = <String, int>{}, reserved = <String, int>{};
    final refreshed = <String>{};
    for (final selection in selected) {
      Object? failure;
      DownloadBatchItem? item;
      final attempted = <String>[];
      final selectionIdentity = _selectionIdentity(identity, selection.taskId);
      final candidates = _candidates(
        selectionIdentity,
        settings,
        taskId: selection.taskId,
        trackId: selection.track.id,
      );
      for (final candidate in candidates) {
        attempted.add(candidate);
        try {
          Future<DownloadBatchItem> read(XmlyClient client) async {
            await checkpoint?.call();
            await control?.checkpoint();
            final receipt = _receipt(
              candidate,
              selection.taskId,
              selection.track.id,
            );
            final quality =
                (settings['download'] as Map?)?['quality'] as String?;
            final cached =
                receipt == null || _freshResolves.contains(selection.taskId)
                ? null
                : await readRequests(
                    client,
                    settings,
                    () => client.cachedPrepaidAudio(
                      selection.track.id,
                      quality: quality,
                    ),
                    control: control,
                    cancelled: cancelled,
                    checkpoint: checkpoint,
                  );
            if (cached == null &&
                candidate != 'anonymous' &&
                refreshed.add(candidate)) {
              await readRequests(
                client,
                settings,
                () async => await beforeAdmission?.call(candidate, client),
                control: control,
                cancelled: cancelled,
                checkpoint: checkpoint,
              );
            }
            await control?.checkpoint();
            final audio =
                cached ??
                await readRequests<ResolvedAudio>(
                  client,
                  settings,
                  () => client.resolve(selection.track.id, quality: quality),
                  control: control,
                  cancelled: cancelled,
                  checkpoint: checkpoint,
                );
            _identity(audio, candidate, selection.track.id);
            final seconds = _reward(audio) && receipt == null
                ? _fee(audio.track)
                : 0;
            int? expected;
            if (seconds > 0) {
              if (ledger.isBlocked(candidate)) {
                throw const XmlyException('usage_uncertain', '请先核对未确认的听时扣除');
              }
              if (!balances.containsKey(candidate)) {
                await readRequests(
                  client,
                  settings,
                  () => ledger.settleForDownload(candidate),
                  control: control,
                  cancelled: cancelled,
                  checkpoint: checkpoint,
                );
                balances[candidate] = (await readRequests(
                  client,
                  settings,
                  () => ledger.queryQuota(candidate),
                  control: control,
                  cancelled: cancelled,
                  checkpoint: checkpoint,
                )).remainingSeconds;
              }
              expected = balances[candidate]! - (reserved[candidate] ?? 0);
              if (expected < seconds) {
                throw const XmlyException('insufficient_quota', '听时不足');
              }
            }
            return DownloadBatchItem._(
              _metadata(audio.track, selection.track),
              seconds,
              expected,
              selection.taskId,
              candidate,
              null,
              List.unmodifiable(attempted),
            );
          }

          final prepared = candidate == 'anonymous'
              ? await read(anonymous)
              : await _previewAccount(
                  candidate,
                  read,
                  control,
                  cancelled: cancelled,
                  checkpoint: checkpoint,
                );
          item = prepared;
          reserved[candidate] = (reserved[candidate] ?? 0) + prepared.seconds;
          break;
        } catch (error) {
          if (error is DownloadStopped) rethrow;
          failure = error;
          if (!_requestFailure(error)) break;
        }
      }
      items.add(
        item ??
            DownloadBatchItem._(
              selection.track,
              0,
              null,
              selection.taskId,
              selectionIdentity,
              _message(failure ?? const DownloadStopped()),
              List.unmodifiable(attempted),
            ),
      );
    }
    return DownloadBatch._(
      accountIdentity: identity,
      rootDirectory: absoluteFilePath(root),
      settings: settings,
      items: List.unmodifiable(items),
      balance: balances.length == 1 ? balances.values.single : null,
      createdAt: DateTime.now(),
      owner: this,
      album: album,
    );
  }

  String _selectionIdentity(String requested, String? taskId) {
    if (taskId == null) return requested;
    final existing = task(taskId);
    if (_hasDebit(existing.accountIdentity, taskId, existing.track.id) &&
        existing.accountIdentity != requested) {
      throw const XmlyException(
        'original_account_required',
        '原任务含已确认或未知的扣时，请选择原账号继续；账号已移除时请先恢复登录',
      );
    }
    // Without a receipt-bound authorization, reuse the task identity while
    // honoring the account explicitly chosen for this new request.
    return requested;
  }

  Future<T> _previewAccount<T>(
    String identity,
    Future<T> Function(XmlyClient) read,
    DownloadControl? control, {
    Future<void>? cancelled,
    Future<void> Function()? checkpoint,
  }) {
    cancelled ??= control?.stopped;
    checkpoint ??= control?.checkpoint;
    if (cancelled == null) return accounts.runWithAccount(identity, read);
    var entered = false;
    final result = Completer<T>();
    final admission = accounts.runWithAccount(identity, (client) async {
      await checkpoint?.call();
      entered = true;
      return read(client);
    });
    admission.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    cancelled.then((_) {
      if (!entered && !result.isCompleted)
        result.completeError(const DownloadStopped());
    });
    return result.future;
  }

  List<String> _candidates(
    String identity,
    Map settings, {
    String? taskId,
    String? trackId,
  }) {
    if ((settings['download'] as Map?)?['polling'] == false ||
        identity == 'anonymous' ||
        _hasDebit(identity, taskId, trackId))
      return [identity];
    return [identity, ...accounts.accountIds.where((id) => id != identity)];
  }

  bool _hasDebit(String identity, String? taskId, String? trackId) {
    if (identity == 'anonymous' || taskId == null) return false;
    return ledger
        .receipts(identity)
        .any(
          (r) =>
              r.taskId == taskId &&
              r.trackId == trackId &&
              !r.historical &&
              const {
                DebitState.confirmed,
                DebitState.submitting,
                DebitState.uncertain,
              }.contains(r.state),
        );
  }

  static bool _requestFailure(Object error) =>
      error is AccountException ||
      error is SocketException ||
      error is TimeoutException ||
      error is XmlyException &&
          const {
            'network',
            'http',
            'http_error',
            'request_failed',
            'rate_limited',
            'login_expired',
            'insufficient_quota',
            'rejected',
            'usage_uncertain',
            'permission_denied',
            'forbidden',
            'unauthorized',
            'quota_unavailable',
          }.contains(error.code);

  Future<void> enqueue(
    DownloadBatch batch, {
    required bool confirmed,
    Future<void> Function(List<DownloadTask> tasks)? beforeStart,
  }) => _enqueue(batch, confirmed: confirmed, beforeStart: beforeStart);

  Future<void> enqueueAutomatic(
    DownloadBatch batch, {
    required bool Function() allowed,
  }) => _enqueue(batch, confirmed: true, allowed: allowed);

  Future<void> _enqueue(
    DownloadBatch batch, {
    required bool confirmed,
    Future<void> Function(List<DownloadTask> tasks)? beforeStart,
    bool Function()? allowed,
  }) async {
    _ensureOpen();
    await _requireMediaTools();
    if (!identical(batch.owner, this))
      throw const XmlyException('batch_invalid', '下载确认已失效');
    if (!confirmed) return;
    await _checkRoot(batch.rootDirectory, batch.settings);
    _option(batch.settings, 'parallelism', 3, 1, 6);
    await _reconcileOutputs(batch.items.map((item) => item.track.id).toSet());
    Future<void> persist() => _updates.synchronized(() async {
      _ensureOpen();
      if (allowed != null && !allowed()) throw const DownloadStopped();
      final next = Map<String, DownloadTask>.from(_tasks);
      final admitted = <DownloadTask>[];
      for (final item in batch.items) {
        if (allowed != null &&
            item.taskId == null &&
            next.values.any(
              (task) =>
                  task.accountIdentity == item.accountIdentity &&
                  task.track.id == item.track.id &&
                  !task.outputMissing,
            ))
          continue;
        if (item.taskId == null) {
          if (_duplicate(item.accountIdentity, item.track.id, source: next) ||
              next.values.any(
                (existing) =>
                    existing.track.id == item.track.id &&
                    _hasDebit(
                      existing.accountIdentity,
                      existing.id,
                      existing.track.id,
                    ),
              )) {
            continue;
          }
          final id = const Uuid().v4();
          final created = DownloadTask(
            id: id,
            accountIdentity: item.accountIdentity,
            track: item.track,
            rootDirectory: absoluteFilePath(batch.rootDirectory),
            settings: _taskSettings(batch.settings, item.track),
            createdAt: DateTime.now(),
            costSeconds: item.seconds,
            expectedBalance: item.expectedBalance,
            userConfirmed: true,
            attemptedAccounts: item.attemptedAccounts,
            needsConfirmation: item.error != null,
            state: item.error == null
                ? DownloadState.queued
                : DownloadState.failed,
            error: item.error,
          );
          next[id] = created;
          admitted.add(created);
        } else {
          final existing = task(item.taskId!);
          if (_workers.containsKey(existing.id) ||
              existing.state == DownloadState.completed ||
              _hasDebit(
                    existing.accountIdentity,
                    existing.id,
                    existing.track.id,
                  ) &&
                  existing.accountIdentity != item.accountIdentity ||
              existing.track.id != item.track.id) {
            throw const XmlyException('task_busy', '下载任务已变化，请重新确认');
          }
          final resumed = existing.copyWith(
            outputMissing: false,
            outputDeleted: false,
            warning: existing.outputDeleted ? null : existing.warning,
            track: item.track,
            settings: {
              for (final entry in existing.settings.entries)
                if (entry.key != 'billingPreviewPending')
                  entry.key: entry.value,
              if (batch.settings['billingPreviewPending'] == true)
                'billingPreviewPending': true,
            },
            state: item.error == null
                ? DownloadState.queued
                : DownloadState.failed,
            accountIdentity: item.accountIdentity,
            costSeconds: item.seconds,
            expectedBalance: item.expectedBalance,
            userConfirmed: true,
            needsConfirmation: item.error != null,
            attemptedAccounts: item.attemptedAccounts,
            error: item.error,
            retryAt: null,
            retryCount: 0,
          );
          next[existing.id] = resumed;
          admitted.add(resumed);
        }
      }
      if (beforeStart != null) await beforeStart(List.unmodifiable(admitted));
      final album = batch.album;
      if (album != null) {
        // Track actual admissions, including a task resumed with its receipt
        // or assigned to another account by polling. Matching track IDs alone
        // must never take ownership of an independent download.
        album.taskIds =
            {...?_albums[album.id]?.taskIds, ...admitted.map((item) => item.id)}
                .where(
                  (id) =>
                      next.containsKey(id) &&
                      next[id]!.state != DownloadState.cancelled,
                )
                .toList();
        album.state = 'running';
        album.error = null;
      }
      await storage.transaction((state) {
        if (allowed != null && !allowed()) throw const DownloadStopped();
        state['downloads'] = next.values.map((item) => item.toJson()).toList();
        state['downloadAlbums'] = [
          for (final job in _albums.values)
            if (job.id != album?.id) job.toJson(),
          if (album != null) album.toJson(),
        ];
      });
      if (allowed != null) {
        for (final task in admitted) {
          _automaticGuards[task.id] = allowed;
        }
      }
      _tasks
        ..clear()
        ..addAll(next);
      if (album != null) _albums[album.id] = album;
      _suspended = false;
      _notify();
    });
    // Account changes can hold their mutex while pausing the queue. Acquire the
    // queue command lock only after admission has entered that account mutex.
    Future<void> admit(XmlyClient _) => _queueCommands.synchronized(persist);
    if (batch.accountIdentity == 'anonymous') {
      await admit(anonymous);
    } else {
      await accounts.runWithAccount(batch.accountIdentity, admit);
    }
    _pump();
  }

  Future<void> pause(String id) => _stop(id, cancel: false);
  Future<void> cancel(String id) => _stop(id, cancel: true);
  Future<void> _stop(String id, {required bool cancel}) =>
      _stopTasks([id], cancel: cancel);

  Future<void> _stopTasks(
    Iterable<String> ids, {
    required bool cancel,
    String? albumId,
  }) async {
    _ensureOpen();
    final state = cancel ? DownloadState.cancelled : DownloadState.paused;
    final targets = <String>{};
    void signal(Iterable<String> values) {
      for (final id in values) {
        if (!targets.add(id)) continue;
        _stopping.update(id, (count) => count + 1, ifAbsent: () => 1);
        _workers[id]?.control._stop(cancel: cancel);
      }
    }

    if (albumId != null) {
      final stop = _albumStops[albumId];
      if (stop != null && !stop.isCompleted) stop.complete();
      _stoppingAlbums.update(albumId, (count) => count + 1, ifAbsent: () => 1);
      _albums[albumId]!.state = state.name;
    }
    // Notify every producer before waiting. Pending album stops also cover a
    // page whose admission is still publishing its newly persisted tasks.
    signal(ids);
    await _queueCommands.synchronized(() async {
      try {
        if (albumId != null) signal(_albums[albumId]!.taskIds);
        await Future.wait([
          for (final id in targets)
            if (_workers[id] case final worker?) worker.done,
        ]);
        await _updates.synchronized(() async {
          final stopped = <String, DownloadTask>{};
          for (final id in targets) {
            final item = task(id);
            if (item.state == DownloadState.completed ||
                albumId != null && !cancel && !item.active) {
              continue;
            }
            stopped[id] = item.copyWith(
              state: state,
              bytesPerSecond: 0,
              retryAt: null,
              processingFailed:
                  item.processingFailed ||
                  item.state == DownloadState.processing,
            );
          }
          final album = albumId == null ? null : _albums[albumId]!;
          if (album != null) album.state = state.name;
          try {
            await _save({..._tasks, ...stopped});
          } catch (_) {
            final message = cancel
                ? '取消状态保存失败，请检查资料目录后重新打开应用'
                : '暂停状态保存失败，请检查资料目录后重新打开应用';
            stopped.updateAll((id, item) => item.copyWith(error: message));
            if (album != null) album.error = message;
            rethrow;
          } finally {
            _tasks.addAll(stopped);
            _notify();
          }
        });
      } finally {
        for (final id in targets) {
          final remaining = _stopping[id]! - 1;
          if (remaining == 0) {
            _stopping.remove(id);
          } else {
            _stopping[id] = remaining;
          }
        }
        if (albumId != null) {
          final remaining = _stoppingAlbums[albumId]! - 1;
          if (remaining == 0) {
            _stoppingAlbums.remove(albumId);
          } else {
            _stoppingAlbums[albumId] = remaining;
          }
        }
        // Finish the stop before the next continue command can start.
        _pump();
      }
    });
  }

  static Future<bool> _outputExists(DownloadTask item) async =>
      item.finalPath != null && await File(item.finalPath!).exists();

  static DownloadTask _missingOutput(DownloadTask item) => item.copyWith(
    state: DownloadState.failed,
    error: '下载文件已删除或丢失，请重试获取',
    bytesPerSecond: 0,
    retryAt: null,
    processingFailed: false,
    outputMissing: true,
    outputDeleted: false,
  );

  DownloadTask? _missingTask(String trackId) => _tasks.values
      .where(
        (item) =>
            item.track.id == trackId &&
            !item.active &&
            (item.outputMissing ||
                item.state != DownloadState.completed &&
                    _hasDebit(item.accountIdentity, item.id, trackId)),
      )
      .firstOrNull;

  /// Called only after a user-authorized file deletion succeeds.
  /// Keep the original task/account/receipt so retry cannot charge a new task.
  Future<void> markAudioDeleted(String id, {String? expectedPath}) async {
    _ensureOpen();
    await _change(id, (item) {
      if (expectedPath != null &&
          (item.state != DownloadState.completed ||
              item.finalPath != expectedPath)) {
        throw const XmlyException('download_changed', '下载记录已变化，请刷新后检查音频');
      }
      return item.state == DownloadState.completed
          ? item.copyWith(
              state: DownloadState.paused,
              finalPath: null,
              error: null,
              warning: '音频已主动删除，可重新下载',
              bytesPerSecond: 0,
              retryAt: null,
              processingFailed: false,
              outputMissing: true,
              outputDeleted: true,
              userConfirmed: false,
              needsConfirmation: true,
            )
          : item;
    });
  }

  Future<void> markAudioMissing(
    String id, {
    required String expectedPath,
  }) async {
    _ensureOpen();
    await _change(id, (item) {
      if (item.state != DownloadState.completed ||
          item.finalPath != expectedPath) {
        throw const XmlyException('download_changed', '下载记录已变化，请刷新后检查音频');
      }
      return _missingOutput(item);
    });
  }

  Future<void> _reconcileOutputs(Set<String> trackIds) =>
      _updates.synchronized(() async {
        final next = Map<String, DownloadTask>.from(_tasks);
        var changed = false;
        for (final item in next.values.toList()) {
          if (item.state == DownloadState.completed &&
              trackIds.contains(item.track.id) &&
              !await _outputExists(item)) {
            next[item.id] = _missingOutput(item);
            changed = true;
          }
        }
        if (!changed) return;
        await _save(next);
        _tasks
          ..clear()
          ..addAll(next);
        _notify();
      });

  Future<void> resume(String id, {bool Function()? isActive}) =>
      _queueCommands.synchronized(() => _resume(id, isActive: isActive));

  Future<void> _resume(String id, {bool Function()? isActive}) async {
    _ensureOpen();
    final worker = _workers[id];
    if (worker != null) {
      // An active worker needs no resume. Do not hold up a later pause command.
      if (!worker.control.paused && !worker.control.cancelled) return;
      await worker.done;
    }
    _ensureOpen();
    if (isActive != null && !isActive()) throw const DownloadStopped();
    final item = task(id);
    if (item.state == DownloadState.completed || item.active) return;
    if (!item.processingFailed &&
        (item.needsConfirmation || !item.userConfirmed)) {
      throw const XmlyException('confirmation_required', '请重新确认本次听时和余额');
    }
    await _change(id, (item) {
      // Playback may have been cancelled while this command waited to update.
      if (isActive != null && !isActive()) throw const DownloadStopped();
      _automaticGuards.remove(id); // A manual continue is a fresh user action.
      return item.copyWith(
        outputMissing: false,
        outputDeleted: false,
        state: DownloadState.queued,
        error: null,
        retryAt: null,
        retryCount: 0,
        attemptedAccounts: const [],
      );
    });
    _suspended = false;
    _pump();
  }

  Future<void> retry(String id, {bool reacquire = false}) async {
    _ensureOpen();
    await _workers[id]?.done;
    final item = task(id);
    if (item.state == DownloadState.completed) {
      if (item.finalPath != null && await File(item.finalPath!).exists())
        return;
      await _change(
        id,
        (value) => value.copyWith(
          state: DownloadState.paused,
          finalPath: null,
          error: null,
        ),
      );
    }
    if (reacquire) {
      Future<void> revoke(XmlyClient client) async {
        await discardSource?.call(item);
        // Revoke all qualities for just this account/track, including leases
        // with no known expiry, before allowing an explicit replacement.
        client.invalidate(item.track.id);
        await client.flushUrlCache();
      }

      if (item.accountIdentity == 'anonymous') {
        await revoke(anonymous);
      } else {
        await accounts.runWithAccount(item.accountIdentity, revoke);
      }
      await _change(id, (value) => value.copyWith(processingFailed: false));
      _freshResolves.add(id);
    }
    await resume(id);
  }

  Future<void> reprocess(
    String id, {
    required String format,
    required int bitrateKbps,
    String conflict = 'skip',
    bool useCurrentTools = true,
  }) async {
    _ensureOpen();
    if (!const {'original', 'mp3', 'm4a', 'm4b', 'flac'}.contains(format) ||
        !const {32, 64, 96, 128, 192}.contains(bitrateKbps) ||
        !const {'skip', 'overwrite', 'number'}.contains(conflict)) {
      throw const XmlyException('invalid_settings', '处理设置无效');
    }
    if (task(id).active) throw const XmlyException('task_busy', '请先暂停任务');
    await _workers[id]?.done;
    await _change(id, (value) {
      if (value.active || !value.processingFailed)
        throw const XmlyException('task_busy', '此任务没有待重跑的处理');
      final settings = Map<String, dynamic>.from(value.settings);
      final media = Map<String, dynamic>.from(
        settings['media'] as Map? ?? const {},
      );
      media['format'] = format;
      media['bitrateKbps'] = bitrateKbps;
      if (useCurrentTools) {
        final current =
            (storage.state['settings'] as Map)['media'] as Map? ?? const {};
        for (final key in ['ffmpegPath', 'ffprobePath']) {
          media.remove(key);
          if (current[key] != null) media[key] = current[key];
        }
      }
      settings['media'] = media;
      settings['download'] = {
        ...(settings['download'] as Map? ?? const {}),
        'conflict': conflict,
      };
      return value.copyWith(
        settings: settings,
        state: DownloadState.paused,
        error: null,
      );
    });
    await resume(id);
  }

  Future<void> relocate(String id, String directory) async {
    _ensureOpen();
    if (task(id).active) throw const XmlyException('task_busy', '请先暂停任务');
    await _workers[id]?.done;
    await _checkRoot(directory, task(id).settings);
    await _change(id, (value) {
      if (value.active || value.state == DownloadState.completed)
        throw const XmlyException('task_busy', '请先暂停任务');
      final settings = Map<String, dynamic>.from(value.settings);
      settings['download'] = {
        ...(settings['download'] as Map? ?? const {}),
        'rootDirectory': directory,
      };
      return value.copyWith(
        rootDirectory: absoluteFilePath(directory),
        settings: settings,
        state: DownloadState.paused,
        processingFailed: false,
        error: null,
        warning: null,
        receivedBytes: 0,
        totalBytes: null,
        bytesPerSecond: 0,
        retryAt: null,
        finalPath: null,
      );
    });
  }

  Future<void> pauseAll() {
    _suspended = true;
    for (final stop in _albumStops.values) {
      if (!stop.isCompleted) stop.complete();
    }
    for (final worker in _workers.values) {
      worker.control._stop(cancel: false);
    }
    return _queueCommands.synchronized(() async {
      for (final job in _albums.values) {
        if (job.state == 'running') job.state = 'paused';
      }
      final workers = _workers.values.toList();
      for (final worker in workers) {
        worker.control._stop(cancel: false);
      }
      // Stopping must not depend on a writable state directory. Drain producers
      // before taking the final snapshot so late worker updates cannot undo it.
      await Future.wait(workers.map((worker) => worker.done));
      await _updates.synchronized(() async {
        final next = Map<String, DownloadTask>.from(_tasks);
        final paused = tasks.where((item) => item.active).toList();
        for (final item in paused) {
          next[item.id] = item.copyWith(
            state: DownloadState.paused,
            bytesPerSecond: 0,
            retryAt: null,
            processingFailed:
                item.processingFailed || item.state == DownloadState.processing,
          );
        }
        try {
          await _save(next);
        } catch (_) {
          for (final item in paused) {
            next[item.id] = next[item.id]!.copyWith(
              error: '暂停状态保存失败，请检查资料目录后重新打开应用',
            );
          }
          rethrow;
        } finally {
          _tasks
            ..clear()
            ..addAll(next);
          _notify();
        }
      });
    });
  }

  Future<void> resumeAll() => _queueCommands.synchronized(() async {
    _ensureOpen();
    await Future.wait(
      _workers.values
          .where((worker) => worker.control.paused || worker.control.cancelled)
          .map((worker) => worker.done)
          .toList(),
    );
    for (final item in tasks.where(
      (item) =>
          item.state == DownloadState.paused &&
          (item.processingFailed ||
              item.userConfirmed && !item.needsConfirmation),
    )) {
      _automaticGuards.remove(item.id);
      await _change(
        item.id,
        (value) => value.copyWith(
          outputMissing: false,
          outputDeleted: false,
          state: DownloadState.queued,
          error: null,
          retryAt: null,
          retryCount: 0,
          attemptedAccounts: const [],
        ),
      );
    }
    _suspended = false;
    for (final job in _albums.values) {
      if (job.state == 'paused') {
        _albumRechecks.add(job.id);
        job.state = 'running';
      }
    }
    await _updates.synchronized(() => _save(_tasks));
    _pump();
  });

  void prioritize(String? taskId) {
    if (taskId != null) task(taskId);
    _priority = taskId;
    _pump();
  }

  /// Apply a saved global limit without resuming a paused queue or stopping work.
  void settingsChanged() => _pump();

  void _pump() {
    if (_closed || _suspended || !_loaded) return;
    final parallelism = _option(
      storage.state['settings'] as Map,
      'parallelism',
      3,
      1,
      6,
    );
    _pumpAlbums();
    final stoppedAlbumTasks = {
      for (final id in _stoppingAlbums.keys) ..._albums[id]!.taskIds,
    };
    for (final item in tasks.where(
      (item) =>
          item.state == DownloadState.queued &&
          !_stopping.containsKey(item.id) &&
          !stoppedAlbumTasks.contains(item.id) &&
          !(_automaticGuards[item.id]?.call() ?? true),
    )) {
      unawaited(
        _stop(item.id, cancel: false).catchError((Object _) {
          _tasks[item.id] = task(item.id).copyWith(
            state: DownloadState.paused,
            error: '暂停状态保存失败，请检查资料目录后重新打开应用',
          );
          _notify();
        }),
      );
    }
    final pending = tasks
        .where(
          (item) =>
              item.state == DownloadState.queued &&
              !_workers.containsKey(item.id) &&
              !_stopping.containsKey(item.id) &&
              !stoppedAlbumTasks.contains(item.id) &&
              (_automaticGuards[item.id]?.call() ?? true),
        )
        .toList();
    if (_priority != null) {
      final index = pending.indexWhere((item) => item.id == _priority);
      if (index > 0) pending.insert(0, pending.removeAt(index));
    }
    for (final item in pending) {
      if (_workers.length >= parallelism) break;
      final control = DownloadControl._(
        (received, total, rate) {
          final current = task(item.id);
          _tasks[item.id] = current.copyWith(
            receivedBytes: received,
            totalBytes: total,
            bytesPerSecond: rate,
          );
          _notify();
        },
        () => _change(
          item.id,
          (value) => value.copyWith(
            state: DownloadState.processing,
            processingFailed: true,
          ),
        ),
        (message) =>
            _change(item.id, (value) => value.copyWith(warning: message)),
      );
      final done = Completer<void>();
      _workers[item.id] = (control: control, done: done.future);
      unawaited(
        _run(item.id, control).whenComplete(() {
          _workers.remove(item.id);
          done.complete();
          _pump();
        }),
      );
    }
  }

  Future<void> _run(String id, DownloadControl control) async {
    var quoteRefreshes = 0;
    try {
      if (!(_automaticGuards[id]?.call() ?? true))
        throw const DownloadStopped();
      _automaticGuards.remove(id);
      while (true) {
        await control.checkpoint();
        await _requireMediaTools(checkpoint: control.checkpoint);
        await control.checkpoint();
        try {
          final String path;
          if (task(id).processingFailed) {
            final process = processOnly;
            if (process == null) {
              throw const XmlyException('integration_required', '媒体处理服务未接入');
            }
            await control.processing();
            path = await process(task(id), control);
          } else {
            final audio = await _orderedAdmission(id, control);
            await control.checkpoint();
            await _change(
              id,
              (item) => item.copyWith(
                state: DownloadState.downloading,
                retryAt: null,
                error: null,
              ),
            );
            await control.checkpoint();
            // Network producers enter only after normal account admission.
            path = await transfer(task(id), audio, control);
          }
          // The backend returns only after committing a verified output. A
          // concurrent pause/cancel must preserve this completed result.
          if (!p.isAbsolute(path)) {
            throw const XmlyException('invalid_output', '媒体处理未返回有效成品路径');
          }
          await _change(
            id,
            (item) => item.copyWith(
              state: DownloadState.completed,
              finalPath: path,
              bytesPerSecond: 0,
              error: null,
              processingFailed: false,
              outputMissing: false,
              outputDeleted: false,
            ),
          );
          return;
        } catch (error) {
          if (error is DownloadStopped) rethrow;
          if (error is XmlyException &&
              error.code == 'confirmation_changed' &&
              task(id).userConfirmed &&
              quoteRefreshes++ == 0)
            continue;
          if (await _rotate(id, error, control)) continue;
          // API/transport own bounded request retries; do not multiply them here.
          rethrow;
        }
      }
    } on DownloadStopped {
      // The caller owns the stopped state and waits for this worker to drain.
    } catch (error) {
      try {
        final changed =
            error is XmlyException &&
            const {
              'confirmation_changed',
              'confirmation_required',
            }.contains(error.code) &&
            !task(id).userConfirmed;
        await _change(
          id,
          (item) =>
              item.state == DownloadState.cancelled ||
                  item.state == DownloadState.paused
              ? item
              : item.copyWith(
                  state: changed
                      ? DownloadState.awaitingDebit
                      : DownloadState.failed,
                  needsConfirmation: changed,
                  error: _message(error),
                  bytesPerSecond: 0,
                  processingFailed:
                      item.processingFailed ||
                      item.state == DownloadState.processing,
                  retryAt: null,
                ),
        );
      } catch (_) {
        // Durability failed: keep a visible stopped state, never start a producer.
        final item = task(id);
        _tasks[id] = item.copyWith(
          state: DownloadState.failed,
          error: '下载状态保存失败，请检查资料目录后重新打开应用',
          bytesPerSecond: 0,
        );
        _notify();
      }
    }
  }

  Future<bool> _rotate(String id, Object error, DownloadControl control) async {
    final current = task(id);
    if (!_requestFailure(error) ||
        current.processingFailed ||
        _hasDebit(current.accountIdentity, id, current.track.id))
      return false;
    final attempted = {...current.attemptedAccounts, current.accountIdentity};
    for (final identity in _candidates(
      current.accountIdentity,
      current.settings,
      taskId: id,
      trackId: current.track.id,
    ).where((id) => !attempted.contains(id))) {
      await control.checkpoint();
      attempted.add(identity);
      await _change(
        id,
        (item) => item.copyWith(attemptedAccounts: attempted.toList()),
      );
      final batch = await _preview(
        identity,
        current.rootDirectory,
        {
          ...current.settings,
          'download': {
            ...(current.settings['download'] as Map? ?? const {}),
            'polling': false,
          },
        },
        [(track: current.track, taskId: null)],
        control: control,
      );
      final candidate = batch.items.single;
      if (candidate.error != null) continue;
      await control.checkpoint();
      await _change(
        id,
        (item) => item.copyWith(
          accountIdentity: identity,
          track: candidate.track,
          costSeconds: candidate.seconds,
          expectedBalance: candidate.expectedBalance,
          state: DownloadState.queued,
          receivedBytes: 0,
          totalBytes: null,
          bytesPerSecond: 0,
          error: null,
        ),
      );
      return true;
    }
    return false;
  }

  Future<ResolvedAudio> _orderedAdmission(String id, DownloadControl control) {
    // A stopped worker must not wait for another task's admission while holding
    // the command lock. Once entered, keep waiting for any debit to be journaled.
    var entered = false;
    final result = Completer<ResolvedAudio>();
    final admission = _admissionOrder
        .putIfAbsent(task(id).accountIdentity, Lock.new)
        .synchronized(() async {
          entered = true;
          await control.checkpoint();
          await _checkRoot(task(id).rootDirectory, task(id).settings);
          return _admit(id, control);
        });
    admission.then(
      (audio) {
        if (!result.isCompleted) result.complete(audio);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    control.stopped.then((_) {
      if (!entered && !result.isCompleted)
        result.completeError(const DownloadStopped());
    });
    return result.future;
  }

  Future<ResolvedAudio> _admit(String id, DownloadControl control) async {
    var current = task(id);
    if (current.settings['billingPreviewPending'] == true) {
      if (_hasDebit(current.accountIdentity, id, current.track.id) &&
          _receipt(current.accountIdentity, id, current.track.id) == null) {
        throw const XmlyException('usage_uncertain', '请先核对本集未确认的听时扣除');
      }
      // Manual batches defer the existing fee/account preview until execution.
      final batch = await _preview(
        current.accountIdentity,
        current.rootDirectory,
        current.settings,
        [(track: current.track, taskId: id)],
        control: control,
      );
      final prepared = batch.items.single;
      await control.checkpoint();
      if (prepared.error != null) {
        throw XmlyException('download_unavailable', prepared.error!);
      }
      final settings = Map<String, dynamic>.from(current.settings)
        ..remove('billingPreviewPending');
      await _change(
        id,
        (item) => item.copyWith(
          accountIdentity: prepared.accountIdentity,
          track: prepared.track,
          costSeconds: prepared.seconds,
          expectedBalance: prepared.expectedBalance,
          attemptedAccounts: prepared.attemptedAccounts,
          settings: settings,
        ),
      );
      current = task(id);
    }
    Future<ResolvedAudio> authorize(XmlyClient client) async {
      await control.checkpoint();
      if (current.accountIdentity != 'anonymous' &&
          ledger
              .receipts(current.accountIdentity)
              .any(
                (receipt) =>
                    receipt.taskId == id &&
                    !receipt.historical &&
                    const {
                      DebitState.submitting,
                      DebitState.uncertain,
                    }.contains(receipt.state),
              )) {
        throw const XmlyException('usage_uncertain', '请先核对本集未确认的听时扣除');
      }
      final previous = _receipt(current.accountIdentity, id, current.track.id);
      final fresh = _freshResolves.contains(id);
      final quality =
          (current.settings['download'] as Map?)?['quality'] as String?;
      final cached = previous == null || fresh
          ? null
          : await readRequests(
              client,
              current.settings,
              () =>
                  client.cachedPrepaidAudio(current.track.id, quality: quality),
              control: control,
            );
      await control.checkpoint();
      int? expectedBalance = current.expectedBalance;
      if (cached == null && current.accountIdentity != 'anonymous') {
        final claimed = await readRequests(
          client,
          current.settings,
          () async =>
              await beforeAdmission?.call(current.accountIdentity, client),
          control: control,
        );
        if (claimed != null && claimed > 0) {
          await _updates.synchronized(() async {
            final next = Map<String, DownloadTask>.from(_tasks);
            for (final item in next.values.toList()) {
              if (item.accountIdentity == current.accountIdentity &&
                  item.expectedBalance != null &&
                  item.state != DownloadState.completed &&
                  !_hasDebit(item.accountIdentity, item.id, item.track.id)) {
                next[item.id] = item.copyWith(
                  expectedBalance: item.expectedBalance! + claimed,
                );
              }
            }
            await _save(next);
            _tasks
              ..clear()
              ..addAll(next);
          });
          expectedBalance = task(id).expectedBalance;
        }
        await control.checkpoint();
      }
      final audio =
          cached ??
          await readRequests<ResolvedAudio>(
            client,
            current.settings,
            () => client.resolve(
              current.track.id,
              quality: quality,
              force: fresh,
              preferCached: previous == null && !fresh,
            ),
            control: control,
          );
      _freshResolves.remove(id);
      _identity(audio, current.accountIdentity, current.track.id);
      await control.checkpoint();
      final reward = _reward(audio);
      if (reward &&
          previous == null &&
          ledger.isBlocked(current.accountIdentity)) {
        throw const XmlyException('usage_uncertain', '请先核对未确认的听时扣除');
      }
      if (previous == null && current.userConfirmed) {
        // The start action authorizes this selected track and configured account
        // policy; revalidate a stale quote, never replay an uncertain debit.
        final seconds = reward ? _fee(audio.track) : 0;
        expectedBalance = seconds == 0
            ? null
            : (await readRequests(
                client,
                current.settings,
                () => ledger.queryQuota(current.accountIdentity),
                control: control,
              )).remainingSeconds;
        await control.checkpoint();
        await _change(
          id,
          (item) => item.copyWith(
            costSeconds: seconds,
            expectedBalance: expectedBalance,
            needsConfirmation: false,
          ),
        );
        current = task(id);
      }
      await _change(
        id,
        (item) => item.copyWith(
          state: DownloadState.awaitingDebit,
          track: _metadata(audio.track, item.track),
          actualQuality: audio.actualQuality,
        ),
      );
      await control.checkpoint();
      if (reward) {
        final receipt =
            previous ??
            await readRequests(
              client,
              current.settings,
              () => ledger.prepay(
                identity: current.accountIdentity,
                taskId: id,
                audio: audio,
                userConfirmed: current.userConfirmed,
                expectedSeconds: current.costSeconds,
                expectedBalance: expectedBalance,
                wait: control.wait,
              ),
              control: control,
            );
        if (receipt == null ||
            receipt.state != DebitState.confirmed ||
            receipt.historical ||
            receipt.accountIdentity != current.accountIdentity ||
            receipt.taskId != id ||
            receipt.trackId != current.track.id) {
          throw const XmlyException('receipt_required', '听时尚未确认，下载未开始');
        }
        await _change(
          id,
          (item) => item.copyWith(receiptOperationId: receipt.operationId),
        );
      }
      // Retain this pre-debit URL even when the debit consumes the last second.
      return audio;
    }

    if (current.accountIdentity == 'anonymous') return authorize(anonymous);
    // A queued account change can own the mutex and call pauseAll(). Abandon only
    // not-yet-entered admissions; an actual debit must always finish its journal.
    var entered = false;
    final result = Completer<ResolvedAudio>();
    final admission = accounts.runWithAccount(current.accountIdentity, (
      client,
    ) async {
      entered = true;
      return authorize(client);
    });
    admission.then(
      (audio) {
        if (!result.isCompleted) result.complete(audio);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    control._stopped.future.then((_) {
      if (!entered && !result.isCompleted)
        result.completeError(const DownloadStopped());
    });
    return result.future;
  }

  Future<void> _change(String id, DownloadTask Function(DownloadTask) change) =>
      _updates.synchronized(() async {
        final next = Map<String, DownloadTask>.from(_tasks);
        next[id] = change(task(id));
        await _save(next);
        _tasks[id] = next[id]!;
        _notify();
      });
  Future<void> _save(Map<String, DownloadTask> values) => storage.transaction((
    state,
  ) {
    state['downloads'] = values.values.map((item) => item.toJson()).toList();
    state['downloadAlbums'] = _albums.values
        .map((job) => job.toJson())
        .toList();
  });
  bool _duplicate(
    String identity,
    String trackId, {
    Map<String, DownloadTask>? source,
  }) => (source ?? _tasks).values.any(
    (item) =>
        item.track.id == trackId &&
        (item.state == DownloadState.completed ||
            item.active && _hasDebit(item.accountIdentity, item.id, trackId) ||
            item.accountIdentity == identity &&
                item.deduplicates &&
                (item.active || !item.outputMissing)),
  );
  DownloadReceipt? _receipt(String identity, String? taskId, String trackId) {
    if (taskId == null || identity == 'anonymous') return null;
    for (final receipt in ledger.receipts(identity)) {
      if (receipt.taskId == taskId &&
          receipt.accountIdentity == identity &&
          receipt.trackId == trackId &&
          receipt.state == DebitState.confirmed &&
          !receipt.historical)
        return receipt;
    }
    return null;
  }

  // A quota-based authorization may also return isAuthorized.
  // The resolver retains whether that permission required listening quota.
  static bool _reward(ResolvedAudio audio) => audio.requiresReward;
  static int _fee(Track track) {
    if (!track.duration.isFinite ||
        track.duration <= 0 ||
        track.duration > 2147483647) {
      throw const XmlyException('invalid_duration', '本集时长无效，不能预扣听时');
    }
    return track.duration.ceil();
  }

  static void _identity(ResolvedAudio audio, String identity, String trackId) {
    if (audio.accountIdentity != identity || audio.track.id != trackId) {
      throw const XmlyException('identity_mismatch', '声音授权与所选账号不一致');
    }
  }

  static Track _metadata(Track fresh, Track selected) => Track(
    id: fresh.id,
    title: fresh.title.isEmpty ? selected.title : fresh.title,
    artist: fresh.artist.isEmpty ? selected.artist : fresh.artist,
    album: fresh.album.isEmpty ? selected.album : fresh.album,
    albumId: fresh.albumId.isEmpty ? selected.albumId : fresh.albumId,
    duration: fresh.duration,
    orderNo: fresh.orderNo ?? selected.orderNo,
    episode: fresh.episode ?? selected.episode,
    isPaid: fresh.isPaid,
    isAuthorized: fresh.isAuthorized,
    coverUrl: fresh.coverUrl ?? selected.coverUrl,
    intro: fresh.intro.isEmpty ? selected.intro : fresh.intro,
    raw: {
      ...fresh.raw,
      if (fresh.albumId.isEmpty || fresh.albumId == selected.albumId)
        'totalCount':
            xmlyPositive(fresh.raw['totalCount']) ??
            xmlyPositive(fresh.raw['total']) ??
            xmlyPositive(selected.raw['totalCount']) ??
            xmlyPositive(selected.raw['total']),
      if (selected.officialPosition != null)
        'officialPosition': selected.officialPosition,
    },
  );
  static Future<T> readRequests<T>(
    XmlyClient client,
    Map settings,
    Future<T> Function() action, {
    DownloadControl? control,
    Future<void>? cancelled,
    Future<void> Function()? checkpoint,
  }) => client.withReadPolicy(
    action,
    rateLimitRetries: _option(settings, 'retryLimit', 3, 0, 1000),
    minimumRateLimitDelay: const Duration(minutes: 5),
    cancelled: cancelled ?? control?.stopped,
    checkpoint: checkpoint ?? control?.checkpoint,
  );
  static int _option(Map settings, String key, int fallback, int min, int max) {
    final download = settings['download'];
    final value = download is Map ? download[key] : null;
    if (value == null) return fallback;
    if (value is! int || value < min || value > max) {
      throw const XmlyException('invalid_settings', '下载设置超出范围');
    }
    return value;
  }

  static Future<void> _requireMediaTools({
    Future<void> Function()? checkpoint,
  }) async {
    if (Platform.isAndroid)
      await MediaProcessor().checkTools(checkpoint: checkpoint);
  }

  static Future<void> _checkRoot(String path, [Map? settings]) =>
      DownloadPaths().checkRoot(
        path,
        minimumFreeMiB: _option(
          settings ?? const {},
          'minimumFreeMiB',
          512,
          512,
          1048576,
        ),
      );
  static String _message(Object error) {
    // Never persist third-party messages (they can contain signed URLs/secrets).
    if (error is XmlyException) {
      switch (error.code) {
        case 'original_account_required':
          return '原任务含已确认或未知的扣时，请先登录并选择原账号继续';
        case 'confirmation_changed':
        case 'confirmation_required':
          return '听时或余额持续变化，本次下载已停止；任务和扣时记录保留，请稍后重试';
        case 'catalogue_changed':
          return '专辑在刷新期间再次变化，已停止；已下载内容和扣时记录保留，请稍后继续';
        case 'catalogue_limit':
          return '专辑超过 5000 集下载上限，已停止；已下载内容和扣时记录保留';
        case 'invalid_catalogue':
          return '专辑分页、顺序或声音 ID 无效，已停止；已下载内容和扣时记录保留';
        case 'usage_uncertain':
        case 'receipt_required':
          return '听时扣除尚未确认，请先核对';
        case 'insufficient_quota':
          return '听时不足，请在官方 App 获取听时';
        case 'rate_limited':
          return '请求过于频繁，已达到重试上限';
        case 'login_expired':
          return '登录已失效，请重新登录';
        case 'download_root':
        case 'download_not_writable':
          return '下载目录不可写，请重新选择';
        case 'download_directory':
          return '下载目录不存在或无效，请重新选择';
        case 'disk_space':
          return '下载空间不足，请释放空间或更换目录，源缓存已保留';
        case 'disk_space_unavailable':
        case 'disk_space_unsupported':
          return '无法查询下载目录的可用空间，请更换目录后重试';
        case 'invalid_space':
          return '可用空间设置无效，请检查下载设置';
        case 'destination_exists':
          return '目标文件已存在，请选择覆盖或添加编号，源缓存已保留';
        case 'atomic_commit_cross_device':
          return '无法跨存储卷安全保存文件，请更换下载目录，源缓存已保留';
        case 'atomic_commit_unsupported':
          return '当前存储不支持安全保存文件，请更换下载目录或设备，源缓存已保留';
        case 'atomic_commit':
        case 'invalid_commit':
          return '文件安全提交失败，源缓存已保留，请更换目录后重试';
        case 'integration_required':
          return '媒体处理服务未接入，不能重试处理';
        case 'media_tool_missing':
        case 'media_tool':
          return Platform.isAndroid
              ? '随附 Android FFmpeg/FFprobe 无法使用，请重新安装完整安装包；任务、源缓存及已确认的听时记录保留'
              : '无法启动媒体工具，请检查路径';
        case 'media_probe':
          return '无法识别有效音轨或时长，源缓存已保留，请选择重新获取或其他格式';
        case 'media_incomplete':
          return '音频时长明显短于标注时长，请重新获取音频；源缓存和已有扣时收据已保留';
        case 'media_hash':
        case 'media_validation':
          return '音频校验失败，源缓存已保留，请选择其他格式后重试';
        case 'media_stream_changed':
          return '原始音频流校验失败，请选择其他格式，源缓存已保留';
        case 'media_process':
          return '媒体处理失败，源缓存已保留，请检查输出格式或媒体工具后重试';
        case 'media_timeout':
          return '媒体处理超时，源缓存已保留，请重试处理';
        case 'media_output_limit':
          return '媒体工具输出异常，源缓存已保留，请检查媒体工具后重试';
        case 'media_original_unsupported':
          return '此源格式不能原样写入标签，请选择 MP3、M4A 或 FLAC，源缓存已保留';
        case 'media_format':
        case 'media_bitrate':
        case 'media_settings':
        case 'media_tags':
          return '音频格式、码率或标签设置无效，请检查媒体设置';
        case 'media_local_file':
          return '本地音频文件不可用，源缓存已保留，请检查目录或重新获取音频';
        case 'source_missing':
          return '本地源音频缺失或损坏，请选择重新获取';
        case 'invalid_duration':
          return '声音时长无效，不能预扣听时';
      }
    }
    if (error is FileSystemException) {
      return '文件保存失败，源缓存已保留，请检查目录权限或更换目录';
    }
    return '下载失败，已保留任务及已确认的听时记录';
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _ensureOpen() {
    if (!_loaded || _closed)
      throw const XmlyException('closed', '下载服务尚未打开或已关闭');
  }

  Future<void> close() async {
    if (_closed) return;
    // A failed load must not overwrite persisted tasks with the empty queue.
    if (_loaded) await pauseAll();
    _closed = true;
    await _changes.close();
  }
}
