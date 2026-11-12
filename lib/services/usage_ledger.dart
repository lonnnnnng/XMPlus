// Ported from xmly/usage.py (AGPL-3.0-or-later); see LICENSE/NOTICE.
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../api/xmly_client.dart';
import '../models/xmly_models.dart';
import '../storage/app_storage.dart';

enum DebitState { prepared, submitting, confirmed, uncertain, rejected }

class DownloadReceipt {
  const DownloadReceipt({
    required this.operationId,
    required this.accountIdentity,
    required this.trackId,
    required this.taskId,
    required this.seconds,
    required this.balanceBefore,
    this.balanceAfter,
    required this.createdAt,
    required this.state,
    this.historical = false,
  });

  final String operationId, accountIdentity, trackId, taskId;
  final int seconds, balanceBefore;
  final int? balanceAfter;
  final DateTime createdAt;
  final DebitState state;
  final bool historical;

  factory DownloadReceipt.fromJson(Map<String, dynamic> value) {
    final historical =
        value['historical'] == true || value['state'] == 'historical';
    final state = value['state'] == 'historical'
        ? DebitState.confirmed
        : DebitState.values
              .where((item) => item.name == value['state'])
              .firstOrNull;
    if (state == null ||
        ['operationId', 'accountIdentity', 'trackId', 'taskId'].any(
          (key) => value[key] is! String || (value[key] as String).isEmpty,
        ) ||
        value['seconds'] is! int ||
        (value['seconds'] as int) < 1 ||
        (value['seconds'] as int) > UsageLedger.maxSeconds ||
        value['balanceBefore'] is! int ||
        (value['balanceBefore'] as int) < 0 ||
        (value['balanceAfter'] != null &&
            (value['balanceAfter'] is! int ||
                (value['balanceAfter'] as int) < 0)) ||
        value['createdAt'] is! int) {
      throw const XmlyException('invalid_ledger', '扣时记录损坏，请保留资料并恢复备份');
    }
    return DownloadReceipt(
      operationId: value['operationId'] as String,
      accountIdentity: value['accountIdentity'] as String,
      trackId: 'xmly:${xmlyIdentifier(value['trackId'] as String)}',
      taskId: value['taskId'] as String,
      seconds: value['seconds'] as int,
      balanceBefore: value['balanceBefore'] as int,
      balanceAfter: value['balanceAfter'] as int?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(value['createdAt'] as int),
      state: state,
      historical: historical,
    );
  }

  Map<String, dynamic> toJson() => {
    'operationId': operationId,
    'accountIdentity': accountIdentity,
    'trackId': trackId,
    'taskId': taskId,
    'seconds': seconds,
    'balanceBefore': balanceBefore,
    'balanceAfter': balanceAfter,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'state': historical && state == DebitState.confirmed
        ? 'historical'
        : state.name,
    if (historical) ...{'historical': true, 'downloadExempt': false},
  };
}

/// One account mutex covers online debt and download prepayments. A local UUID
/// identifies the journal entry only: the server has no idempotency key.
class UsageLedger {
  UsageLedger({
    required this.storage,
    required this.clientFor,
    Duration Function()? monotonic,
    DateTime Function()? clock,
  }) : _monotonic = monotonic ?? _elapsedClock(),
       _clock = clock ?? DateTime.now;

  static const maxSeconds = 2147483647;
  static const reportFactor = 1.0;
  final AppStorage storage;
  final XmlyClient Function(String identity) clientFor;
  final Duration Function() _monotonic;
  final DateTime Function() _clock;
  final Map<String, Lock> _locks = {};
  final Lock _watchChanges = Lock();
  _Listening? _watch;

  bool get needsRestart => _watch?.suspended ?? false;

  static Duration Function() _elapsedClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  Lock _lock(String identity) => _locks.putIfAbsent(identity, Lock.new);

  Map<String, dynamic> _ledger(String identity) {
    final account = (storage.state['accounts'] as Map)[identity];
    if (account is! Map) {
      throw const XmlyException('missing_account', '请先登录原账号');
    }
    final ledger = account['ledger'];
    if (ledger != null && ledger is! Map<String, dynamic>) {
      throw const XmlyException('invalid_ledger', '听时记录损坏，请保留资料');
    }
    final result = ledger as Map<String, dynamic>? ?? const <String, dynamic>{};
    if ((result['usage_uncertain'] != null &&
            result['usage_uncertain'] is! bool) ||
        (result['usage_pending'] != null && result['usage_pending'] is! Map)) {
      throw const XmlyException('invalid_ledger', '待核对听时记录无效，请保留资料');
    }
    return result;
  }

  Future<void> _write(
    String identity,
    void Function(Map<String, dynamic>) update,
  ) => storage.transaction((state) {
    final account = (state['accounts'] as Map)[identity];
    if (account is! Map) {
      throw const XmlyException('missing_account', '请先登录原账号');
    }
    final ledger = account.putIfAbsent('ledger', () => <String, dynamic>{});
    if (ledger is! Map<String, dynamic>) {
      throw const XmlyException('invalid_ledger', '听时记录损坏，请保留资料');
    }
    update(ledger);
  });

  List<DownloadReceipt> receipts(String identity) {
    final items = _ledger(identity)['receipts'] ?? const [];
    if (items is! List) {
      throw const XmlyException('invalid_ledger', '扣时记录损坏，请保留资料');
    }
    return List.unmodifiable(
      items.map((item) {
        if (item is! Map) {
          throw const XmlyException('invalid_ledger', '扣时记录损坏，请保留资料');
        }
        final receipt = DownloadReceipt.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (receipt.accountIdentity != identity) {
          throw const XmlyException('invalid_ledger', '扣时记录与账号不符');
        }
        return receipt;
      }),
    );
  }

  bool isBlocked(String identity) {
    final ledger = _ledger(identity);
    return ledger['usage_uncertain'] == true ||
        ledger['usage_pending'] != null ||
        receipts(identity).any(
          (item) =>
              item.state == DebitState.submitting ||
              item.state == DebitState.uncertain,
        );
  }

  /// A durable zero-baseline report cannot be resolved by comparing balances.
  bool hasUnverifiableReport(String identity) {
    if (identity == 'anonymous') return false;
    final pending = _ledger(identity)['usage_pending'];
    return pending is Map &&
        pending['accountIdentity'] == identity &&
        pending['balanceBefore'] == 0 &&
        (pending['state'] == 'submitting' || pending['state'] == 'uncertain');
  }

  void _guard(String identity) {
    if (isBlocked(identity)) throw _uncertain;
    if (clientFor(identity).identity != identity) {
      throw const XmlyException('account_mismatch', '请求账号已改变，请重新操作');
    }
  }

  static const _uncertain = XmlyException(
    'usage_uncertain',
    '上次扣时结果未知，请先到官方 App 核对并确认是否已扣',
  );

  /// Local recovery only; no POST, query, or automatic replay on startup.
  Future<void> load() async {
    for (final identity
        in (storage.state['accounts'] as Map).keys.cast<String>().toList()) {
      await _lock(identity).synchronized(() => _recover(identity));
    }
  }

  Future<void> _recover(String identity) async {
    final ledger = _ledger(identity);
    final entries = receipts(identity);
    final pending = ledger['usage_pending'];
    final recoverPending = pending is Map && pending['state'] == 'submitting';
    if (!recoverPending &&
        !entries.any((item) => item.state == DebitState.submitting))
      return;
    await _write(identity, (next) {
      for (final entry in next['receipts'] as List? ?? const []) {
        if (entry is Map && entry['state'] == 'submitting')
          entry['state'] = 'uncertain';
      }
      if (recoverPending) {
        (next['usage_pending'] as Map)['state'] = 'uncertain';
        next['usage_uncertain'] = true;
      }
    });
  }

  Future<Quota> queryQuota(String identity) =>
      _lock(identity).synchronized(() async {
        final client = clientFor(identity);
        if (client.identity != identity) {
          throw const XmlyException('account_mismatch', '请使用原账号核对听时');
        }
        return client.queryQuota();
      });

  Future<DownloadReceipt?> prepay({
    required String identity,
    required String taskId,
    required ResolvedAudio audio,
    required bool userConfirmed,
    int? expectedSeconds,
    int? expectedBalance,
    Future<void> Function(Duration delay)? wait,
  }) => _lock(identity).synchronized(() async {
    if (!audio.requiresReward) return null;
    if (audio.accountIdentity != identity || taskId.trim().isEmpty) {
      throw const XmlyException('account_mismatch', '声音授权与下载账号不符');
    }
    await _recover(identity);
    _guard(identity);
    for (final receipt in receipts(identity).reversed) {
      if (receipt.taskId != taskId) continue;
      if (receipt.trackId != audio.track.id) {
        throw const XmlyException('task_mismatch', '原任务与声音不符');
      }
      if (receipt.state == DebitState.confirmed && !receipt.historical)
        return receipt;
    }
    final duration = audio.track.duration;
    if (!duration.isFinite || duration <= 0 || duration > maxSeconds) {
      throw const XmlyException('invalid_duration', '缺少有效的整首时长，不能预扣下载');
    }
    final seconds = duration.ceil();
    if (!userConfirmed) {
      throw const XmlyException('confirmation_required', '请先确认本首扣时及不可自动退款说明');
    }
    await _settleLocked(identity, pause: false);
    // Settlement takes its own balance lock. Acquire this only afterwards;
    // keep the fresh quote, durable journal, report and result atomic to claims.
    return clientFor(identity).withBalanceChange(() async {
      final quota = await clientFor(identity).queryQuota();
      if ((expectedSeconds != null && expectedSeconds != seconds) ||
          (expectedBalance != null &&
              expectedBalance != quota.remainingSeconds)) {
        throw const XmlyException('confirmation_changed', '时长或余额已改变，请重新确认');
      }
      if (quota.remainingSeconds < seconds) throw _insufficient;
      for (var attempt = 0; ; attempt++) {
        final operation = DownloadReceipt(
          operationId: const Uuid().v4(),
          accountIdentity: identity,
          trackId: audio.track.id,
          taskId: taskId,
          seconds: seconds,
          balanceBefore: quota.remainingSeconds,
          createdAt: _clock(),
          state: DebitState.submitting,
        ).toJson();
        try {
          await _submit(identity, operation, online: false);
          return receipts(
            identity,
          ).singleWhere((item) => item.operationId == operation['operationId']);
        } on XmlyException catch (error) {
          final rejected = receipts(identity).any(
            (receipt) =>
                receipt.operationId == operation['operationId'] &&
                receipt.state == DebitState.rejected,
          );
          if (!rejected ||
              !error.definitive ||
              attempt >= 4 ||
              const {
                'invalid_duration',
                'invalid_ledger',
                'login_expired',
                'login_required',
                'account_mismatch',
                'invalid_endpoint',
                'insufficient_quota',
                'rate_limited',
              }.contains(error.code))
            rethrow;
          final backoff = Duration(seconds: 1 << attempt);
          final delay = (error.retryAfter ?? Duration.zero) > backoff
              ? error.retryAfter!
              : backoff;
          if (wait != null) {
            await wait(delay);
          } else {
            await Future<void>.delayed(delay);
          }
          _guard(identity);
          final refreshed = await clientFor(identity).queryQuota();
          if (refreshed.remainingSeconds != quota.remainingSeconds) {
            throw const XmlyException('confirmation_changed', '重试前余额已变化，请重新确认');
          }
        }
      }
    });
  });

  static const _insufficient = XmlyException(
    'insufficient_quota',
    '听时不足，请前往官方 App 获取听时',
    definitive: true,
  );

  double debt(String identity) {
    final value = _ledger(identity)['usage_seconds'] ?? 0.0;
    if (value is! num || !value.isFinite || value < 0) {
      throw const XmlyException('invalid_ledger', '实际收听记录无效，请保留资料');
    }
    return value.toDouble();
  }

  /// Starts paused. Only actual playback state events may enable metering.
  Future<void> startWatch({
    required String identity,
    required String trackId,
    required bool requiresReward,
    bool prepaid = false,
    double speed = 1,
  }) => _watchChanges.synchronized(() async {
    _validSpeed(speed);
    final normalized = 'xmly:${xmlyIdentifier(trackId)}';
    await _stopWatch();
    if (!requiresReward || prepaid || identity == 'anonymous') return;
    await _lock(identity).synchronized(() async {
      await _recover(identity);
      _guard(identity);
      final quota = await clientFor(identity).queryQuota();
      final newDevice = quota.newDevice && quota.remainingSeconds == 0;
      if (!newDevice && quota.remainingSeconds - debt(identity) <= 0) {
        throw _insufficient;
      }
      _watch = _Listening(identity, normalized, speed, _monotonic());
    });
  });

  static void _validSpeed(double speed) {
    if (!speed.isFinite || speed < 0.5 || speed > 3) {
      throw const XmlyException('invalid_speed', '播放倍速范围为 0.5–3.0');
    }
  }

  /// No position argument: seeking can never produce billable seconds.
  /// Record device events immediately; periodic saves use [sampleCurrentState].
  void recordPlaybackState({
    required bool playing,
    required bool buffering,
    double? speed,
  }) {
    if (speed != null) _validSpeed(speed);
    final watch = _watch;
    if (watch == null || watch.suspended) return;
    _captureElapsed(watch);
    watch.playing = playing && !buffering;
    if (speed != null) watch.speed = speed;
  }

  /// Save the latest device state without replacing it with queued UI state.
  Future<void> sampleCurrentState({double? speed}) {
    if (speed != null) {
      _validSpeed(speed);
      final watch = _watch;
      if (watch != null) {
        _captureElapsed(watch);
        watch.speed = speed;
      }
    }
    return observe(
      playing: _watch?.playing ?? false,
      buffering: false,
      stateAlreadyRecorded: true,
    );
  }

  Future<void> observe({
    required bool playing,
    required bool buffering,
    double? speed,
    bool stateAlreadyRecorded = false,
  }) {
    if (!stateAlreadyRecorded) {
      recordPlaybackState(playing: playing, buffering: buffering, speed: speed);
    }
    final observedWatch = _watch;
    return _watchChanges.synchronized(() async {
      final watch = observedWatch;
      if (watch == null || !identical(watch, _watch)) return;
      await _lock(watch.identity).synchronized(() async {
        try {
          await _sample(watch.identity);
          if (isBlocked(watch.identity)) throw _uncertain;
          if (!playing ||
              _monotonic() - watch.settledAt >= const Duration(seconds: 120)) {
            // A later device event may already have updated the actual state.
            await _settleLocked(watch.identity, pause: false);
          }
        } catch (_) {
          _suspend(watch);
          rethrow;
        }
      });
    });
  }

  void _captureElapsed(_Listening watch) {
    final now = _monotonic();
    final elapsed = now > watch.sampledAt
        ? (now - watch.sampledAt).inMicroseconds / 1000000
        : 0.0;
    watch.unsaved += watch.playing ? elapsed * watch.speed * reportFactor : 0;
    watch.sampledAt = now;
  }

  void _suspend(_Listening watch) {
    _captureElapsed(watch);
    watch.playing = false;
    watch.suspended = true;
  }

  Future<void> _sample(String identity) async {
    final watch = _watch;
    if (watch == null || watch.identity != identity) return;
    _captureElapsed(watch);
    if (watch.unsaved == 0) return;
    final amount = watch.unsaved;
    try {
      final total = debt(identity) + amount;
      await _write(identity, (ledger) => ledger['usage_seconds'] = total);
      watch.unsaved -= amount;
    } catch (_) {
      _suspend(watch);
      rethrow;
    }
  }

  /// Restore pauses producers first; preserve unknown journals without sending.
  Future<void> captureForRestore() => _watchChanges.synchronized(() async {
    final watch = _watch;
    if (watch == null) return;
    await _lock(watch.identity).synchronized(() async {
      // Keep the watch and unsaved sample reachable if persistence fails.
      await _sample(watch.identity);
      watch.playing = false;
      _watch = null;
    });
  });

  /// Previewing or prepaying a download does not pause actual playback. Keep
  /// sampling the watch across network waits, as periodic settlement does.
  Future<void> settleForDownload(String identity) =>
      _lock(identity).synchronized(() => _settleLocked(identity, pause: false));

  /// Callers pause the player before this account-switch/exit boundary.
  Future<void> settle([String? identity]) async {
    if (identity != null) {
      await _lock(identity).synchronized(() => _settleLocked(identity));
      return;
    }
    await _settleAccounts();
  }

  /// Exit can leave these durable journals intact, but may not replay them.
  Future<void> settleForExit() => _settleAccounts(exiting: true);

  Future<void> _settleAccounts({bool exiting = false}) async {
    final identities = (storage.state['accounts'] as Map).keys
        .cast<String>()
        .toList();
    for (final id in identities) {
      await _lock(id).synchronized(() async {
        try {
          await _settleLocked(id);
        } on XmlyException catch (error) {
          if (!exiting ||
              error.code != 'usage_uncertain' ||
              !hasUnverifiableReport(id)) {
            rethrow;
          }
        }
      });
    }
  }

  Future<void> _settleLocked(String identity, {bool pause = true}) async {
    await _recover(identity);
    await _sample(identity);
    final watch = _watch;
    if (pause && watch?.identity == identity) watch!.playing = false;
    if (!isBlocked(identity) &&
        debt(identity) < 1 &&
        watch?.identity != identity)
      return;
    _guard(identity);
    var seconds = debt(identity).floor();
    while (seconds > 0) {
      final amount = seconds > maxSeconds ? maxSeconds : seconds;
      await clientFor(identity).withBalanceChange(() async {
        final quota = await clientFor(identity).queryQuota();
        final newDevice = quota.newDevice && quota.remainingSeconds == 0;
        if (!newDevice && quota.remainingSeconds < amount) throw _insufficient;
        final operation = <String, dynamic>{
          'operationId': const Uuid().v4(),
          'accountIdentity': identity,
          'trackId': watch?.identity == identity ? watch!.trackId : '',
          'seconds': amount,
          'balanceBefore': quota.remainingSeconds,
          'balanceAfter': null,
          'createdAt': _clock().millisecondsSinceEpoch,
          'state': 'submitting',
        };
        await _submit(identity, operation, online: true);
      });
      seconds = debt(identity).floor();
    }
    if (watch?.identity == identity) watch!.settledAt = _monotonic();
  }

  Future<void> stopWatch() => _watchChanges.synchronized(_stopWatch);

  Future<void> _stopWatch() async {
    final watch = _watch;
    if (watch == null) return;
    await _lock(watch.identity)
        .synchronized(() => _settleLocked(watch.identity));
    _watch = null;
  }

  Future<void> _submit(
    String identity,
    Map<String, dynamic> operation, {
    required bool online,
  }) async {
    // A failed journal commit returns before even constructing a report request.
    await _write(identity, (ledger) {
      if (online) {
        ledger['usage_pending'] = operation;
        ledger['usage_uncertain'] = true;
      } else {
        (ledger.putIfAbsent('receipts', () => <dynamic>[]) as List).add(
          operation,
        );
      }
    });
    final balanceBefore = operation['balanceBefore'] as int;
    // 一天限免时余额超过 20 小时，扣时接口不可用。
    final freeDay = balanceBefore > const Duration(hours: 20).inSeconds;
    final int balanceAfter;
    try {
      balanceAfter = freeDay
          ? balanceBefore
          : (await clientFor(identity)
                    .debitSeconds(operation['seconds'] as int))
                .remainingSeconds;
    } catch (error) {
      // A generic rejection is not operation-specific proof for a report on
      // a device without a balance bucket. Keep its journal replay-blocking.
      if (error is XmlyException &&
          error.definitive &&
          !(online && balanceBefore == 0)) {
        try {
          await _finish(
            identity,
            operation,
            online: online,
            state: DebitState.rejected,
          );
        } catch (_) {
          await _markUncertain(identity, operation, online: online);
          throw _uncertain;
        }
        rethrow;
      }
      await _markUncertain(identity, operation, online: online);
      throw _uncertain;
    }
    operation['balanceAfter'] = balanceAfter;
    // A new-device flag describes quota, not whether this report was applied.
    if (!freeDay && balanceBefore - balanceAfter != operation['seconds']) {
      await _markUncertain(identity, operation, online: online);
      throw _uncertain;
    }
    try {
      await _finish(
        identity,
        operation,
        online: online,
        state: DebitState.confirmed,
      );
    } catch (_) {
      // Durable submitting remains authoritative even when disk stays unavailable.
      await _markUncertain(identity, operation, online: online);
      throw _uncertain;
    }
  }

  Future<void> _finish(
    String identity,
    Map<String, dynamic> operation, {
    required bool online,
    required DebitState state,
  }) => _write(identity, (ledger) {
    if (online) {
      if (state == DebitState.confirmed) {
        final current = ledger['usage_seconds'] as num;
        ledger['usage_seconds'] = (current - (operation['seconds'] as int))
            .clamp(0, double.infinity);
      }
      ledger.remove('usage_pending');
      ledger['usage_uncertain'] = false;
    } else {
      final entries = ledger['receipts'] as List;
      final index = entries.indexWhere(
        (item) => (item as Map)['operationId'] == operation['operationId'],
      );
      if (index < 0)
        throw const XmlyException('invalid_ledger', '扣时记录丢失，请保留资料');
      entries[index] = {...operation, 'state': state.name};
    }
  });

  Future<void> _markUncertain(
    String identity,
    Map<String, dynamic> operation, {
    required bool online,
  }) async {
    if (_watch?.identity == identity) _suspend(_watch!);
    try {
      await _write(identity, (ledger) {
        final pending = {...operation, 'state': 'uncertain'};
        if (online) {
          ledger['usage_pending'] = pending;
          ledger['usage_uncertain'] = true;
        } else {
          final entries = ledger['receipts'] as List;
          final index = entries.indexWhere(
            (item) => (item as Map)['operationId'] == operation['operationId'],
          );
          if (index >= 0) entries[index] = pending;
        }
      });
    } catch (_) {
      // The pre-POST submitting journal is already durable and blocks replay.
    }
  }

  /// [wasDebited] is an explicit human decision, never inferred from a balance.
  /// A negative decision permits the next explicit operation, not an auto-retry.
  Future<void> reconcile(
    String identity,
    String operationId, {
    required bool wasDebited,
  }) => _lock(identity).synchronized(() async {
    await _recover(identity);
    final ledger = _ledger(identity);
    final pending = ledger['usage_pending'];
    final online = pending is Map && pending['operationId'] == operationId;
    Map<String, dynamic>? operation;
    if (online) {
      operation = Map<String, dynamic>.from(pending);
    } else {
      for (final receipt in receipts(identity)) {
        if (receipt.operationId == operationId) operation = receipt.toJson();
      }
    }
    if (operation == null ||
        operation['accountIdentity'] != identity ||
        !['uncertain', 'submitting'].contains(operation['state'])) {
      throw const XmlyException('no_uncertain_operation', '没有这笔需要人工核对的扣时');
    }
    if (operation['seconds'] is! int ||
        (operation['seconds'] as int) < 1 ||
        (online && (operation['seconds'] as int) > debt(identity))) {
      throw const XmlyException('invalid_ledger', '待核对扣时记录无效，请保留资料');
    }
    // The screen already tried to display the balance. A human decision made
    // in the official app must remain saveable when that query is unavailable.
    // Validate the mounted identity without making another network request.
    queryClient(identity);
    // A report may be accepted without deducting anything on a new device.
    // Neither manual balance-based answer proves whether it was applied.
    if (online && operation['balanceBefore'] == 0) {
      throw const XmlyException(
        'usage_uncertain',
        '新设备没有可核对的余额变动，已保留听时记录，不会重复上报',
      );
    }
    await _finish(
      identity,
      operation,
      online: online,
      state: wasDebited ? DebitState.confirmed : DebitState.rejected,
    );
  });

  XmlyClient queryClient(String identity) {
    final client = clientFor(identity);
    if (client.identity != identity) {
      throw const XmlyException('account_mismatch', '请使用原账号核对听时');
    }
    return client;
  }
}

class _Listening {
  _Listening(this.identity, this.trackId, this.speed, this.sampledAt)
    : settledAt = sampledAt;
  final String identity, trackId;
  double speed;
  Duration sampledAt, settledAt;
  bool playing = false;
  bool suspended = false;
  double unsaved = 0;
}
