// SPDX-License-Identifier: AGPL-3.0-or-later
// Port of xmly/progress.py. Never uses listening-time debit or reward issuance.
import 'dart:async';
import 'dart:convert';

import 'package:synchronized/synchronized.dart';

import '../api/xmly_client.dart';
import '../api/xmly_history.dart';
import '../models/xmly_models.dart';

class _Session {
  _Session(this.identity, this.track, this.started);
  final String identity;
  final Track track;
  final int started;
  (double, int)? recorded;
}

/// Coalesces only actual playback observations, one newest record per album.
/// readPending/savePending must address the specified account's persistent map.
/// Automatic sync is disabled until the caller supplies an enabled consent flag.
class OfficialProgress {
  OfficialProgress({
    required XmlyClient? Function() client,
    required Map<String, dynamic> Function(String identity) readPending,
    required Future<void> Function(String identity, Map<String, dynamic>)
    savePending,
    bool Function()? enabled,
    DateTime Function()? clock,
    Duration Function()? monotonic,
  }) : _client = client,
       _readPending = readPending,
       _savePending = savePending,
       _enabled = enabled ?? (() => false),
       _clock = clock ?? DateTime.now {
    final watch = Stopwatch()..start();
    _monotonic = monotonic ?? (() => watch.elapsed);
  }

  final XmlyClient? Function() _client;
  final Map<String, dynamic> Function(String identity) _readPending;
  final Future<void> Function(String identity, Map<String, dynamic>)
  _savePending;
  final bool Function() _enabled;
  final DateTime Function() _clock;
  late final Duration Function() _monotonic;
  final _stateLock = Lock(), _flushLock = Lock();
  final Map<String, _Session> _sessions = {};
  final Map<String, (double, int)> _observed = {};
  Future<void>? _running;
  Duration _lastSent = const Duration(seconds: -30);
  int _lastSyncedAt = 0;
  String _error = '';
  bool _closing = false;

  static Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

  void start(String device, Track track, String identity) {
    if (_closing) return;
    _sessions[device] = _Session(
      identity,
      track,
      _clock().millisecondsSinceEpoch,
    );
    _observed.remove(device);
  }

  Future<void> observe(
    String device,
    double position, {
    bool terminal = false,
    bool actual = false,
  }) async {
    if (!position.isFinite || position < 0 || position > 2147483647) {
      throw ArgumentError('播放位置无效');
    }
    final session = _sessions[device];
    final client = _client();
    if (session == null || client == null || _closing) return;
    if (session.identity != client.identity) {
      _sessions.remove(device);
      _observed.remove(device);
      return;
    }
    if (actual) {
      final now = _clock().millisecondsSinceEpoch;
      _observed[device] = (
        position,
        now < session.started ? session.started : now,
      );
    }
    final observed = _observed[device];
    if (observed == null || observed.$2 <= session.started || !_enabled()) {
      if (terminal) {
        _sessions.remove(device);
        _observed.remove(device);
      }
      return;
    }
    final track = session.track;
    final album = track.albumId.isNotEmpty
        ? track.albumId
        : '${track.raw['album_id'] ?? track.raw['albumId'] ?? ''}';
    final key = album.isEmpty ? track.id : album;
    await _stateLock.synchronized(() async {
      final pending = _copy(_readPending(session.identity));
      if (!pending.containsKey(key) && pending.length >= 256) {
        _error = '待同步进度已达上限，请连接网络后重试';
        return;
      }
      final previous = pending[key];
      if (previous is Map &&
          previous['ended_at_ms'] is int &&
          (previous['ended_at_ms'] as int) > observed.$2)
        return;
      final sameObservation =
          previous is Map &&
          previous['identity'] == session.identity &&
          previous['track'] is Map &&
          (previous['track'] as Map)['id'] == track.id &&
          previous['position'] == observed.$1 &&
          previous['started_at_ms'] == session.started &&
          previous['ended_at_ms'] == observed.$2;
      // Pause/buffer cannot replay an ambiguous POST or recreate an ACKed record.
      // Keep in-flight snapshots unchanged so their ACK can still remove them.
      if (!actual && !sameObservation) return;
      if (sameObservation) {
        if (previous['attempted'] == true ||
            previous['terminal'] == true ||
            !terminal)
          return;
        pending[key] = {...previous, 'terminal': true};
        await _savePending(session.identity, pending);
        return;
      }
      if (session.recorded == observed) return;
      final safeTrack = track.toJson();
      safeTrack['raw'] = {
        'album_id': album,
        if (track.raw.containsKey('direction'))
          'direction': track.raw['direction'],
      };
      pending[key] = {
        'identity': session.identity,
        'track': safeTrack,
        'position': observed.$1,
        'started_at_ms': session.started,
        'ended_at_ms': observed.$2,
        'terminal': terminal,
        'attempted': false,
      };
      // Durable before any history POST; account switching cannot lose records.
      await _savePending(session.identity, pending);
      session.recorded = observed;
    });
    if (terminal) {
      _sessions.remove(device);
      _observed.remove(device);
    }
    if (terminal || _monotonic() - _lastSent >= const Duration(seconds: 30))
      schedule();
  }

  void schedule() {
    if (_closing || !_enabled() || _running != null) return;
    _running = flush()
        .catchError((Object _) {
          _error = '进度保存或同步失败，已保留待同步云进度';
        })
        .whenComplete(() {
          _running = null;
          final client = _client();
          if (_closing || !_enabled() || client == null) return;
          if (_error.isNotEmpty) return;
          final eligible = _readPending(client.identity).values
              .whereType<Map>()
              .any(
                (entry) =>
                    entry['identity'] == client.identity &&
                    entry['attempted'] != true &&
                    (entry['terminal'] == true ||
                        _monotonic() - _lastSent >=
                            const Duration(seconds: 30)),
              );
          if (eligible) schedule();
        });
  }

  Map<String, dynamic> snapshot() {
    final client = _client();
    final pending = client == null ? 0 : _readPending(client.identity).length;
    return {
      'status': _running != null
          ? 'syncing'
          : _error.isNotEmpty
          ? 'failed'
          : pending > 0
          ? 'pending'
          : 'synced',
      'pending': pending,
      'error': _error,
      'last_synced_at': _lastSyncedAt,
      'enabled': _enabled(),
    };
  }

  /// Failed/possibly delivered records are never replayed by observation,
  /// shutdown or restart. Only an explicit retry=true permits re-submission.
  Future<void> flush({bool retry = false}) => _flushLock.synchronized(() async {
    final client = _client();
    if (client == null || !_enabled()) {
      if (retry) {
        throw const XmlyException('history_unavailable', '请先登录并开启历史同步');
      }
      return;
    }
    bool sameClient() => identical(client, _client());
    bool active() => _enabled() && sameClient();

    final identity = client.identity;
    final history = XmlyHistory(client, clock: _clock);
    _lastSent = _monotonic();
    final pending = _copy(_readPending(identity));
    var failed = false, unconfirmed = false;
    for (final key in pending.keys) {
      if (!active()) break;
      final raw = pending[key];
      if (raw is! Map<String, dynamic> || raw['identity'] != identity) {
        failed = true;
        _error = '待同步云进度格式无效，已保留记录';
        continue;
      }
      if (!retry && raw['attempted'] == true) continue;
      var entry = _copy(raw);
      try {
        // Mark even read failures: only explicit retry may repeat this entry.
        final marked = await _stateLock.synchronized(() async {
          final current = _copy(_readPending(identity));
          if (jsonEncode(current[key]) != jsonEncode(entry)) return false;
          entry = {...entry, 'attempted': true};
          current[key] = entry;
          await _savePending(identity, current);
          return true;
        });
        if (!active()) break;
        if (!marked) continue;
        final track = Track.fromJson(entry['track'] as Map<String, dynamic>);
        final position = (entry['position'] as num).toDouble();
        final started = entry['started_at_ms'] as int;
        final ended = entry['ended_at_ms'] as int;
        final album = track.albumId.isNotEmpty
            ? track.albumId
            : '${track.raw['album_id'] ?? ''}';
        if (album.isEmpty) {
          failed = true;
          _error = '部分声音缺少专辑信息，已保留待同步记录；其他进度继续同步';
          continue;
        }
        final official = await history.progress(albumId: album);
        if (!active()) break;
        if (official != null &&
            (official['updated_at'] as num) * 1000 > ended) {
          await _removeIfUnchanged(identity, key, entry);
          continue;
        }
        await history.sync(track, position, started, ended);
        // Revoking consent blocks new writes, not cleanup of an existing ACK.
        if (!sameClient()) break;
        await _removeIfUnchanged(identity, key, entry);
        _lastSyncedAt = ended;
      } on Exception catch (error) {
        // Preserve the original absolute wall-clock bounds and pending record.
        failed = true;
        unconfirmed |=
            error is XmlyException && error.code == 'history_unconfirmed';
        _error = '收听进度同步失败，已保留待同步云进度';
      } on TypeError {
        failed = true;
        _error = '待同步云进度格式无效，已保留记录';
      } on ArgumentError {
        failed = true;
        _error = '待同步声音或进度信息无效，已保留记录；其他进度继续同步';
      }
    }
    if (sameClient() && _readPending(identity).isEmpty) _error = '';
    if (!active()) {
      if (retry) {
        throw const XmlyException('history_interrupted', '账号或同步设置已变更，请重新操作');
      }
      return;
    }
    if (retry && failed) {
      throw XmlyException(
        unconfirmed ? 'history_unconfirmed' : 'history_sync_failed',
        '历史同步失败，进度已保留',
      );
    }
  });

  Future<void> _removeIfUnchanged(
    String identity,
    String key,
    Map<String, dynamic> entry,
  ) => _stateLock.synchronized(() async {
    final pending = _copy(_readPending(identity));
    if (jsonEncode(pending[key]) != jsonEncode(entry)) return;
    pending.remove(key);
    await _savePending(identity, pending);
  });

  Future<void> close() async {
    _closing = true;
    await _running;
    await flush();
    _sessions.clear();
    _observed.clear();
  }
}
